import importlib.util
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
spec = importlib.util.spec_from_file_location('proof', ROOT / 'probe/analyze_proof.py')
proof = importlib.util.module_from_spec(spec); spec.loader.exec_module(proof)
from analyze import FIELDS


def capture(rtts, drop_tick, hit_ms=50, damage=60):
    """Ticks every 200 ms (build 1000 + 200 j), one reply per tick, one hit; HP drops at drop_tick."""
    rows, hp = [], 300
    def add(phase, ms, **values):
        row = dict.fromkeys(FIELDS, 0)
        row.update(id=len(rows) + 1, phase=phase, ns=int(ms * 1e6) + 1, generation=1, hp=hp, max=300, valid=1)
        row.update(values); rows.append(row); return row['id']
    for j, rtt in enumerate(rtts):
        ms = 200 * j
        if j == 0: add(3, hit_ms, value=damage)
        if j == drop_tick: hp -= damage - 1
        tick = add(40, ms, tick_sequence=j, server_time=1000 + 200 * j, bullet=rtt, correlation=1000 + j)
        add(6, ms + .1, update_context=1000 + j, update_source=1)
        add(41, ms + .2, tick_sequence=j, server_time=1000 + 200 * j)
        if j == 0: rows.sort(key=lambda r: r['ns'])
    return '\n'.join('hit_probe_v4\t' + '\t'.join(str(r[k]) for k in FIELDS) for r in rows) + '\n'


class ProofTests(unittest.TestCase):
    # The hit (50 ms) travels ahead of the reply to tick 1 (sent at 200 ms, build 1200).
    def test_proof_lands_on_the_applying_tick(self):
        # Tick 3's new round trip 300 dates reply 1 at 1500, between builds 1400 and 1600.
        r = proof.check(capture([250, 260, 310, 300, 290, 280], drop_tick=3))
        self.assertEqual((r['hits'], r['early'], r['late_ticks'], r['c_needed_ms']), (1, 0, {0: 1}, 0))

    def test_hit_applied_after_a_proving_tick_is_an_early_clear(self):
        r = proof.check(capture([250, 260, 310, 300, 290, 280], drop_tick=4))
        self.assertEqual((r['early'], r['c_needed_ms']), (1, 101))  # Tick 3 was built 100 ms after the bound.
        self.assertEqual(proof.check(capture([250, 260, 310, 300, 290, 280], drop_tick=4), c_ms=101)['early'], 0)

    def test_repeated_round_trip_proves_nothing(self):
        # Tick 3 repeats 310 (no new reply); tick 4's 500 dates reply 1 at 1700, one tick late.
        r = proof.check(capture([250, 260, 310, 310, 500, 280], drop_tick=3))
        self.assertEqual((r['early'], r['late_ticks']), (0, {1: 1}))

    def test_reply_sent_before_the_hit_proves_nothing(self):
        # Tick 2's 310 dates reply 0 (sent before the hit) at 1310; later ticks repeat it.
        r = proof.check(capture([250, 260, 310, 310, 310, 310], drop_tick=2))
        self.assertEqual((r['hits'], r['skipped']['no_proof']), (0, 1))


if __name__ == '__main__':
    unittest.main()
