#!/usr/bin/env python3
"""Backfills boss kills from RealmHound into a capture session that has none (issue #41).

    tools/drop_backfill.py [--db PATH] [--realmhound DIR] [--session N]

Staging run 1 captured bags but no kills (the guard then relied on the game's kill flag). This adds
RealmHound's boss kills from the session's window as kills (landed_by 'realmhound', your damage from
its fight record) and links the bags RealmHound credits to those bosses to them. Minion kills stay
missing: RealmHound records boss fights only. RealmHound's files are opened read-only. Running it
again replaces the earlier backfill. Quit the app that owns the database first.
"""
import argparse
import glob
import os
import sqlite3
import sys

from drop_check import REALMHOUND, STAGING_DB, read_only, realmhound_drops


def realmhound_kills(folder, start, end):
    """Boss kills in the window: (ended, boss type, max HP, your damage)."""
    kills = []
    for path in glob.glob(os.path.join(os.path.expanduser(folder), '*', 'databases', 'combat_history.db')):
        kills += read_only(path).execute('''
            SELECT f.ended_at / 1000.0, f.boss_object_type, f.boss_max_hp,
                   coalesce((SELECT sum(p.damage) FROM fight_participants p WHERE p.fight_id = f.id AND p.is_local), 0)
            FROM fights f WHERE f.killed = 1 AND f.ended_at BETWEEN ? AND ?''', (start * 1000, end * 1000)).fetchall()
    return sorted(kills)


def backfill(db, drops, kills, session, out=print):
    own = db.execute('''SELECT count(*) FROM kills k JOIN maps m ON m.id = k.map
                        WHERE m.session = ? AND k.landed_by <> 'realmhound' ''', (session,)).fetchone()[0]
    if own: raise SystemExit(f'Session {session} has {own} captured kills: a backfill would count them twice.')
    db.execute('''UPDATE bags SET kill = NULL WHERE kill IN (SELECT k.id FROM kills k JOIN maps m ON m.id = k.map
                  WHERE m.session = ? AND k.landed_by = 'realmhound')''', (session,))
    db.execute('''DELETE FROM kills WHERE landed_by = 'realmhound' AND map IN (SELECT id FROM maps WHERE session = ?)''', (session,))
    maps = db.execute('SELECT entered, id FROM maps WHERE session = ? ORDER BY entered', (session,)).fetchall()
    added = []
    for ended, boss, max_hp, damage in kills:
        inside = [m for entered, m in maps if entered <= ended]
        if not inside: continue
        db.execute('''INSERT INTO kills(map, time, mob_type, damage_projectile, damage_projectile_alt, damage_ability, max_hp, landed_by)
                      VALUES (?, ?, ?, ?, 0, 0, ?, 'realmhound')''', (inside[-1], ended, boss, damage, max_hp))
        added.append((db.execute('SELECT last_insert_rowid()').fetchone()[0], ended, boss))
    bags = {}
    for bag, time, bag_type in db.execute('''SELECT b.id, b.time, b.bag_type FROM bags b JOIN maps m ON m.id = b.map
                                             WHERE m.session = ? AND b.kill IS NULL''', (session,)):
        items = sorted(r[0] for r in db.execute('SELECT item_type FROM bag_items WHERE bag = ?', (bag,)))
        bags[bag] = (time, bag_type, items)
    linked = 0
    for d in drops:
        # RealmHound's own link: its drop names the boss, a fraction of a second after the fight ends.
        kill = next((k for k, ended, boss in added if boss == d['mob_type'] and -1 <= d['time'] - ended <= 3), None)
        near = sorted((abs(t - d['time']), b) for b, (t, bag_type, items) in bags.items()
                      if bag_type == d['bag_type'] and items == d['items'] and abs(t - d['time']) < 3)
        if kill and near:
            db.execute('UPDATE bags SET kill = ? WHERE id = ?', (kill, near[0][1]))
            del bags[near[0][1]]
            linked += 1
    db.commit()
    out(f'Session {session}: {len(added)} boss kills from RealmHound, {linked} bags linked to them.')
    return len(added), linked


def self_test():
    db = sqlite3.connect(':memory:')
    db.executescript('''
        CREATE TABLE maps(id INTEGER PRIMARY KEY, session INTEGER, generation INTEGER, name TEXT, entered REAL);
        CREATE TABLE kills(id INTEGER PRIMARY KEY, map INTEGER, time REAL, object_id INTEGER, mob_type INTEGER, damage_projectile INTEGER,
            damage_projectile_alt INTEGER, damage_ability INTEGER, max_hp INTEGER, landed_by TEXT);
        CREATE TABLE bags(id INTEGER PRIMARY KEY, map INTEGER, time REAL, bag_type INTEGER, kill INTEGER);
        CREATE TABLE bag_items(bag INTEGER, slot INTEGER, item_type INTEGER);
        INSERT INTO maps VALUES (1, 1, 1, 'Nexus', 50), (2, 1, 2, 'Abyss of Demons', 100);
        INSERT INTO bags VALUES (1, 2, 110.2, 1296, NULL), (2, 2, 110.3, 1287, NULL), (3, 2, 140, 1296, NULL);
        INSERT INTO bag_items VALUES (1, 0, 3073), (3, 0, 3073);
    ''')
    drops = [dict(time=110.25, bag_type=1296, mob_type=2314, items=[3073]),   # the boss's white bag
             dict(time=140.0, bag_type=1296, mob_type=1650, items=[3073])]    # a minion's: no kill to link to
    assert backfill(db, drops, [(110.0, 2314, 20000, 9000)], 1, out=lambda _: None) == (1, 1)
    assert db.execute('SELECT map, mob_type, damage_projectile FROM kills').fetchall() == [(2, 2314, 9000)], 'kill in its map'
    assert db.execute('SELECT id FROM bags WHERE kill IS NOT NULL').fetchall() == [(1,)], 'only the bag RealmHound credits to the boss'
    assert backfill(db, drops, [(110.0, 2314, 20000, 9000)], 1, out=lambda _: None) == (1, 1), 'a rerun replaces the backfill'
    assert db.execute('SELECT count(*) FROM kills').fetchone() == (1,)
    db.execute("INSERT INTO kills(map, time, mob_type, landed_by) VALUES (2, 1, 1, 'removed')")
    try:
        backfill(db, drops, [], 1, out=lambda _: None); raise AssertionError('captured kills must block a backfill')
    except SystemExit: pass
    print('drop_backfill self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--db', default=STAGING_DB)
    parser.add_argument('--realmhound', default=REALMHOUND)
    parser.add_argument('--session', type=int, help='capture session id (default: latest)')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test: return self_test()
    db = sqlite3.connect(os.path.expanduser(args.db))
    db.execute('PRAGMA busy_timeout = 5000')
    row = db.execute('SELECT id, started, coalesce(ended, started + 86400) FROM sessions WHERE (? IS NULL OR id = ?) '
                     'ORDER BY id DESC LIMIT 1', (args.session, args.session)).fetchone()
    if not row: sys.exit('No capture session in ' + args.db)
    session, start, end = row
    backfill(db, realmhound_drops(args.realmhound, start - 5, end + 5), realmhound_kills(args.realmhound, start - 5, end + 5), session)


if __name__ == '__main__':
    main()
