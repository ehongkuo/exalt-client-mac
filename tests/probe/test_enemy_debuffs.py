import importlib.util
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('enemy_debuffs', ROOT / 'probe/enemy_debuffs.py')
debuffs = importlib.util.module_from_spec(spec); spec.loader.exec_module(debuffs)

XML = b'''<Objects>
<Object type="0x1" id="Zombie Hulk">
  <Enemy/>
  <Projectile id="0"><Damage>45</Damage><ConditionEffect duration="2.4">Armor Broken</ConditionEffect></Projectile>
  <Projectile id="1"><MinDamage>10</MinDamage><MaxDamage>20</MaxDamage><ArmorPiercing/>
    <ConditionEffect duration="3">Curse</ConditionEffect><ConditionEffect duration="1">Slowed</ConditionEffect></Projectile>
</Object>
<Object type="0x2" id="Friendly Pet"><Projectile id="0"><Damage>5</Damage><ConditionEffect duration="1">Exposed</ConditionEffect></Projectile></Object>
</Objects>'''


class EnemyDebuffTests(unittest.TestCase):
    def test_lists_enemy_debuff_projectiles_only(self):
        rows = debuffs.find(XML)
        self.assertEqual([(r['effect'], r['enemy'], r['projectile'], r['damage'], r['duration'], r['armor_piercing']) for r in rows],
                         [('Armor Broken', 'Zombie Hulk', '0', '45', '2.4', False), ('Curse', 'Zombie Hulk', '1', '10-20', '3', True)])


if __name__ == '__main__':
    unittest.main()
