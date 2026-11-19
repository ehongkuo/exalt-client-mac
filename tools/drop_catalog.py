#!/usr/bin/env python3
"""Builds the dungeon, mob and drop catalog from RealmEye and the game data (issue #51).

    tools/drop_catalog.py build [--offline] [--refresh] [--db PATH]...
    tools/drop_catalog.py fetch PATH...     fetch single RealmEye pages into the cache, e.g. /wiki/dungeons
    tools/drop_catalog.py check             check data/drop_catalog.json against the game data (./build.sh runs it)
    tools/drop_catalog.py --self-test

build reads RealmEye's dungeon list, each dungeon's page and each of its mobs' pages, matches every
name to the game's type ids in RealmHound's XML (read-only), and writes data/drop_catalog.json. It
prints what changed since the last file, and what drop_rates_v2.db has seen in play that the catalog
still lacks. Mobs and items with no sprite in the game data (no texture, or the 'invisible' sheet) get RealmEye's, in
data/sprites/.

Run it yourself, not from an AI agent: RealmEye's robots.txt blocks AI agents by name. Every request
is checked against robots.txt for this tool's User-Agent, spaced at least 2 s apart (RealmEye asks for
1 s), and saved under ~/Library/Caches/Exalt Client Mac/realmeye/, so a page is fetched once until you
pass --refresh. --offline uses only the cache. Data from RealmEye (https://www.realmeye.com), credited
in the catalog it builds.
"""
import argparse
import collections
import datetime
import glob
import html as htmllib
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser

SITE = 'https://www.realmeye.com'
AGENT = 'exalt-client-mac-drop-catalog/1.0 (personal tool, one page every 2 s, cached)'
CACHE = os.path.expanduser('~/Library/Caches/Exalt Client Mac/realmeye')
XML = os.path.expanduser('~/Library/Application Support/RealmHound/assets/xml')
# The installed and staging apps share one database in the installed app's folder (#49); #58 started a new file.
DBS = [os.path.expanduser('~/Library/Application Support/Exalt Client Mac/drop_rates_v2.db')]
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, 'data', 'drop_catalog.json')
SPRITES = os.path.join(REPO, 'data', 'sprites')
DELAY = 2.0
REALM = 'Realm of the Mad God'   # the map name kills in the Realm are stored under
FAMILIES = {'weapons': 'weapon', 'ability-items': 'ability', 'armor': 'armor', 'rings': 'ring'}


def cache_path(path, cache=CACHE):
    """The cache file of a site path: /wiki/abyss-of-demons → <cache>/wiki/abyss-of-demons.html."""
    clean = path.split('#')[0].split('?')[0].strip('/')
    if not clean or '..' in clean.split('/'):
        raise ValueError(f'not a page path: {path!r}')
    return os.path.join(cache, clean if os.path.splitext(clean)[1] else clean + '.html')


class Fetcher:
    def __init__(self, cache=CACHE, refresh=False, offline=False, opener=urllib.request.urlopen, sleep=time.sleep,
                 clock=time.monotonic):
        self.cache, self.refresh, self.offline = cache, refresh, offline
        self.opener, self.sleep, self.clock = opener, sleep, clock
        self.last, self.robots, self.delay = None, None, DELAY
        self.missing, self.fresh = [], set()   # fresh: fetched this run, so --refresh fetches each once

    def wait(self):
        if self.last is not None:
            left = self.delay - (self.clock() - self.last)
            if left > 0: self.sleep(left)
        self.last = self.clock()

    def get(self, url):
        self.wait()
        url = urllib.parse.quote(url, safe=':/?#=&%')   # RealmEye has image paths with spaces (Enemies/Lord Ruthven.png)
        with self.opener(urllib.request.Request(url, headers={'User-Agent': AGENT}), timeout=30) as r:
            return r.read()

    def allowed(self, path):
        if self.robots is None:
            self.robots = urllib.robotparser.RobotFileParser()
            self.robots.parse(self.get(SITE + '/robots.txt').decode('utf-8', 'replace').splitlines())
            self.delay = max(DELAY, float(self.robots.crawl_delay(AGENT) or 0))
        return self.robots.can_fetch(AGENT, SITE + path)

    def raw(self, path):
        """The file's bytes, from the cache when it's there. None when robots.txt disallows it, it's missing
        on the site, or --offline and it isn't cached."""
        file = cache_path(path, self.cache)
        if os.path.exists(file) and not (self.refresh and file not in self.fresh):
            with open(file, 'rb') as f: return f.read()
        why = 'offline, not cached' if self.offline else None
        if not why and not self.allowed(path): why = 'robots.txt'
        if not why:
            try:
                data = self.get(SITE + path)
            except urllib.error.HTTPError as e:
                why = f'HTTP {e.code}'
        if why:
            self.missing.append((path, why))
            return None
        os.makedirs(os.path.dirname(file), exist_ok=True)
        with open(file + '.part', 'wb') as f: f.write(data)
        os.replace(file + '.part', file)   # a cut-off run never leaves half a page in the cache
        self.fresh.add(file)
        print(f'fetched {path}', file=sys.stderr)
        return data

    def page(self, path):
        data = self.raw(path)
        return None if data is None else data.decode('utf-8', 'replace')


# RealmEye pages. Layouts as of Nov 2026: the dungeon list's table rows open with a text link and an
# anchor; a dungeon page lists its mobs as image links between Layout and Drops of Interest (h2–h4);
# a mob page has "Base HP" and a <h3 id="drops"> section of text links, tiers as /wiki/weapons#tier-7.

def key(name):
    """A name for matching: entities decoded, curly quotes straightened, case folded."""
    return re.sub(r'\s+', ' ', htmllib.unescape(name).replace('’', "'").replace('‘', "'")).strip().casefold()


def wiki(html):
    """The page's own content: from the wiki-page div up to the sidebar (whose links lead everywhere)."""
    i = html.find('<div class="wiki-page"')
    j = html.find('wiki-sidebar', max(i, 0))
    return html[max(i, 0):j if j >= 0 else len(html)]


def biome_pages(html):
    """The Realm's enemy list is one page per biome: their slugs (beach-enemies, …)."""
    return list(dict.fromkeys(re.findall(r'<a href="/wiki/([^"#]+-enemies)">', wiki(html))))


def dungeon_list(html):
    """(slug, name) of each dungeon in the list."""
    found = re.findall(r'<td[^>]*><a href="/wiki/([^"#]+)">([^<]+)</a><a id=', wiki(html))
    return list(dict.fromkeys((slug, htmllib.unescape(name).strip()) for slug, name in found))


def image_links(html):
    """(slug, name) of each image link, the way mobs are shown: the name is the image's alt text, else the
    caption after it (a boss's image may have no alt)."""
    found = re.findall(r'<a href="/wiki/([^"#]+)"><img ([^>]*)>(?:\s*(?:<br>)?\s*(?:<b>)?([^<]+))?', html)
    out = []
    for slug, attrs, caption in found:
        alt = re.search(r'\balt="([^"]*)"', attrs)
        name = htmllib.unescape(alt[1] if alt and alt[1] else caption).strip()
        if name: out.append((slug, name))
    return list(dict.fromkeys(out))


def dungeon_mobs(html):
    """(slug, name) of the image links in a dungeon page's mob part: from Layout (some pages list mobs there)
    to the first section after the mobs, skipping environmental hazards. Heading levels vary by page, and
    links that aren't mobs (maps, chests, portals) are dropped later by their pages' lack of stats."""
    parts = re.split(r'<h[234]([^>]*)>(.*?)</h[234]>', wiki(html))
    mobs, inside = [], False
    for attrs, heading, body in zip(parts[1::3], parts[2::3], parts[3::3]):
        hid = (re.search(r'id="#?([^"]*)"', attrs) or [None, ''])[1]
        text = re.sub('<[^>]+>', '', heading).strip().casefold()
        if hid in ('layout', 'enemies', 'boss', 'bosses', 'inhabitants') or text.startswith(('boss', 'enem')): inside = True
        if hid in ('drops', 'interest', 'quests', 'tips', 'history', 'trivia', 'notes', 'mini-dungeons') or text.startswith('drops of'):
            break
        if inside and not text.startswith('environmental'): mobs += image_links(body)
    return list(dict.fromkeys(mobs))


def is_mob(html):
    return 'id="stats"' in html   # a mob's page opens with its stats (HP, DEF, EXP)


def mob_drops(html):
    """A mob page's named drops (names) and tiers ({family: [tier]})."""
    html = wiki(html)
    start = html.find('id="drops"')
    if start < 0: return [], {}
    end = re.compile(r'<h[23] id=').search(html, start + 10)
    drops, tiers = [], {}
    for href, text in re.findall(r'<a href="/wiki/([^"]+)">([^<]+)</a>', html[start:end.start() if end else len(html)]):
        tier = re.fullmatch(r'([a-z-]+)#tier-(\d+)', href)
        if tier and tier[1] in FAMILIES:
            tiers.setdefault(FAMILIES[tier[1]], set()).add(int(tier[2]))
        else:
            drops.append(htmllib.unescape(text).strip())
    return list(dict.fromkeys(drops)), {f: sorted(t) for f, t in sorted(tiers.items())}


def sprite_src(html, name):
    """The site path of the image RealmEye shows for a name, or None."""
    for alt in (htmllib.escape(name), name):
        if m := re.search(r'<img [^>]*?alt="' + re.escape(alt) + r'"[^>]*?src="(/s/[^"]+)"', html): return m[1]
    for alt in (htmllib.escape(name), name):   # a form of it: "Archbishop Leucoryx (light form)"
        if m := re.search(r'<img [^>]*?alt="' + re.escape(alt) + r' \([^"]*\)"[^>]*?src="(/s/[^"]+)"', html): return m[1]
    return None


# The game data (RealmHound's XML), read-only.

class Game:
    def __init__(self, folder=XML):
        self.objects = {}   # type → {id, name, cls, file, texture, loot, dungeon}; a later file wins
        for path in sorted(glob.glob(os.path.join(folder, '*.xml'))):
            with open(path, encoding='utf-8', errors='replace') as f: self.read(f.read(), os.path.basename(path))
        self.by_name = {}
        self.by_id = {}   # RealmEye sometimes uses the XML id (Oryx the Mad God 2): tried when no display name matches
        for t, o in self.objects.items():
            self.by_name.setdefault(key(o['name']), []).append(t)
            self.by_id.setdefault(key(o['id']), []).append(t)

    def read(self, text, file):
        for attrs, body in re.findall(r'<Object\s([^>]*?[^/])>(.*?)</Object>', text, re.S):
            t = re.search(r'\btype="0x([0-9a-fA-F]+)"', attrs)
            i = re.search(r'\bid="([^"]*)"', attrs)
            icon = re.search(r'\bcollectionIcon="(\d+)"', attrs)
            if not t or not i: continue
            el = lambda tag: (m := re.search(f'<{tag}>([^<]*)</{tag}>', body)) and htmllib.unescape(m[1]).strip()
            oid, display = htmllib.unescape(i[1]), el('DisplayId')
            self.objects[int(t[1], 16)] = dict(
                id=oid, name=display if display and not display.startswith('{') else oid, cls=el('Class'), file=file,
                item='<Item/>' in body or '<Item />' in body, loot=el('BagType') is not None,
                # A texture on the 'invisible' sheet draws nothing (Hermit God, Oryx: other objects draw them), so it counts as none.
                texture=bool(re.search(r'<(Animated)?Texture[ >]', body)) and not re.search(r'<File>\s*invisible\s*</File>', body),
                dungeon=el('DungeonName'),
                icon=icon and int(icon[1]))

    def match(self, name, want, hint='', every=False):
        """Type ids for a RealmEye name: Character objects for want='mob', loot items for 'item'. When several
        share the name: the ones whose XML id is the name, then the ones in a file named like the dungeon (hint).
        every=True keeps them all: the Realm has a copy per biome (Djinn, City Djinn). A name nothing has is tried
        again without RealmEye's trailing qualifier: Primal Snake (Boss), The Puppet Master (Encore, Thorned Ravager<."""
        bare = re.sub(r'\s*\([^)]*\)?$|<$', '', name)
        if bare != name and not self.by_name.get(key(name)) and not self.by_id.get(key(name)): return self.match(bare, want, hint, every)
        found = [t for t in self.by_name.get(key(name)) or self.by_id.get(key(name), []) if
                 (self.objects[t]['cls'] == 'Character' if want == 'mob' else self.objects[t]['item'] and self.objects[t]['loot'])]
        for narrow in () if every else (lambda t: key(self.objects[t]['id']) == key(name),
                       lambda t: hint and re.sub(r'[^a-z]', '', hint.casefold()) in self.objects[t]['file'].casefold()):
            if len(found) > 1 and any(map(narrow, found)): found = [t for t in found if narrow(t)]
        return sorted(found)

    def dungeons(self):
        return {key(o['dungeon']): o['dungeon'] for o in self.objects.values() if o['dungeon']}

    def portal(self, dungeon):
        return min((t for t, o in self.objects.items() if o['dungeon'] == dungeon and o['cls'] == 'Portal'), default=None)


def hexid(t): return f'0x{t:04x}'


# Events that drop another dungeon's loot, so its icon would be wrong (checked by eye against the sheet).
BORROWED_LOOT = {'White Snake Invasion I', 'White Snake Invasion II'}


def dungeon_icons(out, game):
    """Each dungeon's cell in CollectionIcon.png (16 px cells, 20 a row): the game gives items a collectionIcon, not
    portals, so a dungeon takes the cell most of its mobs' drops name. Cells 0-9 are badges and 100 is the Realm's;
    a tie or a borrowed-loot event gets no icon, since a wrong icon is worse than none."""
    drops = {t: m['drops'] for m in out['mobs'] for t in m['types']}
    for d in out['dungeons']:
        if d['name'] in BORROWED_LOOT: continue
        count = collections.Counter(i for mob in d['mobs'] for item in set(drops.get(mob, []))
                                    if (i := game.objects[int(item, 16)]['icon']) is not None and i >= 10
                                    and (i != 100 or d['name'] == REALM))
        top = count.most_common(2)
        if top and (len(top) == 1 or top[0][1] > top[1][1]): d['icon'] = top[0][0]


# Catalog entries the game data draws nothing for and RealmEye has no image of, with why. Empty so far.
NO_SPRITE = {}


def check(catalog, game, sprites=SPRITES):
    """Problems with a catalog: an id the game data lacks or gives the wrong kind, or an entry with no sprite (no
    texture in the game data, no RealmEye image in data/sprites, no reason in NO_SPRITE)."""
    problems = []
    def look(hexes, want, what):
        for h in hexes:
            o = game.objects.get(int(h, 16))
            if o is None: problems.append(f'{what}: {h} is not in the game data'); continue
            if want == 'mob' and o['cls'] != 'Character' or want == 'item' and not o['item'] or want == 'portal' and o['cls'] != 'Portal':
                problems.append(f'{what}: {h} ({o["name"]}) is not a {want}')
            elif not o['texture'] and h not in catalog.get('sprites', {}) and h not in NO_SPRITE:
                problems.append(f'{what}: {h} ({o["name"]}) has no sprite')
    for d in catalog['dungeons']:
        look([d['portal']] if d.get('portal') else [], 'portal', d['name'])
        look(d['mobs'], 'mob', d['name'])
    for m in catalog['mobs']:
        look(m['types'], 'mob', m['name'])
        look(m['drops'], 'item', m['name'])
    problems += [f'sprite {h}: {f} is missing' for h, f in catalog.get('sprites', {}).items() if not os.path.exists(os.path.join(sprites, f))]
    return problems


def build(fetch, game, sprites=SPRITES):
    """The catalog, from RealmEye pages and the game data."""
    out = dict(source=dict(site='RealmEye', url=SITE, note='Dungeons, mobs and drops from RealmEye; ids and sprites from the game data.',
                           built=datetime.date.today().isoformat()),
               dungeons=[], mobs=[], unmatched=[], ambiguous=[])
    listing = fetch.page('/wiki/dungeons')
    if listing is None: raise SystemExit('no dungeon list: run without --offline, or fetch /wiki/dungeons')
    names = game.dungeons()
    pages = [(slug, name) for slug, name in dungeon_list(listing)] + [('the-realm-enemies', REALM)]
    mobs = {}   # slug → entry
    portal_sprites = []   # (portal type, dungeon name, its page) for portals the game draws nothing for
    for slug, name in pages:
        game_name = REALM if name == REALM else names.get(key(name))
        if game_name is None:
            out['unmatched'].append(dict(kind='dungeon', realmeye=name, why='no portal with this <DungeonName>'))
            continue
        html = fetch.page(f'/wiki/{slug}')
        if html is None: continue
        if name == REALM:
            listed = [m for biome in biome_pages(html) if (page := fetch.page(f'/wiki/{biome}')) for m in image_links(wiki(page))]
        else:
            listed = dungeon_mobs(html)
        types = set()
        for mob_slug, mob_name in listed:
            if mob_slug not in mobs:
                page = fetch.page(f'/wiki/{mob_slug}')
                if page is None or not is_mob(page): continue   # an item or a place, not a mob
                drops, tiers = mob_drops(page)
                mobs[mob_slug] = dict(name=mob_name, realmeye=mob_slug, page=page, drops=drops, tiers=tiers, types=None)
            entry = mobs[mob_slug]
            if entry['types'] is None:
                entry['types'] = game.match(entry['name'], 'mob', name, every=name == REALM)
                if not entry['types']:
                    out['unmatched'].append(dict(kind='mob', realmeye=entry['name'], why='no Character object with this name'))
                elif len(entry['types']) > 1 and name != REALM:
                    out['ambiguous'].append(dict(kind='mob', realmeye=entry['name'], types=list(map(hexid, entry['types']))))
            types.update(entry['types'])
        out['dungeons'].append(dict(name=game_name, portal=(p := game.portal(game_name)) and hexid(p), realmeye=slug,
                                    mobs=list(map(hexid, sorted(types)))))
        if p and not game.objects[p]['texture']: portal_sprites.append((p, name, html))
    need_sprite, no_item = list(portal_sprites), {}
    places = set(names) | {key(n) for _, n in pages}   # a mob dropping a portal: a place, not loot
    for entry in sorted(mobs.values(), key=lambda e: key(e['name'])):
        if not entry['types']: continue
        drops = []
        for item in entry['drops']:
            found = game.match(item, 'item')
            if not found:
                if key(item) not in places: no_item.setdefault(item, []).append(entry['name'])
            elif len(found) > 1:
                out['ambiguous'].append(dict(kind='drop', realmeye=item, types=list(map(hexid, found))))
            drops += found
            need_sprite += [(t, item, entry['page']) for t in found if not game.objects[t]['texture']]
        need_sprite += [(t, entry['name'], entry['page']) for t in entry['types'] if not game.objects[t]['texture']]
        out['mobs'].append(dict(name=entry['name'], types=list(map(hexid, entry['types'])), realmeye=entry['realmeye'],
                                tiers=entry['tiers'], drops=list(map(hexid, sorted(set(drops))))))
    out['unmatched'] += [dict(kind='drop', realmeye=item, mobs=m, why='no loot item with this name') for item, m in no_item.items()]
    out['dungeons'].sort(key=lambda d: d['name'])
    dungeon_icons(out, game)
    for k in ('unmatched', 'ambiguous'):
        out[k] = sorted({json.dumps(e, sort_keys=True): e for e in out[k]}.values(), key=lambda e: (e['kind'], key(e['realmeye'])))
    # RealmEye's sprite for anything the game data draws nothing for.
    out['sprites'] = {}
    # Several RealmEye pages can name one game id (Rogue Puppet under each class's puppet page): use the first that
    # shows a picture under that name.
    candidates = {}
    for t, n, p in need_sprite: candidates.setdefault(t, []).append((n, p))
    for t, tries in sorted(candidates.items()):
        src = data = None
        for n, p in tries:   # the first page with a picture we can get (cached, when offline)
            if (src := sprite_src(p, n)) and (data := fetch.raw(src)): break
        if data:
            os.makedirs(sprites, exist_ok=True)
            file = f'{hexid(t)}{os.path.splitext(src)[1]}'
            with open(os.path.join(sprites, file), 'wb') as f: f.write(data)
            out['sprites'][hexid(t)] = file
    return out


def diff(old, new):
    """Lines saying what changed between two catalogs."""
    def sets(c):
        return ({d['name'] for d in c.get('dungeons', [])}, {m['name'] for m in c.get('mobs', [])},
                {(m['name'], d) for m in c.get('mobs', []) for d in m['drops']},
                {(m['name'], f, t) for m in c.get('mobs', []) for f, ts in m['tiers'].items() for t in ts},
                {e['realmeye'] for e in c.get('unmatched', [])})
    lines = []
    for label, a, b in zip(('dungeon', 'mob', 'drop', 'tier', 'unmatched'), sets(old), sets(new)):
        for x in sorted(b - a, key=str): lines.append(f'+ {label} {x}')
        for x in sorted(a - b, key=str): lines.append(f'- {label} {x}')
    return lines


def missing_in_play(catalog, dbs):
    """Lines naming maps, mobs and dropped items seen in the drop database that the catalog lacks."""
    dungeons = {d['name'] for d in catalog['dungeons']}
    mobs = {int(t, 16) for m in catalog['mobs'] for t in m['types']}
    drops = {int(t, 16) for m in catalog['mobs'] for t in m['drops']}
    seen = {'map': set(), 'mob': set(), 'item': set()}
    for path in dbs:
        if not os.path.exists(path): continue
        db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
        try:
            seen['map'] |= {r[0] for r in db.execute(
                "SELECT DISTINCT m.name FROM kills k JOIN maps m ON m.id = k.map WHERE m.name IS NOT NULL")}
            seen['mob'] |= {r for r in db.execute(
                "SELECT DISTINCT k.mob_type, coalesce(o.display_name, o.name, '') FROM kills k LEFT JOIN objects o ON o.type = k.mob_type "
                "WHERE coalesce(o.drop_source, 1) AND k.mob_type IS NOT NULL")}
            seen['item'] |= {r for r in db.execute(
                "SELECT DISTINCT i.item_type, coalesce(t.display_name, t.name, '') FROM bag_items i LEFT JOIN items t ON t.type = i.item_type "
                "WHERE t.tier IS NULL")}   # tiered items are covered by tiers
        except sqlite3.Error as e:
            print(f'{path}: {e}', file=sys.stderr)
        finally:
            db.close()
    lines = [f'map {m}' for m in sorted(seen['map'] - dungeons)]
    lines += [f'mob {hexid(t)} {n}' for t, n in sorted(seen['mob']) if t not in mobs]
    lines += [f'item {hexid(t)} {n}' for t, n in sorted(seen['item']) if t not in drops]
    return lines


def self_test():
    import tempfile
    assert cache_path('/wiki/abyss-of-demons', '/c') == '/c/wiki/abyss-of-demons.html'
    assert cache_path('wiki/x#loot', '/c') == '/c/wiki/x.html'
    assert cache_path('/s/a/img/wiki/i/abc.png', '/c') == '/c/s/a/img/wiki/i/abc.png'
    for bad in ('/', '/wiki/../../etc'):
        try: cache_path(bad, '/c'); raise AssertionError(bad)
        except ValueError: pass

    class Reply:
        def __init__(self, body): self.body = body
        def __enter__(self): return self
        def __exit__(self, *a): pass
        def read(self): return self.body
    asked, slept, now = [], [], [0.0]
    robots = b'User-agent: Claude-Code\nDisallow: /\n\nUser-agent: *\nDisallow: /forum/users/\nCrawl-delay: 1\n'
    def opener(req, timeout):
        asked.append((req.full_url, req.get_header('User-agent')))
        return Reply(robots if req.full_url.endswith('/robots.txt') else b'<html>page</html>')
    with tempfile.TemporaryDirectory() as cache:
        f = Fetcher(cache, opener=opener, sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)), clock=lambda: now[0])
        assert f.page('/wiki/dungeons') == '<html>page</html>'
        assert f.page('/forum/users/someone') is None
        assert f.page('/wiki/dungeons') == '<html>page</html>'   # cached: no request
        assert [u for u, _ in asked] == [SITE + '/robots.txt', SITE + '/wiki/dungeons'], asked
        assert all(a == AGENT for _, a in asked)
        assert slept == [2.0], slept   # 2 s between requests even though robots.txt asks for 1
        assert Fetcher(cache, offline=True).page('/wiki/elsewhere') is None
        assert f.raw('/s/a/img/wiki/d/Enemies/Lord Ruthven.png') == b'<html>page</html>' and asked[-1][0].endswith('/Enemies/Lord%20Ruthven.png'), asked[-1]

    # Made-up pages in RealmEye's layout.
    listing = ('<div class="wiki-page"><table><tr><td rowspan="3"><a href="/wiki/test-den">Test Den</a><a id="test-den"></a></td>'
               '<td><a href="/wiki/test-den"><img alt="Test Den" src="/s/x.png"></a></td></tr>'
               '<tr><td><a href="/wiki/oryx-s-nook">Oryx’s Nook</a><a id="nook"></a></td></tr></table></div>')
    assert dungeon_list(listing) == [('test-den', 'Test Den'), ('oryx-s-nook', 'Oryx’s Nook')]
    den = ('<div class="wiki-page"><h4>Key</h4><a href="/wiki/den-key"><img alt="Den Key" src="/s/y.png"></a>'
           '<h2 id="layout">Layout</h2><h4>Village</h4><a href="/wiki/den-guard"><img alt="Den Guard" src="/s/g.png"></a>'
           '<h2 id="enemies">Enemies and Environmental Hazards</h2><h3>Enemies</h3>'
           '<a href="/wiki/den-rat"><img alt="Den Rat" src="/s/r.png"><br>Den Rat</a>'
           '<h3>Environmental Hazards</h3><a href="/wiki/den-lava"><img alt="Den Lava" src="/s/v.png"></a>'
           '<h2 id="boss">Boss</h2><a href="/wiki/den-king"><img src="/s/k.png"><br>Den King</a>'
           '<h2>Treasure Room Boss</h2><a href="/wiki/den-idol"><img alt="Den Idol" src="/s/i.png"></a>'
           '<h2 id="interest">Drops of Interest</h2><a href="/wiki/den-sword"><img alt="Den Sword" src="/s/s.png"></a></div>')
    assert dungeon_mobs(den) == [('den-guard', 'Den Guard'), ('den-rat', 'Den Rat'), ('den-king', 'Den King'), ('den-idol', 'Den Idol')], dungeon_mobs(den)
    hive = ('<div class="wiki-page"><h3>Bosses</h3><a href="/wiki/q"><img src="/s/q.png"><br><b>Q</b></a>'
            '<h3 id="drops">Drops of Interest</h3><a href="/wiki/z"><img alt="Z" src="/s/z.png"></a></div>')
    assert dungeon_mobs(hive) == [('q', 'Q')], dungeon_mobs(hive)
    king = ('<div class="wiki-page"><img alt="Den King" title="Den King" src="/s/k.png"><h3 id="stats">Stats</h3><p>HP: 100</p>'
            '<h3 id="drops">Drops</h3><table><tr><td><img alt="Purple Bag" src="/s/b.png"></td>'
            '<td><a href="/wiki/den-sword"><img alt="Den Sword" src="/s/s.png"></a></td><td><a href="/wiki/den-sword">Den Sword</a>'
            '<sup><abbr title="Guaranteed">G</abbr></sup></td><td><a href="/wiki/weapons#tier-7">Tier 7 Weapons</a></td>'
            '<td><a href="/wiki/rings#tier-3">Tier 3 Rings</a></td><td><a href="/wiki/weapons#tier-8">Tier 8 Weapons</a></td>'
            '<td><a href="/wiki/pet-eggs">Pet Eggs</a></td><td><a href="/wiki/test-den">Test Den</a></td></tr></table><h3 id="tips">Tips</h3><a href="/wiki/z">Not a drop</a></div>')
    assert is_mob(king) and not is_mob(den)
    assert mob_drops(king) == (['Den Sword', 'Pet Eggs', 'Test Den'], {'ring': [3], 'weapon': [7, 8]}), mob_drops(king)
    assert sprite_src(king, 'Den King') == '/s/k.png'
    assert sprite_src('<img alt="Den King (light form)" src="/s/l.png"><img alt="Den King (chaos form)" src="/s/c.png">', 'Den King') == '/s/l.png'

    xml = ('<Objects><Object type="0x0010" id="Test Den Portal"><Class>Portal</Class><DungeonName>Test Den</DungeonName>'
           '<Texture><File>a</File><Index>1</Index></Texture></Object>'
           '<Object type="0x0011" id="Den King"><Class>Character</Class><Texture><File>a</File><Index>2</Index></Texture></Object>'
           '<Object type="0x0012" id="Heroic Den King"><Class>Character</Class><DisplayId>Den King</DisplayId></Object>'
           '<Object type="0x0013" id="Den Rat"><Class>Character</Class><Texture><File>invisible</File><Index>0</Index></Texture></Object>'
           '<Object id="Den Sword" type="0x0020" collectionIcon="42"><Class>Equipment</Class><Item/><BagType>2</BagType>'
           '<Texture><File>a</File><Index>3</Index></Texture></Object>'
           '<Object type="0x0021" id="Den Sword Skin"><DisplayId>Den Sword</DisplayId><Item/></Object></Objects>')
    with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as art:
        with open(os.path.join(folder, 'testDenObjects.xml'), 'w') as f: f.write(xml)
        game = Game(folder)
        assert game.match('Heroic Den King', 'mob') == [0x12] and game.match('Den King (Boss)', 'mob') == [0x11] \
            and game.match('Den Rat<', 'mob') == [0x13] and game.match('Den King', 'mob', every=True) == [0x11, 0x12]
        assert game.match('Den King', 'mob') == [0x11]       # the XML id wins over a display name
        assert game.match('Den Sword', 'item') == [0x20]     # a skin (no <BagType>) isn't loot
        assert game.match('den rat', 'mob') == [0x13] and game.match('Den Lava', 'mob') == []
        rat = '<div class="wiki-page"><img alt="Den Rat" src="/s/r.png"><h3 id="stats">Stats</h3></div>'
        pages = {'wiki/dungeons': listing, 'wiki/test-den': den, 'wiki/den-king': king, 'wiki/den-rat': rat,
                 'wiki/the-realm-enemies': '<div class="wiki-page"><a href="/wiki/beach-enemies">Beach Enemies</a></div>'
                                           '<div class="col-md-3 wiki-sidebar"><a href="/wiki/test-den-enemies">Not the Realm</a></div>',
                 'wiki/beach-enemies': '<div class="wiki-page"><a href="/wiki/den-rat"><img alt="Den Rat" src="/s/r.png"></a></div>',
                 's/r.png': 'PNG'}
        for path, body in pages.items():
            os.makedirs(os.path.dirname(cache_path(path, cache)), exist_ok=True)
            with open(cache_path(path, cache), 'w') as f: f.write(body)
        fetch = Fetcher(cache, offline=True)
        c = build(fetch, game, art)
        assert [d['name'] for d in c['dungeons']] == [REALM, 'Test Den'], c['dungeons']
        den_entry = c['dungeons'][1]
        assert den_entry['portal'] == '0x0010' and den_entry['mobs'] == ['0x0011', '0x0013'], den_entry
        assert c['dungeons'][0]['mobs'] == ['0x0013'] and 'icon' not in c['dungeons'][0]
        assert den_entry['icon'] == 42, den_entry
        assert c['mobs'][0] == dict(name='Den King', types=['0x0011'], realmeye='den-king', tiers={'ring': [3], 'weapon': [7, 8]},
                                    drops=['0x0020']), c['mobs'][0]
        assert {(e['kind'], e['realmeye']) for e in c['unmatched']} == {('dungeon', 'Oryx’s Nook'), ('drop', 'Pet Eggs')}, c['unmatched']
        assert c['sprites'] == {'0x0013': '0x0013.png'} and open(os.path.join(art, '0x0013.png')).read() == 'PNG'
        assert [p for p, _ in fetch.missing] == ['/wiki/den-guard', '/wiki/den-idol']   # a dungeon the game lacks isn't fetched
        assert diff({}, c)[:2] == [f'+ dungeon {REALM}', '+ dungeon Test Den'] and diff(c, c) == []
        assert check(c, game, art) == [], check(c, game, art)
        bad = json.loads(json.dumps(c)); bad['mobs'][0]['drops'] += ['0x0013', '0x0999']; bad['sprites'] = {}
        assert sorted(check(bad, game, art)) == sorted(['Den King: 0x0013 (Den Rat) is not a item', 'Den King: 0x0999 is not in the game data',
                                                        f'{REALM}: 0x0013 (Den Rat) has no sprite', 'Test Den: 0x0013 (Den Rat) has no sprite',
                                                        'Den Rat: 0x0013 (Den Rat) has no sprite']), check(bad, game, art)

        db = os.path.join(folder, 'drop_rates.db')
        con = sqlite3.connect(db)
        con.executescript("""
            CREATE TABLE maps(id INTEGER PRIMARY KEY, name TEXT); CREATE TABLE kills(map INTEGER, mob_type INTEGER);
            CREATE TABLE objects(type INTEGER, name TEXT, display_name TEXT, drop_source INTEGER);
            CREATE TABLE bag_items(item_type INTEGER); CREATE TABLE items(type INTEGER, name TEXT, display_name TEXT, tier INTEGER);
            INSERT INTO maps VALUES (1, 'Test Den'), (2, 'New Place'); INSERT INTO kills VALUES (1, 17), (2, 99);
            INSERT INTO objects VALUES (99, 'New Mob', NULL, 1); INSERT INTO bag_items VALUES (32), (77), (78);
            INSERT INTO items VALUES (77, 'New Ring', NULL, NULL), (78, 'T9 Sword', NULL, 9);""")
        con.commit(); con.close()
        assert missing_in_play(c, [db]) == ['map New Place', 'mob 0x0063 New Mob', 'item 0x004d New Ring'], missing_in_play(c, [db])
    print('drop_catalog self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--refresh', action='store_true', help='fetch again even when cached')
    parser.add_argument('--offline', action='store_true', help='use only cached pages')
    sub = parser.add_subparsers(dest='command')
    fetch = sub.add_parser('fetch', help='fetch pages into the cache')
    fetch.add_argument('paths', nargs='+')
    b = sub.add_parser('build', help='build data/drop_catalog.json')
    b.add_argument('--db', action='append', help=f'drop database to check for gaps (default: {", ".join(DBS)})')
    b.add_argument('--out', default=OUT)
    sub.add_parser('check', help='check data/drop_catalog.json against the game data')
    args = parser.parse_args()
    if args.self_test: return self_test()
    if args.command == 'check':
        if not glob.glob(os.path.join(XML, '*.xml')):
            print('drop_catalog check skipped: no RealmHound XML'); return 0
        with open(OUT, encoding='utf-8') as fh: catalog = json.load(fh)
        problems = check(catalog, Game())
        print('\n'.join(problems) if problems else f'drop_catalog check passed: {len(catalog["dungeons"])} dungeons, {len(catalog["mobs"])} mobs')
        return 1 if problems else 0
    f = Fetcher(refresh=args.refresh, offline=args.offline)
    if args.command == 'fetch':
        for p in args.paths:
            if f.page(p) is not None: print(f'cached {p}')
    elif args.command == 'build':
        catalog = build(f, Game())
        old = {}
        if os.path.exists(args.out):
            with open(args.out, encoding='utf-8') as fh: old = json.load(fh)
        if old.get('source', {}).get('built') and not diff(old, catalog):
            catalog['source']['built'] = old['source']['built']   # unchanged data keeps its date
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out + '.part', 'w', encoding='utf-8') as fh:
            json.dump(catalog, fh, indent=1, ensure_ascii=False, sort_keys=False); fh.write('\n')
        os.replace(args.out + '.part', args.out)
        changes = diff(old, catalog)
        print(f'{len(catalog["dungeons"])} dungeons, {len(catalog["mobs"])} mobs, {len(catalog["unmatched"])} unmatched, '
              f'{len(catalog["ambiguous"])} ambiguous → {args.out}')
        print('\n'.join(['Changes:'] + changes) if changes else 'No changes.')
        gaps = missing_in_play(catalog, args.db or DBS)
        if gaps: print('\n'.join(['Seen in play, not in the catalog:'] + gaps))
    else:
        parser.error('nothing to do: try build')
    for path, why in f.missing: print(f'skipped ({why}): {path}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
