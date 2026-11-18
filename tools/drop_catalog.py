#!/usr/bin/env python3
"""Builds the dungeon, mob and drop catalog from RealmEye and the game data (issue #51).

    tools/drop_catalog.py fetch PATH...     fetch RealmEye pages into the cache, e.g. /wiki/dungeons
    tools/drop_catalog.py --self-test

Run it yourself, not from an AI agent: RealmEye's robots.txt blocks AI agents by name. Every request
is checked against robots.txt for this tool's User-Agent, spaced at least 2 s apart (RealmEye asks for
1 s), and saved under ~/Library/Caches/Exalt Client Mac/realmeye/, so a page is fetched once until you
pass --refresh. Data from RealmEye (https://www.realmeye.com), credited in the catalog it builds.
"""
import argparse
import os
import sys
import time
import urllib.error
import urllib.request
import urllib.robotparser

SITE = 'https://www.realmeye.com'
AGENT = 'exalt-client-mac-drop-catalog/1.0 (personal tool, one page every 2 s, cached)'
CACHE = os.path.expanduser('~/Library/Caches/Exalt Client Mac/realmeye')
DELAY = 2.0


def cache_path(path, cache=CACHE):
    """The cache file of a site path: /wiki/abyss-of-demons → <cache>/wiki/abyss-of-demons.html."""
    clean = path.split('#')[0].split('?')[0].strip('/')
    if not clean or '..' in clean.split('/'):
        raise ValueError(f'not a page path: {path!r}')
    return os.path.join(cache, clean + '.html')


class Fetcher:
    def __init__(self, cache=CACHE, refresh=False, opener=urllib.request.urlopen, sleep=time.sleep, clock=time.monotonic):
        self.cache, self.refresh = cache, refresh
        self.opener, self.sleep, self.clock = opener, sleep, clock
        self.last, self.robots, self.delay = None, None, DELAY

    def wait(self):
        if self.last is not None:
            left = self.delay - (self.clock() - self.last)
            if left > 0: self.sleep(left)
        self.last = self.clock()

    def get(self, url):
        self.wait()
        with self.opener(urllib.request.Request(url, headers={'User-Agent': AGENT}), timeout=30) as r:
            return r.read()

    def allowed(self, path):
        if self.robots is None:
            self.robots = urllib.robotparser.RobotFileParser()
            self.robots.parse(self.get(SITE + '/robots.txt').decode('utf-8', 'replace').splitlines())
            self.delay = max(DELAY, float(self.robots.crawl_delay(AGENT) or 0))
        return self.robots.can_fetch(AGENT, SITE + path)

    def page(self, path):
        """The page's HTML, from the cache when it's there. None when robots.txt disallows it or it's missing."""
        file = cache_path(path, self.cache)
        if os.path.exists(file) and not self.refresh:
            with open(file, encoding='utf-8') as f: return f.read()
        if not self.allowed(path):
            print(f'skipped (robots.txt): {path}', file=sys.stderr)
            return None
        try:
            html = self.get(SITE + path).decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            print(f'skipped (HTTP {e.code}): {path}', file=sys.stderr)
            return None
        os.makedirs(os.path.dirname(file), exist_ok=True)
        with open(file + '.part', 'w', encoding='utf-8') as f: f.write(html)
        os.replace(file + '.part', file)   # a cut-off run never leaves half a page in the cache
        print(f'fetched {path}')
        return html


def self_test():
    import tempfile
    assert cache_path('/wiki/abyss-of-demons', '/c') == '/c/wiki/abyss-of-demons.html'
    assert cache_path('wiki/x#loot', '/c') == '/c/wiki/x.html'
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
        assert os.path.exists(os.path.join(cache, 'wiki', 'dungeons.html'))
    print('drop_catalog self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--refresh', action='store_true', help='fetch again even when cached')
    sub = parser.add_subparsers(dest='command')
    fetch = sub.add_parser('fetch', help='fetch pages into the cache')
    fetch.add_argument('paths', nargs='+')
    args = parser.parse_args()
    if args.self_test: return self_test()
    if args.command != 'fetch': parser.error('nothing to do: try fetch /wiki/dungeons')
    f = Fetcher(refresh=args.refresh)
    missing = [p for p in args.paths if f.page(p) is None]
    print(f'cache: {CACHE}')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
