import importlib.util
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
spec = importlib.util.spec_from_file_location('untracked', ROOT / 'probe/analyze_untracked.py')
untracked = importlib.util.module_from_spec(spec); spec.loader.exec_module(untracked)
from analyze import FIELDS


class Capture:
    def __init__(self, hp=300):
        self.rows, self.hp = [], hp

    def add(self, phase, ms, **values):
        row = dict.fromkeys(FIELDS, 0)
        row.update(id=len(self.rows)+1, phase=phase, ns=int(ms*1e6)+1, generation=1, hp=self.hp, max=300, valid=1)
        row.update(values); self.rows.append(row); return row['id']

    def hit(self, ms, damage):
        self.add(3, ms, value=damage)

    def tick(self, ms, hp, **context):
        if context:
            self.add(29, ms, **context)
        entry = self.add(5, ms, callsite=0x184c115, update_source=1)
        self.hp = hp; self.add(6, ms+.1, correlation=entry, update_source=1)

    def text(self):
        return '\n'.join('hit_probe_v4\t'+'\t'.join(str(r[k]) for k in FIELDS) for r in self.rows)+'\n'


class UntrackedTests(unittest.TestCase):
    def test_healing_masked_hits_are_explained(self):
        c = Capture(); c.hit(0, 60); c.tick(200, 260); c.hit(300, 50); c.tick(400, 230)
        self.assertEqual(untracked.inspect(c.text())['unexplained'], [])

    def test_loss_without_report_is_strict_evidence(self):
        c = Capture(); c.hit(0, 60); c.tick(200, 240); c.tick(400, 228, flag0=4, owner=100)
        found = untracked.inspect(c.text())['unexplained']
        self.assertEqual([(u['unexplained'], u['context']) for u in found], [(12, 'frostbite_full')])

    def test_window_finds_loss_hidden_by_an_unapplied_report(self):
        c = Capture(); c.hit(0, 60); c.tick(200, 300); c.tick(3000, 250)
        self.assertEqual(untracked.inspect(c.text())['unexplained'], [])
        self.assertEqual(untracked.inspect(c.text(), 2000)['unexplained'][0]['unexplained'], 50)

    def test_reported_hits_leave_no_excess(self):
        c = Capture(); c.hit(0, 93); c.tick(400, 208); c.hit(500, 45); c.hit(550, 45); c.tick(900, 119)
        self.assertEqual(untracked.inspect(c.text())['excess'], [])

    def test_bleeding_drain_is_excess_even_when_earlier_damage_is_unspent(self):
        c = Capture(); c.hit(0, 90); c.tick(400, 250)  # 40 HP of this hit was healed in the same update.
        c.add(29, 2000, projectile=0x8000); c.tick(2100, 247); c.hit(2150, 43); c.tick(2500, 201)
        result = untracked.inspect(c.text())
        self.assertEqual(result['unexplained'], [])  # The unspent 40 HP hides the drain from the strict test.
        self.assertEqual([(x['excess'], x['context']) for x in result['excess']],
                         [(50, 'report_larger_than_loss'), (3, 'bleeding'), (3, 'bleeding')])
        self.assertEqual(result['expired_reports'], 1)

    def test_debuff_carried_by_a_hit_is_excess_with_changed_conditions(self):
        c = Capture(); c.hit(0, 48); c.add(29, 20, projectile=0x2000000000000); c.tick(600, 205)
        found = untracked.inspect(c.text())['excess']
        self.assertEqual([(x['excess'], x['attributed'], x['context']) for x in found], [(47, [48], 'conditions_changed')])

    def test_hit_masked_by_healing_is_marked_ambiguous(self):
        c = Capture(); c.hit(0, 93); c.tick(400, 298)
        self.assertEqual(untracked.inspect(c.text())['excess'][0]['context'], 'report_larger_than_loss')

    def test_max_hp_change_is_not_damage(self):
        c = Capture(); c.tick(0, 300); c.rows[-2]['hp'] = 340; c.rows[-2]['max'] = 300
        self.assertEqual(untracked.inspect(c.text())['max_hp_changes'], 1)


if __name__ == '__main__':
    unittest.main()
