import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
spec = importlib.util.spec_from_file_location('replay', ROOT / 'probe/replay_policy.py')
replay = importlib.util.module_from_spec(spec); spec.loader.exec_module(replay)
from analyze import FIELDS, read_events

POLICY = ROOT / 'probe/fatal_policy_v10.h'


class Capture:
    """Synthetic probe rows in hit_probe.h order; ms is local monotonic time."""
    def __init__(self, hp):
        self.rows, self.hp, self.sequence = [], hp, 100

    def add(self, phase, ms, **values):
        row = dict.fromkeys(FIELDS, 0)
        row.update(id=len(self.rows)+1, phase=phase, ns=int(ms*1e6)+1, generation=1, hp=self.hp, max=1000, valid=15,
                   tick_sequence=self.sequence, server_time=self.sequence*200)
        row.update(values);self.rows.append(row)

    def hit(self, ms, damage):
        self.add(12, ms, value=damage, flag0=1, flag1=1)

    def tick(self, ms, hp=None, rtt=0):
        self.add(16, ms, update_source=1)
        if hp is not None:
            self.hp = hp;self.add(6, ms+.1, update_source=1)
        self.sequence += 1
        if rtt:  # Sync trace: tick receive with its round-trip field, then the reply.
            self.add(40, ms+.15, bullet=rtt);self.add(41, ms+.18)
        self.add(17, ms+.2)

    def text(self, intervention=0):
        lines = [f'hit_probe_ready\tv8\tfatal_intervention={intervention}', 'timing\t1\t1\t1']
        lines += ['hit_probe_v4\t'+'\t'.join(str(row[k]) for k in FIELDS) for row in self.rows]
        return '\n'.join(lines)+'\n'


class ReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.binary = replay.build_driver(POLICY, cls.dir.name)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def scope(self, capture):
        results = replay.replay(self.binary, read_events(capture.text()))
        self.assertEqual(len(results), 1)
        return results[0]

    def test_burst_requests_before_recorded_death(self):
        c = Capture(300)
        for ms in range(0, 400, 200):c.tick(ms, 300)
        for i in range(5):c.hit(400+50*i, 70)
        c.tick(600, 0)
        r = self.scope(c)
        self.assertEqual(r['outcome'], 'escape_before_death')
        self.assertEqual(r['requests'][0], dict(ns=int(600e6)+1, reason='lethal', projected=-50))

    def test_v10_keeps_hit_through_untracked_loss(self):
        # Gap B: an unhooked 100 HP loss, then the server kills. v10 clears only by proof, so the
        # loss can't retire the tracked hit (v8 did, and missed this death).
        c = Capture(200)
        c.tick(0, 200, 250);c.hit(10, 100);c.tick(200, 100, 260);c.hit(300, 60);c.tick(400, 0, 270)
        r = self.scope(c)
        self.assertEqual(r['outcome'], 'escape_before_death')
        self.assertEqual(r['requests'][0]['projected'], -60)

    def test_quiet_then_stale_request_without_death(self):
        c = Capture(500)
        for ms in range(0, 1400, 200):c.tick(ms, 500 if ms < 400 else 450)
        c.hit(250, 60)  # never proved: no tick carries a round-trip value
        c.rows.sort(key=lambda row: row['ns'])
        r = self.scope(c)
        self.assertEqual(r['outcome'], 'quiet')
        c.hit(3500, 5)
        r = self.scope(c)
        self.assertEqual(r['outcome'], 'request_without_death')
        self.assertEqual(r['requests'][0]['reason'], 'stale')

    def test_passive_and_duplicate_captures(self):
        c = Capture(100);c.hit(0, 10)
        self.assertTrue(replay.passive(c.text()))
        self.assertFalse(replay.passive(c.text(intervention=1)))
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'a').mkdir();(Path(d)/'b').mkdir()
            (Path(d)/'a/guard-1.tsv').write_text(c.text())
            (Path(d)/'b/guard-1.tsv').write_text(c.text()[:-40])
            self.assertEqual(len(replay.captures([d])), 1)
            report = replay.run([d], [POLICY], self.dir.name)
            self.assertEqual(report['passive_outcomes'][str(POLICY)], {'quiet': 1})


if __name__ == '__main__':
    unittest.main()
