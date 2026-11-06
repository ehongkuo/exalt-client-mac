#!/usr/bin/env python3
"""Check the ordering proof (plan Phase 1) against hits whose applying update is known.

Proof: a hit report travels ahead of the client's next tick reply R on one ordered connection.
A later tick's round-trip field (phase 40 `bullet`) dates the latest reply the server received:
build(k) + rtt falls between the previous and current build times for exactly the reply to tick k.
So the server had the hit by B = build(k) + rtt, and every tick built at least c after B must
contain it. Repeated round-trip values prove nothing new and are skipped.

Truth: oldest-first accounting per tick, applied = heal text + HP drop (report order is application
order). Only hits that accounting clears cleanly count: no unexplained loss or bleeding while pending,
and in captures without heal text only isolated hits (nothing else pending, no rise above
regeneration between the report and the drop). Early clears must be 0; c must exceed the largest
build(E - 1) - B, where E is the tick that applied the hit.
"""
import argparse
import json
from pathlib import Path
from analyze import read_events
from analyze_untracked import latest_copies

REGEN = 5            # HP a tick may restore while applying a hit (residue limit).
BLEEDING = 0x8000    # Condition word 0; drains HP with no report.


def ticks_of(events):
    """Ticks per generation, with build time, round trip, HP before/after, heal text and reply send."""
    hp = {e['update_context']: e['hp'] for e in events if e['phase'] == 6 and e['update_source'] == 1}
    replies = {}
    for r in events:
        if r['phase'] == 41: replies.setdefault((r['generation'], r['tick_sequence'], r['server_time']), r['ns'])
    heal = [e for e in events if e['phase'] == 47 and e['flag2'] == 7 and e['flag1'] and e['value'] > 0]
    bleed = sorted((e['ns'], bool(e['projectile'] & BLEEDING)) for e in events if e['phase'] == 29 and e['flag0'] & 1)
    out, last, prev_ns = {}, {}, {}
    for e in (e for e in events if e['phase'] == 40):
        g = e['generation']; before = last.get(g)
        after = hp.get(e['correlation'], before)
        healed = sum(x['value'] for x in heal if x['generation'] == g and prev_ns.get(g, 0) < x['ns'] <= e['ns'])
        bleeding = next((on for ns, on in reversed(bleed) if ns <= e['ns']), False)
        out.setdefault(g, []).append(dict(ns=e['ns'], tick=e['tick_sequence'], build=e['server_time'], rtt=e['bullet'],
            before=before, after=after, heal=healed, bleeding=bleeding,
            reply=replies.get((g, e['tick_sequence'], e['server_time']))))
        last[g] = after; prev_ns[g] = e['ns']
    return out


def proofs(ticks):
    """For each tick index j, the newest reply index k it proves received, and when (server clock)."""
    proved = {}
    for j in range(1, len(ticks)):
        rtt = ticks[j]['rtt']
        if not rtt or rtt == ticks[j-1]['rtt']:
            continue
        lo, hi = ticks[j-1]['build'], ticks[j]['build']
        match = [k for k in range(j) if lo < ticks[k]['build'] + rtt <= hi]
        if match:  # Several matches: claim the oldest reply, which proves the least.
            proved[j] = (match[0], ticks[match[0]]['build'] + rtt)
    return proved


def truth(ticks, hits, heal_text):
    """Tick index that applied each hit, by oldest-first accounting; None when it cannot be trusted."""
    pending, applied_at, i = [], {}, 0
    for j, t in enumerate(ticks):
        while i < len(hits) and hits[i]['ns'] < t['ns']:
            pending.append([i, hits[i]['value']]); i += 1
        if t['before'] is None:
            continue
        rise = t['after'] - t['before'] - t['heal']
        applied = t['heal'] + t['before'] - t['after']
        if t['bleeding'] or applied > sum(p[1] for p in pending) + REGEN or (not heal_text and pending and rise > REGEN):
            for p in pending: applied_at[p[0]] = None  # Bleeding, untracked loss or an unseen heal.
            pending = []; continue
        partial = False
        while applied > 0 and pending:
            take = min(applied, pending[0][1]); pending[0][1] -= take; applied -= take
            if pending[0][1]: partial = True
            else: applied_at.setdefault(pending.pop(0)[0], j)
        if partial and pending and pending[0][1] <= REGEN:
            applied_at.setdefault(pending.pop(0)[0], j)
    if not heal_text:  # Without heal text, keep only hits that were alone while pending.
        for n, j in list(applied_at.items()):
            if j is None: continue
            alone = not any(hits[n]['ns'] - 1.5e9 < h['ns'] < ticks[j]['ns'] for m, h in enumerate(hits) if m != n)
            quiet = all(t['before'] is not None and t['after'] <= t['before'] + REGEN
                        for t in ticks if hits[n]['ns'] < t['ns'] < ticks[j]['ns'])
            if not (alone and quiet): applied_at[n] = None
    return applied_at


def check(text, c_ms=0):
    events = read_events(text)
    heal_text = any(e['phase'] == 47 for e in events)
    rows, skipped = [], dict(no_reply=0, no_proof=0, untrusted=0)
    for g, ticks in ticks_of(events).items():
        hits = [e for e in events if e['phase'] == 3 and e['generation'] == g and e['value'] > 0 and e['valid'] and not e['in_nexus']]
        proved, applied = proofs(ticks), truth(ticks, hits, heal_text)
        for n, h in enumerate(hits):
            R = next((k for k, t in enumerate(ticks) if t['reply'] and t['reply'] > h['ns']), None)
            if R is None: skipped['no_reply'] += 1; continue
            P = next((j for j in sorted(proved) if proved[j][0] >= R), None)
            if P is None: skipped['no_proof'] += 1; continue
            E = applied.get(n)
            if E is None: skipped['untrusted'] += 1; continue
            B = proved[P][1]
            C = next((j for j in range(P, len(ticks)) if ticks[j]['build'] >= B + c_ms), None)
            if C is None: skipped['no_proof'] += 1; continue
            rows.append(dict(seconds=round((h['ns'] - events[0]['ns']) / 1e9, 3), damage=h['value'],
                applied_tick=ticks[E]['tick'], clear_tick=ticks[C]['tick'], late_ticks=C - E,
                clear_ms_after_hit=round((ticks[C]['ns'] - h['ns']) / 1e6), applied_ms_after_hit=round((ticks[E]['ns'] - h['ns']) / 1e6),
                build_after_B=ticks[E]['build'] - B, previous_build_after_B=ticks[E-1]['build'] - B if E else None))
    need = [r['previous_build_after_B'] for r in rows if r['previous_build_after_B'] is not None]
    return dict(heal_text=heal_text, hits=len(rows), early=sum(r['late_ticks'] < 0 for r in rows),
                c_needed_ms=max(0, max(need) + 1) if need else 0, skipped=skipped, rows=rows,
                late_ticks={n: sum(r['late_ticks'] == n for r in rows) for n in sorted({r['late_ticks'] for r in rows})})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+')
    parser.add_argument('--c-ms', type=int, default=0, help='Clear on the first tick built at least this long after the proof bound')
    parser.add_argument('--json')
    args = parser.parse_args()
    result = {str(f): check(t, args.c_ms) for f, t in latest_copies(args.paths)}
    result = {k: v for k, v in result.items() if v['hits'] or any(v['skipped'].values())}
    if args.json: Path(args.json).write_text(json.dumps(result, indent=2) + '\n')
    for path, r in result.items():
        print(f"{Path(path).name}: {r['hits']} checked, early clears {r['early']}, lateness in ticks {r['late_ticks']}, "
              f"c needed {r['c_needed_ms']} ms, heal text {r['heal_text']}, skipped {r['skipped']}")


if __name__ == '__main__':
    main()
