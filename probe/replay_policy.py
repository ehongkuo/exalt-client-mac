#!/usr/bin/env python3
"""Replay recorded probe captures through the real fatal policy, offline.

Read-only. Each capture's audited damage, incoming HP assignments and ticks are
fed to probe/policy_replay.c compiled against one or more policy headers, so a
candidate policy can be compared with the current one on the same evidence.
Outcomes are only meaningful for passive captures, where no escape altered play.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from analyze import read_events

ROOT = Path(__file__).resolve().parents[1]
DRIVER = Path(__file__).with_name('policy_replay.c')
TERRAIN_NOTIFY_CALLER, AREA_NOTIFY_CALLER = 0x196ed65, 0x183f7be
REASONS = {0: 'none', 1: 'lethal', 2: 'stale', 3: 'capacity'}


def build_driver(policy, out_dir):
    binary = Path(out_dir) / f'policy-replay-{hashlib.sha256(str(policy).encode()).hexdigest()[:12]}'
    subprocess.run(['clang', '-O1', '-Wall', '-Wextra', '-Werror', f'-DFATAL_POLICY_PATH="{Path(policy).resolve()}"',
                    str(DRIVER), '-o', str(binary)], check=True)
    return binary


def inputs(events):
    """Translate events into driver lines, mirroring hit_probe.h call order."""
    lines, deaths, scopes, ends = [], {}, [], {}
    scope = None
    for e in events:
        if e['in_nexus']:
            if scope is not None:ends.setdefault(scope, 'nexus')
            scope = None
            continue
        if e['generation'] != scope:
            scope = e['generation'];scopes.append(scope)
            lines.append((scope, f"G {e['ns']}"))
        phase, ns = e['phase'], e['ns']
        if phase == 12 and e['flag0'] and e['flag1']:
            lines.append((scope, f"D {ns} {e['hp']} {e['value']}"))
        elif phase == 3 and e['callsite'] in (TERRAIN_NOTIFY_CALLER, AREA_NOTIFY_CALLER):
            lines.append((scope, f"D {ns} {e['hp']} {e['value']}"))
        elif phase == 6 and e['update_source'] in (1, 2):
            lines.append((scope, f"H {ns} {e['hp']}"))
        elif phase == 16:
            lines.append((scope, f"T {ns}"))
        elif phase == 17:
            lines.append((scope, f"R {ns} {e['hp']} {e['tick_sequence'] & 0xffffffff} {e['server_time'] & 0xffffffff}"))
        elif phase == 7:
            ends.setdefault(scope, 'manual_nexus')
        if (phase == 6 and e['hp'] <= 0) or phase in (13, 15):
            deaths.setdefault(scope, ns)
    return lines, deaths, scopes, ends


def replay(binary, events):
    lines, deaths, scopes, ends = inputs(events)
    feed = '\n'.join(line for _, line in lines) + '\n'
    out = subprocess.run([str(binary)], input=feed, capture_output=True, text=True, check=True).stdout.splitlines()
    # The driver prints exactly one row per D/H/R, in order; pair them back to scopes.
    owners = [scope for scope, line in lines if line[0] in 'DHR']
    if len(owners) != len(out):
        raise ValueError('driver output out of step with inputs')
    results = {s: dict(scope=s, hits=0, damage=0, requests=[], rebases=0, max_rebase_retired=0,
                       min_projected=None, death_ns=deaths.get(s), ended=ends.get(s, 'capture_end'))
               for s in scopes}
    for scope, row in zip(owners, out):
        cells = row.split()
        r = results[scope]
        if cells[0] == 'D':
            damage, decision, reason, projected = int(cells[2]), int(cells[3]), int(cells[4]), int(cells[6])
            if damage > 0:
                r['hits'] += 1;r['damage'] += damage
                r['min_projected'] = projected if r['min_projected'] is None else min(r['min_projected'], projected)
            if decision == 1:
                r['requests'].append(dict(ns=int(cells[1]), reason=REASONS.get(reason, reason), projected=projected))
        elif cells[0] == 'R' and cells[3] == '1':
            r['rebases'] += 1;r['max_rebase_retired'] = max(r['max_rebase_retired'], int(cells[4]))
    for r in results.values():
        first = r['requests'][0]['ns'] if r['requests'] else None
        death = r['death_ns']
        r['outcome'] = ('escape_before_death' if death is not None and first is not None and first < death else
                        'missed_death' if death is not None else
                        'request_without_death' if first is not None else 'quiet')
    return [r for r in results.values() if r['hits'] or r['death_ns'] is not None]


def captures(paths):
    """Unique captures; a shorter copy that prefixes a longer one is a duplicate."""
    kept = {}
    for source in paths:
        path = Path(source)
        for file in (sorted(path.rglob('guard-*.tsv')) if path.is_dir() else [path]):
            if not file.is_file():
                continue
            text = file.read_bytes().decode('utf-8', 'replace')
            timing = next((l for l in text.splitlines() if l.startswith('timing\t')), '')
            key = (file.name, timing or hashlib.sha256(text.encode()).hexdigest())
            old = kept.get(key)
            if old and (old[1].startswith(text) or text.startswith(old[1])):
                if len(text) > len(old[1]):kept[key] = (file, text)
                continue
            kept[key if not old else key + (hashlib.sha256(text.encode()).hexdigest(),)] = (file, text)
    return list(kept.values())


def passive(text):
    ready = [l for l in text.splitlines() if l.startswith('hit_probe_ready\t')]
    return bool(ready) and all('fatal_intervention=0' in l for l in ready)


def run(paths, policies, out_dir):
    binaries = {str(p): build_driver(p, out_dir) for p in policies}
    report = dict(schema=1, policies=list(binaries), captures=[],
                  limitation='Deaths and survival come from passive captures only. A request without a death '
                             'is an early escape under that policy, unless the player was about to Nexus anyway. '
                             'Untracked damage and server-side calculation are not modeled.')
    for file, text in captures(paths):
        events = read_events(text)
        if not any(e['phase'] in (12, 16) for e in events):
            continue
        entry = dict(path=str(file.resolve()), sha256=hashlib.sha256(text.encode()).hexdigest(),
                     passive=passive(text), results={})
        for policy, binary in binaries.items():
            entry['results'][policy] = replay(binary, events)
        report['captures'].append(entry)
    totals = {}
    for policy in binaries:
        counts = {}
        for c in report['captures']:
            if not c['passive']:
                continue
            for r in c['results'][policy]:
                counts[r['outcome']] = counts.get(r['outcome'], 0) + 1
        totals[policy] = counts
    report['passive_outcomes'] = totals
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--input', type=Path, action='append', required=True)
    parser.add_argument('--policy', type=Path, action='append',
                        help='Policy header to replay; repeat to compare. Default: probe/fatal_policy.h')
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    policies = args.policy or [ROOT / 'probe/fatal_policy.h']
    with tempfile.TemporaryDirectory() as out_dir:
        report = run(args.input, policies, out_dir)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(captures=len(report['captures']),
                          passive=sum(c['passive'] for c in report['captures']),
                          passive_outcomes=report['passive_outcomes']), indent=2))


if __name__ == '__main__':
    main()
