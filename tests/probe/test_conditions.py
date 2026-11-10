from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
import analyze_conditions as conditions
from analyze import FIELDS, read_events


class Capture:
    def __init__(self):
        self.rows = []

    def add(self, phase, ms, **values):
        row = dict.fromkeys(FIELDS, 0)
        row.update(id=len(self.rows) + 1, phase=phase, ns=int(ms * 1e6) + 1, generation=1, hp=300, max=300, valid=1)
        row.update(values); self.rows.append(row); return row['id']

    def hit(self, ms, damage, base, effects=(), ap=False):
        n = self.add(3, ms, value=damage)
        self.add(32, ms, correlation=n, value=base, owner=7, flag0=base, flag1=base, flag2=int(ap), flag3=7)
        if effects:
            self.add(31, ms, correlation=n, value=len(effects), projectile=int.from_bytes(bytes(effects), 'little'))

    def conditions(self, ms, bits):
        self.add(29, ms, projectile=bits, flag0=1, flag2=1)

    def events(self):
        return read_events('\n'.join('hit_probe_v4\t' + '\t'.join(str(r[k]) for k in FIELDS) for r in self.rows) + '\n')


class ConditionTests(unittest.TestCase):
    def test_effect_ids_map_to_gained_bits_and_base_damage_gives_def(self):
        c = Capture(); c.conditions(0, 0)
        c.hit(100, 48, 95, effects=[59]); c.conditions(120, 0x20000 << 32)  # Exposed arrives after the hit.
        c.conditions(2000, 0)
        c.hit(2100, 48, 95); c.hit(2400, 26, 73)  # Plain hits: base - damage = 47 both times.
        c.hit(3000, 95, 95, effects=[55], ap=True); c.conditions(3010, 0x4000000)
        summary = conditions.summarize(conditions.hits(c.events()))
        self.assertEqual(summary['effect_ids'], {'55': {'hits': 1, 'armor_broken': 1}, '59': {'hits': 1, 'exposed': 1}})
        self.assertEqual(summary['implied_def_on_plain_hits']['shot_a'], {47: 2})
        self.assertEqual(summary['implied_def_on_plain_hits']['shot_b'], {-41: 1, -19: 1})

    def test_gain_window_stops_at_the_next_hit(self):
        c = Capture(); c.conditions(0, 0); c.hit(100, 10, 10, effects=[5]); c.hit(200, 10, 10); c.conditions(300, 0x10)
        self.assertEqual([r['gained_raw'] for r in conditions.hits(c.events())], ['0x0', '0x10'])


if __name__ == '__main__':
    unittest.main()
