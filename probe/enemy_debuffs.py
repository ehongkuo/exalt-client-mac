#!/usr/bin/env python3
"""List enemy projectiles that inflict a damage-changing debuff, from the game's own object XML.

The XML is plain text inside resources.assets, so no Unity extraction is needed. Use the list to pick
test enemies for the condition capture (hardening plan Phase 0 item 4) and to check the debuff charge
(Phase 3 C) against real projectile damage.
"""
import argparse
import json
import mmap
from pathlib import Path
import re

ASSETS = Path.home() / '.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Resources/Data/resources.assets'
DEBUFFS = ('Armor Broken', 'Exposed', 'Curse')
OBJECT = re.compile(rb'<Object type="([^"]*)" id="([^"]*)"[^>]*>(.*?)</Object>', re.S)
PROJECTILE = re.compile(rb'<Projectile([^>]*)>(.*?)</Projectile>', re.S)
EFFECT = re.compile(rb'<ConditionEffect([^>]*)>([^<]*)</ConditionEffect>')


def tag(body, name):
    found = re.search(rb'<%s>([^<]*)</%s>' % (name, name), body)
    return found.group(1).decode() if found else None


def find(data, debuffs=DEBUFFS):
    """One row per enemy projectile and debuff."""
    rows = []
    for obj in OBJECT.finditer(data):
        body = obj.group(3)
        if not re.search(rb'<Enemy\s*/>', body):
            continue
        for shot in PROJECTILE.finditer(body):
            for attrs, name in EFFECT.findall(shot.group(2)):
                name = name.decode().strip()
                if name not in debuffs:
                    continue
                duration = re.search(rb'duration="([^"]*)"', attrs)
                damage = tag(shot.group(2), b'Damage')
                low, high = tag(shot.group(2), b'MinDamage'), tag(shot.group(2), b'MaxDamage')
                rows.append(dict(effect=name, enemy=obj.group(2).decode(), type=obj.group(1).decode(),
                                 projectile=(re.search(rb'id="([^"]*)"', shot.group(1)) or [b'', b'0'])[1].decode(),
                                 damage=damage or (f'{low}-{high}' if low else None),
                                 duration=duration.group(1).decode() if duration else None,
                                 armor_piercing=b'<ArmorPiercing' in shot.group(2)))
    return sorted({json.dumps(r, sort_keys=True): r for r in rows}.values(),
                  key=lambda r: (r['effect'], r['enemy'], r['projectile']))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--assets', type=Path, default=ASSETS)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    with args.assets.open('rb') as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        rows = find(data)
    if args.json:
        print(json.dumps(rows, indent=1))
        return
    for r in rows:
        print('\t'.join(str(r[k]) for k in ('effect', 'enemy', 'projectile', 'damage', 'duration', 'armor_piercing')))


if __name__ == '__main__':
    main()
