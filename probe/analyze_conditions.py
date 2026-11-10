#!/usr/bin/env python3
"""Per-hit debuff evidence from a diagnostic capture (hardening plan Phase 0 item 4, Phase 3 C).

For every projectile hit: its damage, the effect IDs it applies (phase 31), the projectile's damage
inputs (phase 32) and the condition bits gained before the next hit or within a second (phase 29).
The summary answers two questions: which condition each effect ID turns on, and which projectile
field is the base damage (base minus damage is then the DEF the client used, constant per character).
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
from analyze import read_events
from analyze_untracked import condition_names, latest_copies

WINDOW_NS = 1_000_000_000


def hits(events):
    effects = {e['correlation']: list(e['projectile'].to_bytes(8, 'little')[:min(e['value'], 8)])
               for e in events if e['phase'] == 31}
    shots = {e['correlation']: e for e in events if e['phase'] == 32}
    contexts = [e for e in events if e['phase'] == 29 and e['flag0'] & 1 and e['flag2'] == 1]
    notes = [e for e in events if e['phase'] == 3 and e['id'] in shots]
    rows = []
    for i, n in enumerate(notes):
        end = min(n['ns'] + WINDOW_NS, notes[i + 1]['ns'] if i + 1 < len(notes) else n['ns'] + WINDOW_NS)
        same = [c for c in contexts if c['generation'] == n['generation']]
        before = next((c['projectile'] for c in reversed(same) if c['ns'] <= n['ns']), None)
        after = [c['projectile'] for c in same if n['ns'] < c['ns'] <= end]
        gained = 0
        for bits in after:
            gained |= bits & ~(before or 0)
        s = shots[n['id']]
        rows.append(dict(event_id=n['id'], ns=n['ns'], damage=n['value'], effect_ids=effects.get(n['id'], []),
                         shot_a=s['value'] if s['flag3'] & 1 else None, shot_b=s['owner'] if s['flag3'] & 2 else None,
                         min_damage=s['flag0'] if s['flag3'] & 4 else None, max_damage=s['flag1'] if s['flag3'] & 4 else None,
                         armor_piercing=bool(s['flag2']) if s['flag3'] & 4 else None,
                         conditions_before=hex(before) if before is not None else None,
                         gained=condition_names(gained), gained_raw=hex(gained)))
    return rows


def summarize(rows):
    by_effect = defaultdict(Counter)
    for r in rows:
        for effect in set(r['effect_ids']):
            by_effect[effect]['hits'] += 1
            by_effect[effect].update(r['gained'])
    # A base-damage field gives the same (field - damage) on plain hits: the DEF the client used.
    plain = [r for r in rows if not r['effect_ids'] and not r['armor_piercing'] and r['conditions_before'] in ('0x0', None)]
    implied = {key: Counter(r[key] - r['damage'] for r in plain if r[key] is not None)
               for key in ('shot_a', 'shot_b', 'min_damage', 'max_damage')}
    return dict(hits=len(rows), effect_ids={str(k): dict(v) for k, v in sorted(by_effect.items())},
                implied_def_on_plain_hits={k: dict(v.most_common(5)) for k, v in implied.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('paths', nargs='+', help='guard-*.tsv files or folders')
    parser.add_argument('--hits', action='store_true', help='also print every hit')
    args = parser.parse_args()
    for file, text in latest_copies(args.paths):
        rows = hits(read_events(text))
        out = dict(capture=str(file), **summarize(rows))
        if args.hits:
            out['per_hit'] = rows
        print(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()
