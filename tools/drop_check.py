#!/usr/bin/env python3
"""Checks a drop-rate capture against RealmHound (issue #38). Read-only on both sides.

    tools/drop_check.py [--db PATH] [--realmhound DIR] [--session N]

Compares one capture session in drop_rates.db (default: the staging app's, latest session) with
RealmHound's loot and boss-fight records for the same time window, and prints what a staging run
has to answer: do your bags match, does each link to a kill of the right mob, how long after your
last hit removal kills come, which axis mapping links kills to bags, and which of your stats or
map fields carry RealmHound's seed, character id and loot factors. It never prints character or
account names.
"""
import argparse
import glob
import os
import sqlite3
import statistics
import sys

STAGING_DB = '~/Library/Application Support/Exalt Client Mac Staging/drop_rates.db'
REALMHOUND = '~/Library/Application Support/RealmHound/accounts'
AXES = {'y': lambda k: k[1], '-y': lambda k: -k[1], 'z': lambda k: k[2], '-z': lambda k: -k[2]}
FACTORS = ('fame', 'is_seasonal', 'exalt_bonus', 'loot_drop_active', 'loot_tier_active', 'char_id', 'class_id')


def read_only(path):
    return sqlite3.connect(f'file:{path}?mode=ro', uri=True)


def spread(values):
    if not values: return 'none'
    values = sorted(values)
    pick = lambda q: values[min(len(values) - 1, int(q * len(values)))]
    return f'n={len(values)} min={values[0]} median={pick(0.5)} p95={pick(0.95)} max={values[-1]}'


def realmhound_drops(folder, start, end):
    """Your drops RealmHound saved in the window, with their items."""
    drops = []
    for path in glob.glob(os.path.join(os.path.expanduser(folder), '*', 'databases', 'loot_history.db')):
        db = read_only(path)
        for row in db.execute(f'''SELECT id, timestamp / 1000.0, bag_type, mob_type, map_seed, {", ".join(FACTORS)}
                                  FROM loot_drops WHERE timestamp BETWEEN ? AND ?''', (start * 1000, end * 1000)):
            items = sorted(r[0] for r in db.execute('SELECT item_id FROM loot_items WHERE drop_id = ?', (row[0],)))
            drops.append(dict(time=row[1], bag_type=row[2], mob_type=row[3], seed=row[4], items=items,
                              **dict(zip(FACTORS, row[5:]))))
    return drops


def realmhound_bosses(folder, start, end):
    bosses = []
    for path in glob.glob(os.path.join(os.path.expanduser(folder), '*', 'databases', 'combat_history.db')):
        bosses += read_only(path).execute('''SELECT ended_at / 1000.0, boss_object_type FROM fights
                                             WHERE killed = 1 AND ended_at BETWEEN ? AND ?''', (start * 1000, end * 1000)).fetchall()
    return bosses


def check(db, drops, bosses, session, out=print):
    bags = {}
    for bag, time, bag_type, x, y, kill, map_id in db.execute(
            'SELECT b.id, b.time, b.bag_type, b.x, b.y, b.kill, b.map FROM bags b JOIN maps m ON m.id = b.map WHERE m.session = ?', (session,)):
        items = sorted(r[0] for r in db.execute('SELECT item_type FROM bag_items WHERE bag = ?', (bag,)))
        bags[bag] = dict(time=time, type=bag_type, x=x, y=y, kill=kill, map=map_id, items=items)
    kills = {r[0]: r[1:] for r in db.execute('''SELECT k.id, k.time, k.mob_type, k.x, k.y, k.z, k.landed_by, k.since_hit_ms, k.map
                                                FROM kills k JOIN maps m ON m.id = k.map WHERE m.session = ?''', (session,))}
    out(f'Capture: {len(bags)} bags, {len(kills)} kills. RealmHound: {len(drops)} of your drops, {len(bosses)} boss kills.')

    # 1. Your bags, matched by type and items within 3 s.
    matched = []
    for d in drops:
        near = [(abs(b['time'] - d['time']), i) for i, b in bags.items()
                if b['type'] == d['bag_type'] and b['items'] == d['items'] and abs(b['time'] - d['time']) < 3]
        if near: matched.append((d, bags[min(near)[1]]))
    out(f'\n1. Bags: {len(matched)} of {len(drops)} RealmHound drops match a captured bag '
        f'(offset ms: {spread([round((b["time"] - d["time"]) * 1000) for d, b in matched])}).')

    # 2. Each matched bag's kill: linked, right mob, how it was seen.
    linked = [(d, b, kills[b['kill']]) for d, b in matched if b['kill'] in kills]
    right = [x for x in linked if x[2][1] == x[0]['mob_type']]
    out(f'2. Kills: {len(linked)} of {len(matched)} matched bags link to a kill; {len(right)} of those are the mob RealmHound names.')
    by = {}
    for _, _, k in linked: by[k[5]] = by.get(k[5], 0) + 1
    out(f'   seen as: {by or "-"}')
    out(f'   ms from your last hit, linked kills: {spread([k[6] for _, _, k in linked if k[6] is not None])}')
    for d, b in matched:
        if b['kill'] not in kills:
            out(f'   unlinked: bag {b["type"]} at {b["time"]:.3f}, RealmHound mob {d["mob_type"]}')

    # 3. Removal kills with no bag: where to cut "died" from "left your view".
    with_bag = {b['kill'] for b in bags.values()}
    lone = [k[6] for i, k in kills.items() if k[5] == 'removed' and i not in with_bag and k[6] is not None]
    out(f'3. Removal kills without a bag, ms from your last hit: {spread(lone)}')
    for cut in (500, 1000, 2000):
        out(f'   within {cut} ms: {sum(v <= cut for v in lone)}')

    # 4. Which float3 axis is the bag's tile y: distance from each matched bag to its RealmHound mob's nearest kill.
    out('4. Axis mapping, kill to bag distance (tiles) over matched bags:')
    for name, axis in AXES.items():
        best = []
        for d, b in matched:
            near = [((k[2] - b['x']) ** 2 + (axis(k[2:5]) - b['y']) ** 2) ** 0.5 for k in kills.values()
                    if k[7] == b['map'] and k[1] == d['mob_type'] and -2 <= b['time'] - k[0] <= 2]
            if near: best.append(round(min(near), 2))
        out(f'   {name:>2}: {spread(best)}')

    # 5. Boss kills.
    found = sum(any(k[1] == boss and abs(k[0] - t) < 5 for k in kills.values()) for t, boss in bosses)
    out(f'5. Bosses: {found} of {len(bosses)} RealmHound boss kills have a kill of that mob within 5 s.')

    # 6. Map info and your stats against RealmHound's seed, character and loot factors.
    def map_of(bag): return bag['map']
    info = {r[0]: r[1:] for r in db.execute('''SELECT map, class, info_30, info_34, info_38, info_50, info_54,
                                               connection_10c, connection_110, info_28, info_48, info_58 FROM map_info''')}
    names = ('class', 'info_30', 'info_34', 'info_38', 'info_50', 'info_54', 'connection_10c', 'connection_110')
    out('6. Fields that equal RealmHound on every matched drop:')
    rows = [(d, info.get(map_of(b))) for d, b in matched if info.get(map_of(b))]
    for column in ('seed', 'char_id', 'class_id'):
        hits = [n for i, n in enumerate(names) if rows and all(r[i] == d[column] for d, r in rows)]
        out(f'   RealmHound {column}: {", ".join(hits) or "no match"}')
    stats = {}
    for d, b in matched:
        values = {}
        for stat, value in db.execute('''SELECT stat_type, value FROM player_stats WHERE map = ? AND time <= ?
                                         ORDER BY time''', (b['map'], b['time'] + 0.5)):
            values[stat] = value
        stats[id(d)] = values
    for column in ('fame', 'is_seasonal', 'exalt_bonus', 'loot_drop_active', 'loot_tier_active'):
        seen = {d[column] for d, _ in matched}
        same = [s for s in sorted({s for v in stats.values() for s in v})
                if matched and all(stats[id(d)].get(s) == d[column] for d, _ in matched)]
        active = [s for s in sorted({s for v in stats.values() for s in v})
                  if len(seen) > 1 and all((stats[id(d)].get(s, 0) > 0) == bool(d[column]) for d, _ in matched)]
        out(f'   {column} (RealmHound values {sorted(seen)}): equal stats {same or "-"}, '
            f'stats nonzero exactly when set {active or ("-" if len(seen) > 1 else "(constant, untestable)")}')
    texts = sorted({r[8:] for r in info.values()})
    out('   map info strings (realm, 0x48, 0x58), distinct: ' + ('; '.join('|'.join(t) for t in texts[:12]) or '-'))


def self_test():
    """Synthetic capture and RealmHound rows: one bag linked to a removal kill, one lone removal."""
    db = sqlite3.connect(':memory:')
    db.executescript('''
        CREATE TABLE maps(id INTEGER PRIMARY KEY, session INTEGER, generation INTEGER, name TEXT, entered REAL);
        CREATE TABLE bags(id INTEGER PRIMARY KEY, map INTEGER, time REAL, object_id INTEGER, bag_type INTEGER, x REAL, y REAL, kill INTEGER);
        CREATE TABLE bag_items(bag INTEGER, slot INTEGER, item_type INTEGER);
        CREATE TABLE kills(id INTEGER PRIMARY KEY, map INTEGER, time REAL, object_id INTEGER, mob_type INTEGER, x REAL, y REAL, z REAL,
            damage_projectile INTEGER, damage_projectile_alt INTEGER, damage_ability INTEGER, max_hp INTEGER, landed_by TEXT, since_hit_ms INTEGER);
        CREATE TABLE map_info(map INTEGER PRIMARY KEY, class INTEGER, info_30 INTEGER, info_34 INTEGER, info_38 INTEGER, info_50 INTEGER,
            info_54 INTEGER, connection_10c INTEGER, connection_110 INTEGER, info_28 TEXT, info_48 TEXT, info_58 TEXT);
        CREATE TABLE player_stats(map INTEGER, time REAL, stat_type INTEGER, value INTEGER);
        INSERT INTO maps VALUES (1, 1, 2, 'Abyss of Demons', 100);
        INSERT INTO kills VALUES (1, 1, 110.0, 50, 2314, 10, 0, -20, 0, 0, 0, 20000, 'removed', 240);
        INSERT INTO kills VALUES (2, 1, 115.0, 51, 1650, 90, 0, -90, 0, 0, 0, 900, 'removed', 4000);
        INSERT INTO bags VALUES (1, 1, 109.99, 60, 1295, 10.2, 20.1, 1);
        INSERT INTO bag_items VALUES (1, 0, 2856);
        INSERT INTO map_info VALUES (1, 782, 4242, 0, 0, 0, 0, 1463, 7, 'Zephyr', 'DRAINED_3;|A', '');
        INSERT INTO player_stats VALUES (1, 100, 39, 2500), (1, 100, 58, 0);
    ''')
    drops = [dict(time=110.2, bag_type=1295, mob_type=2314, seed=4242, items=[2856], fame=2500, is_seasonal=1,
                  exalt_bonus=0, loot_drop_active=0, loot_tier_active=0, char_id=1463, class_id=782)]
    lines = []
    check(db, drops, [(110.1, 2314)], 1, out=lines.append)
    text = '\n'.join(lines)
    for expected in ('1 of 1 RealmHound drops match', '1 of 1 matched bags link to a kill; 1 of those', "{'removed': 1}",
                     'within 1000 ms: 0', '-z: n=1 min=0.22', '1 of 1 RealmHound boss kills', 'seed: info_30',
                     'char_id: connection_10c', 'class_id: class', 'fame (RealmHound values [2500]): equal stats [39]'):
        assert expected in text, (expected, text)
    print('drop_check self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--db', default=STAGING_DB)
    parser.add_argument('--realmhound', default=REALMHOUND)
    parser.add_argument('--session', type=int, help='capture session id (default: latest)')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test: return self_test()
    db = read_only(os.path.expanduser(args.db))
    row = db.execute('SELECT id, started, coalesce(ended, started + 86400) FROM sessions WHERE (? IS NULL OR id = ?) '
                     'ORDER BY id DESC LIMIT 1', (args.session, args.session)).fetchone()
    if not row: sys.exit('No capture session in ' + args.db)
    session, start, end = row
    first, last = db.execute('''SELECT min(t), max(t) FROM (SELECT b.time t FROM bags b JOIN maps m ON m.id = b.map WHERE m.session = ?
                                UNION ALL SELECT k.time FROM kills k JOIN maps m ON m.id = k.map WHERE m.session = ?)''',
                             (session, session)).fetchone()
    start, end = (first or start) - 5, (last or end) + 5
    print(f'Session {session}: {start:.0f} to {end:.0f}')
    check(db, realmhound_drops(args.realmhound, start, end), realmhound_bosses(args.realmhound, start, end), session)


if __name__ == '__main__':
    main()
