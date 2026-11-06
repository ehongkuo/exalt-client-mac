#!/usr/bin/env python3
"""Find server HP losses that no client damage notification can explain.

Premise under test: every HP loss comes from damage the client computed and reported.
Healing only shrinks a decrease, so if the premise holds the summed HP decreases can never
exceed the summed client damage. A decrease that exceeds every unspent reported amount is
proof against the premise (or of server damage above the local calculation) at that point.

Unspent damage from earlier hits can hide a later untracked loss from that test, so each decrease
is also attributed to specific reports: the subset of reports received 100 ms to max_age_ms before
it whose sum comes closest to the loss without exceeding it by more than the regeneration tolerance.
Whatever remains is excess: damage over time, or server damage above the local calculation.
"""
import argparse
from collections import Counter
import hashlib
from itertools import combinations
import json
from pathlib import Path
from analyze import read_events

TICK_SETTERS = {0x184c115, 0x121f115, 0x91b925}  # Incoming stat handler's HP-setter return, per game build.
DOT_CONDITIONS = {0x8000: 'bleeding'}  # Condition word 0 bits; poison is not yet decoded.
MIN_ROUND_TRIP_MS = 100  # A report cannot be in an update that arrives sooner than this.
REGEN_TOLERANCE = 5  # HP an update may restore while applying a hit.


def latest_copies(paths):
    """One text per capture; a truncated copy of the same capture is dropped."""
    found = {}
    for source in paths:
        path = Path(source)
        for file in (sorted(path.rglob('guard-*.tsv')) if path.is_dir() else [path]):
            text = file.read_bytes().decode('utf-8', 'replace')
            timing = next((line for line in text.splitlines() if line.startswith('timing\t')), '')
            key = (file.name, timing or hashlib.sha256(text.encode()).hexdigest())
            if key not in found or len(text) > len(found[key][1]):
                found[key] = (file, text)
    return sorted(found.values(), key=lambda item: str(item[0]))


def context_key(ctx):
    """Known untracked-damage indicators at the time of a decrease."""
    if ctx is None:
        return 'unavailable'
    tags = []
    if ctx['flag0'] & 4 and ctx['owner'] >= 100:
        tags.append('frostbite_full')
    if ctx['flag0'] & 2 and ctx['value'] == 0:
        tags.append('breath_empty')
    return '+'.join(tags) or 'none'


def closest_subset(reports, loss, tolerance=REGEN_TOLERANCE, limit=12):
    """Reports whose damage best accounts for a loss, preferring older reports on ties."""
    candidates, best, best_sum = reports[:limit], (), 0
    for size in range(1, len(candidates) + 1):
        for subset in combinations(candidates, size):
            total = sum(r[1] for r in subset)
            if best_sum < total <= loss + tolerance:
                best, best_sum = subset, total
    return best


def inspect(text, window_ms=None, max_age_ms=1500):
    """Spend each HP decrease against unspent client damage, oldest first.

    window_ms=None never expires damage: an excess is then strict evidence. With a window,
    damage older than it is dropped, which finds losses masked by hits that never landed."""
    events = read_events(text)
    by_id = {e['id']: e for e in events}
    pool, pending, generation, ctx, last_report = [], [], None, None, None
    out = dict(reports=0, reported_damage=0, decreases=0, hp_lost=0, max_hp_changes=0,
               intervention=any(e['phase'] in (20, 21, 22, 23, 24, 30) for e in events),
               sync=any(e['phase'] == 40 for e in events), unexplained=[], excess=[], expired_reports=0)
    start = events[0]['ns'] if events else 0
    for e in events:
        if e['generation'] != generation:
            pool, pending, generation, ctx = [], [], e['generation'], None
        if e['phase'] == 29:
            ctx = e
        if e['phase'] == 3 and e['value'] > 0 and e['valid'] and not e['in_nexus']:
            pool.append([e['ns'], e['value']]); last_report = e['ns']
            pending.append((e['ns'], e['value'], ctx['projectile'] if ctx else None))
            out['reports'] += 1; out['reported_damage'] += e['value']
        if e['phase'] != 6:
            continue
        before = by_id.get(e['correlation'])
        if not before or before['hp'] <= e['hp']:
            continue
        if before['max'] != e['max'] or before['hp'] > e['max']:
            out['max_hp_changes'] += 1  # Gear change or clamp, not damage.
            continue
        if window_ms is not None:
            pool = [item for item in pool if e['ns'] - item[0] <= window_ms * 1e6]
        loss = need = before['hp'] - e['hp']
        fresh = [r for r in pending if e['ns'] - r[0] <= max_age_ms * 1e6]
        out['expired_reports'] += len(pending) - len(fresh)
        pending = fresh
        eligible = [r for r in pending if e['ns'] - r[0] >= MIN_ROUND_TRIP_MS * 1e6]
        used = closest_subset(eligible, loss)
        pending = [r for r in pending if r not in used]
        residual = loss - sum(r[1] for r in used)
        if residual > 0:
            conditions = ctx['projectile'] if ctx else None
            tags = [name for bit, name in DOT_CONDITIONS.items() if conditions is not None and conditions & bit]
            if any(r[2] != conditions for r in used):
                tags.append('conditions_changed')  # A buff or debuff arrived between the hit and this update.
            if any(r[1] > loss for r in eligible if r not in used):
                tags.append('report_larger_than_loss')  # Possibly a hit masked by healing; ambiguous.
            known = context_key(ctx)
            out['excess'].append(dict(event_id=e['id'], seconds=(e['ns'] - start) / 1e9, loss=loss, excess=residual,
                attributed=[r[1] for r in used], context='+'.join(tags + ([known] if known not in ('none', 'unavailable') else [])) or 'none',
                conditions=f"{conditions:#x}" if conditions is not None else None))
        out['decreases'] += 1; out['hp_lost'] += loss
        while need and pool:
            spent = min(need, pool[0][1]); pool[0][1] -= spent; need -= spent
            if not pool[0][1]:
                pool.pop(0)
        if need:
            out['unexplained'].append(dict(event_id=e['id'], seconds=(e['ns'] - start) / 1e9, hp_before=before['hp'],
                hp_after=e['hp'], max_hp=e['max'], loss=loss, unexplained=need,
                incoming_tick=e['update_source'] == 1 and before['callsite'] in TICK_SETTERS,
                context=context_key(ctx), conditions=f"{ctx['projectile']:#x}" if ctx else None,
                ms_since_report=(e['ns'] - last_report) / 1e6 if last_report else None))
    return out


def run(paths, window_ms=2000, max_age_ms=1500):
    captures = []
    for file, text in latest_copies(paths):
        strict, windowed = inspect(text, max_age_ms=max_age_ms), inspect(text, window_ms, max_age_ms)
        if not strict['reports'] and not strict['decreases']:
            continue
        captures.append(dict(path=str(file), **{k: v for k, v in strict.items() if k != 'unexplained'},
                             strict=strict['unexplained'], windowed=windowed['unexplained']))
    by_context = Counter(u['context'] for c in captures for u in c['strict'])
    excess = Counter()
    for c in captures:
        for x in c['excess']: excess[x['context']] += x['excess']
    return dict(schema=1, window_ms=window_ms, captures=captures,
                totals=dict(captures=len(captures), reports=sum(c['reports'] for c in captures),
                            decreases=sum(c['decreases'] for c in captures),
                            strict_unexplained=sum(len(c['strict']) for c in captures),
                            windowed_unexplained=sum(len(c['windowed']) for c in captures),
                            excess_decreases=sum(len(c['excess']) for c in captures),
                            excess_hp=sum(excess.values())),
                excess_hp_by_context=dict(excess), max_age_ms=max_age_ms,
                strict_by_context=dict(by_context),
                premise_contradicted_without_known_source=by_context['none'] + by_context['unavailable'] > 0,
                meaning='Strict: decreases larger than all unspent client damage in the same map. Windowed: '
                        'the same with client damage expiring after window_ms, so a report the server never '
                        'applied cannot hide a later loss; a windowed-only finding can also be a late hit. Excess: '
                        'HP lost beyond the reports attributed to each decrease (damage over time, or server damage '
                        'above the local calculation); report_larger_than_loss marks findings healing may explain.')


def markdown(result):
    t = result['totals']
    lines = ['# Untracked HP loss', '',
             f"{t['captures']} captures, {t['reports']} client damage reports, {t['decreases']} server HP decreases.",
             f"Strict unexplained decreases: {t['strict_unexplained']}; with a {result['window_ms']} ms window: {t['windowed_unexplained']}.",
             f"Strict findings by context: {result['strict_by_context'] or 'none'}.",
             f"Excess beyond attributed reports: {t['excess_hp']} HP in {t['excess_decreases']} decreases; by context: "
             f"{result['excess_hp_by_context'] or 'none'}.", '',
             '| Capture | Reports | Decreases | Strict | Windowed | Excess HP | Strict contexts |', '|---|---:|---:|---:|---:|---:|---|']
    for c in result['captures']:
        contexts = dict(Counter(u['context'] for u in c['strict']))
        lines.append(f"| {Path(c['path']).name}{' (sync)' if c['sync'] else ''}{' (intervention)' if c['intervention'] else ''} | "
                     f"{c['reports']} | {c['decreases']} | {len(c['strict'])} | {len(c['windowed'])} | "
                     f"{sum(x['excess'] for x in c['excess'])} | {contexts or ''} |")
    lines += ['', result['meaning']]
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+')
    parser.add_argument('--window-ms', type=float, default=2000)
    parser.add_argument('--max-age-ms', type=float, default=1500, help='Oldest report a decrease may be attributed to')
    parser.add_argument('--json')
    args = parser.parse_args()
    result = run(args.paths, args.window_ms, args.max_age_ms)
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=2) + '\n')
    print(markdown(result))


if __name__ == '__main__':
    main()
