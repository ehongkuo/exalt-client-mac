#!/usr/bin/env python3
"""Joins one drop_rates.db into another, once each game (issue #49).

    tools/drop_merge.py TARGET SOURCE      (both apps closed)
    tools/drop_merge.py --self-test

A game is one loot file, so `sessions.file` is the key. A game only in SOURCE is copied into TARGET with
new ids; a game in both keeps the copy with more imported bytes (a loot file only grows, so it holds the
other); anything else is left alone. SOURCE is opened read-only. The catalog tables (objects, items,
dungeons) are not copied: the app rebuilds them from RealmHound's XML. All in one transaction.
"""
import os
import sqlite3
import sys
import tempfile
from urllib.parse import quote

COLUMNS = {   # data tables, keyed to their session through maps
    'maps': 'id, session, generation, name, entered',
    'kills': 'id, map, time, object_id, mob_type, x, y, z, damage_projectile, damage_projectile_alt, damage_ability, '
             'max_hp, landed_by, since_hit_ms, damage_others',
    'bags': 'id, map, time, object_id, bag_type, x, y, kill',
}
SESSION = 'id, file, started, ended, pid, format, game_build, app_version, status, summary, imported_bytes'


def counts(db, schema='main'):
    return {t: db.execute(f'SELECT count(*) FROM {schema}.{t}').fetchone()[0]
            for t in ('sessions', 'maps', 'kills', 'bags', 'bag_items', 'bag_stats', 'capture_gaps', 'map_info', 'player_stats')}


def merge(target, source):
    """Returns (copied, replaced) game counts."""
    db = sqlite3.connect(f'file:{quote(os.path.abspath(target))}', uri=True, isolation_level=None)
    db.execute('PRAGMA busy_timeout = 5000')
    db.execute('ATTACH ? AS src', (f'file:{quote(os.path.abspath(source))}?mode=ro',))
    db.execute('BEGIN IMMEDIATE')
    try:
        new = [r[0] for r in db.execute('SELECT id FROM src.sessions WHERE file NOT IN (SELECT file FROM main.sessions)')]
        newer = db.execute('''SELECT s.id, m.id FROM src.sessions s JOIN main.sessions m USING(file)
                              WHERE s.imported_bytes > m.imported_bytes''').fetchall()
        # The shorter copy of a game goes, rows and all.
        for _, old in newer:
            maps = f'(SELECT id FROM maps WHERE session = {old})'
            bags = f'(SELECT id FROM bags WHERE map IN {maps})'
            for sql in (f'DELETE FROM bag_items WHERE bag IN {bags}', f'DELETE FROM bag_stats WHERE bag IN {bags}',
                        f'DELETE FROM bags WHERE map IN {maps}', f'DELETE FROM kills WHERE map IN {maps}',
                        f'DELETE FROM map_info WHERE map IN {maps}', f'DELETE FROM player_stats WHERE map IN {maps}',
                        f'DELETE FROM maps WHERE session = {old}', f'DELETE FROM capture_gaps WHERE session = {old}',
                        f'DELETE FROM sessions WHERE id = {old}'):
                db.execute(sql)
        chosen = new + [s for s, _ in newer]
        if chosen:
            # New ids: every source id shifted past the target's largest, so links (bags.kill too) stay intact.
            off = {t: db.execute(f'SELECT coalesce(max(id), 0) FROM main.{t}').fetchone()[0] for t in ('sessions', 'maps', 'kills', 'bags')}
            ids = ','.join(map(str, chosen))
            maps = f'(SELECT id FROM src.maps WHERE session IN ({ids}))'
            bags = f'(SELECT id FROM src.bags WHERE map IN {maps})'
            shift = lambda cols, **by: ', '.join(f'{c} + {by[c]}' if c in by else c for c in cols.split(', '))
            db.execute(f"INSERT INTO sessions({SESSION}) SELECT {shift(SESSION, id=off['sessions'])} FROM src.sessions WHERE id IN ({ids})")
            db.execute(f"INSERT INTO maps({COLUMNS['maps']}) SELECT {shift(COLUMNS['maps'], id=off['maps'], session=off['sessions'])} "
                       f"FROM src.maps WHERE session IN ({ids})")
            db.execute(f"INSERT INTO kills({COLUMNS['kills']}) SELECT {shift(COLUMNS['kills'], id=off['kills'], map=off['maps'])} "
                       f"FROM src.kills WHERE map IN {maps}")
            db.execute(f"INSERT INTO bags({COLUMNS['bags']}) SELECT {shift(COLUMNS['bags'], id=off['bags'], map=off['maps'], kill=off['kills'])} "
                       f"FROM src.bags WHERE map IN {maps}")   # a NULL kill stays NULL
            db.execute(f"INSERT INTO bag_items(bag, slot, item_type) SELECT bag + {off['bags']}, slot, item_type FROM src.bag_items WHERE bag IN {bags}")
            db.execute(f"INSERT INTO bag_stats(bag, stat_type, value, text) SELECT bag + {off['bags']}, stat_type, value, text "
                       f"FROM src.bag_stats WHERE bag IN {bags}")
            db.execute(f"INSERT INTO capture_gaps(session, time, lost, reason) SELECT session + {off['sessions']}, time, lost, reason "
                       f"FROM src.capture_gaps WHERE session IN ({ids})")
            info = 'class, info_30, info_34, info_38, info_50, info_54, connection_10c, connection_110, info_28, info_48, info_58'
            db.execute(f"INSERT INTO map_info(map, {info}) SELECT map + {off['maps']}, {info} FROM src.map_info WHERE map IN {maps}")
            db.execute(f"INSERT INTO player_stats(map, time, stat_type, value) SELECT map + {off['maps']}, time, stat_type, value "
                       f"FROM src.player_stats WHERE map IN {maps}")
        db.execute('COMMIT')
    except Exception:
        db.execute('ROLLBACK')
        raise
    finally:
        db.close()
    return len(new), len(newer)


SCHEMA = '''
CREATE TABLE sessions(id INTEGER PRIMARY KEY, file TEXT NOT NULL UNIQUE, started REAL, ended REAL, pid INTEGER, format INTEGER,
    game_build TEXT, app_version TEXT, status TEXT, summary TEXT, imported_bytes INTEGER NOT NULL DEFAULT 0);
CREATE TABLE maps(id INTEGER PRIMARY KEY, session INTEGER NOT NULL, generation INTEGER NOT NULL, name TEXT, entered REAL, UNIQUE(session, generation));
CREATE TABLE kills(id INTEGER PRIMARY KEY, map INTEGER NOT NULL, time REAL NOT NULL, object_id INTEGER, mob_type INTEGER, x REAL, y REAL, z REAL,
    damage_projectile INTEGER, damage_projectile_alt INTEGER, damage_ability INTEGER, max_hp INTEGER, landed_by TEXT,
    since_hit_ms INTEGER, damage_others INTEGER);
CREATE TABLE bags(id INTEGER PRIMARY KEY, map INTEGER NOT NULL, time REAL NOT NULL, object_id INTEGER, bag_type INTEGER, x REAL, y REAL, kill INTEGER);
CREATE TABLE bag_items(bag INTEGER NOT NULL, slot INTEGER NOT NULL, item_type INTEGER NOT NULL);
CREATE TABLE bag_stats(bag INTEGER NOT NULL, stat_type INTEGER, value INTEGER, text TEXT);
CREATE TABLE capture_gaps(session INTEGER NOT NULL, time REAL, lost INTEGER, reason TEXT);
CREATE TABLE map_info(map INTEGER PRIMARY KEY, class INTEGER, info_30 INTEGER, info_34 INTEGER, info_38 INTEGER, info_50 INTEGER,
    info_54 INTEGER, connection_10c INTEGER, connection_110 INTEGER, info_28 TEXT, info_48 TEXT, info_58 TEXT);
CREATE TABLE player_stats(map INTEGER NOT NULL, time REAL NOT NULL, stat_type INTEGER, value INTEGER);
'''


def make(path, games):
    """games: {file: (bytes, kills)}; each kill gets one bag linked to it, with one item, one stat and a gap."""
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    for file, (size, kills) in games.items():
        s = db.execute('INSERT INTO sessions(file, imported_bytes) VALUES (?, ?)', (file, size)).lastrowid
        m = db.execute('INSERT INTO maps(session, generation) VALUES (?, 1)', (s,)).lastrowid
        db.execute('INSERT INTO map_info(map, class) VALUES (?, 7)', (m,))
        db.execute('INSERT INTO player_stats(map, time) VALUES (?, 0)', (m,))
        db.execute('INSERT INTO capture_gaps(session) VALUES (?)', (s,))
        for i in range(kills):
            k = db.execute('INSERT INTO kills(map, time, object_id) VALUES (?, ?, ?)', (m, i, i)).lastrowid
            b = db.execute('INSERT INTO bags(map, time, object_id, kill) VALUES (?, ?, ?, ?)', (m, i, 100 + i, k)).lastrowid
            db.execute('INSERT INTO bag_items(bag, slot, item_type) VALUES (?, 0, 5)', (b,))
            db.execute('INSERT INTO bag_stats(bag, stat_type) VALUES (?, 1)', (b,))
        db.execute('INSERT INTO bags(map, time, object_id) VALUES (?, 99, 999)', (m,))   # a bag with no kill
    db.commit()
    db.close()


def self_test():
    with tempfile.TemporaryDirectory() as folder:
        target, source = os.path.join(folder, 't.db'), os.path.join(folder, 's.db')
        # a: in both, same; b: only in target; c: in both, source longer; d: only in source.
        make(target, {'a': (10, 2), 'b': (10, 1), 'c': (5, 1)})
        make(source, {'c': (9, 3), 'a': (10, 2), 'd': (10, 4)})
        assert merge(target, source) == (1, 1)
        db = sqlite3.connect(target)
        per = dict(db.execute('''SELECT s.file, count(k.id) FROM sessions s JOIN maps m ON m.session = s.id
                                 LEFT JOIN kills k ON k.map = m.id GROUP BY s.file'''))
        assert per == {'a': 2, 'b': 1, 'c': 3, 'd': 4}, per
        assert dict(db.execute('SELECT file, imported_bytes FROM sessions'))['c'] == 9
        c = counts(db)
        assert (c['sessions'], c['kills'], c['bags'], c['bag_items'], c['bag_stats']) == (4, 10, 14, 10, 10), c
        assert (c['maps'], c['map_info'], c['player_stats'], c['capture_gaps']) == (4, 4, 4, 4), c
        # Every linked bag points at a kill of its own game, at its own position, and nothing dangles.
        assert db.execute('''SELECT count(*) FROM bags b JOIN kills k ON k.id = b.kill
                             WHERE k.map = b.map AND b.object_id = 100 + k.object_id''').fetchone()[0] == 10
        for sql in ('SELECT count(*) FROM bag_items WHERE bag NOT IN (SELECT id FROM bags)',
                    'SELECT count(*) FROM bag_stats WHERE bag NOT IN (SELECT id FROM bags)',
                    'SELECT count(*) FROM kills WHERE map NOT IN (SELECT id FROM maps)',
                    'SELECT count(*) FROM maps WHERE session NOT IN (SELECT id FROM sessions)',
                    'SELECT count(*) FROM capture_gaps WHERE session NOT IN (SELECT id FROM sessions)'):
            assert db.execute(sql).fetchone()[0] == 0, sql
        db.close()
        assert merge(target, source) == (0, 0)   # a second run changes nothing
        assert counts(sqlite3.connect(target))['kills'] == 10
    print('drop_merge self-test passed')


def main():
    if sys.argv[1:] == ['--self-test']:
        return self_test()
    if len(sys.argv) != 3 or os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]):
        sys.exit(__doc__)
    target, source = sys.argv[1:]
    for path in (target, source):
        if not os.path.isfile(path): sys.exit(f'not found: {path}')
    before = counts(sqlite3.connect(target))
    copied, replaced = merge(target, source)
    after = counts(sqlite3.connect(target))
    print(f'{copied} games copied, {replaced} replaced by a longer copy')
    for table in after:
        print(f'  {table}: {before[table]} -> {after[table]}')


if __name__ == '__main__':
    main()
