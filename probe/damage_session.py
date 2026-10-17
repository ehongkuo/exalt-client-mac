#!/usr/bin/env python3
"""Bundle a completed local diagnostic run and report HP evidence without guessing causes."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('hit_analysis', HERE / 'analyze.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
FIELDS = analysis.FIELDS


def native_paths():
    data = json.loads((HERE / 'damage_paths.json').read_text())
    return {int(row['return_address'], 16): row['path'] for row in data['notification_callers']}


def summarize(events, ready=False, complete=False, lost=0, off_main=0):
    paths = native_paths()
    contexts, previous, notifications, assignments = {}, {}, {}, {}
    decreases, candidates, context_trace = [], [], []
    for e in events:
        generation = e['generation']
        if e['phase'] == 29:
            mask = e['flag0']
            contexts[generation] = dict(ns=e['ns'], breath=e['value'] if mask & 2 else None,
                frostbite=e['owner'] if mask & 4 else None,
                conditions_raw=hex(e['projectile']) if mask & 1 and e['flag2']==1 else None,
                legacy_sprite_key_raw=hex(e['projectile']) if mask & 1 and e['flag2']!=1 else None,
                local_nexusing=bool(e['flag1']) if mask & 8 else None)
            context_trace.append(dict(contexts[generation], event_id=e['id'], generation=generation))
        if e['phase'] == 5: assignments[e['id']] = e
        if e['phase'] == 3:
            notifications[e['id']] = e
            candidates.append(dict(event_id=e['id'], caller=hex(e['callsite']),
                native_path=paths.get(e['callsite'], 'unmapped'), value=e['value'],
                generation=generation, cause=None))
        if e['max'] <= 0 or e['hp'] > e['max']:
            previous.pop(generation, None)
            continue
        before = previous.get(generation)
        if before and e['hp'] < before['hp']:
            context = contexts.get(generation)
            if context is not None:
                context = dict(context) if 0 <= e['ns'] - context['ns'] <= 250000000 else None
            source = 'sampled_unattributed'
            if e['phase'] == 6:
                source = 'incoming_hp_assignment' if e['update_source'] in (1, 2) else 'hp_assignment'
            elif e['phase'] == 10:
                source = 'notification_return'
            notification = notifications.get(e['correlation']) if e['phase'] == 10 else None
            if notification and notification['generation'] != generation:
                notification = None
            caller = notification['callsite'] if notification else None
            assignment = assignments.get(e['correlation']) if e['phase'] == 6 else None
            observed_caller = assignment['callsite'] if assignment and assignment['generation'] == generation else e['callsite']
            decreases.append(dict(event_id=e['id'], ns=e['ns'], generation=generation,
                before=before['hp'], after=e['hp'], amount=before['hp'] - e['hp'],
                maximum=e['max'], path=source, caller=hex(observed_caller),
                update_context=e['update_context'], update_source=e['update_source'],
                tick_sequence=e['tick_sequence'], server_time=e['server_time'],
                notification_caller=hex(caller) if caller is not None else None,
                native_path=paths.get(caller, 'unmapped'), context=context, cause=None))
        previous[generation] = e
    deaths = [e['id'] for e in events if e['phase'] == 13]
    requests = [e for e in events if e['phase'] == 22]
    arrivals = [e for e in events if e['phase'] == 9 and e['in_nexus']]
    escaped = any(r['flag0'] and a['ns'] > r['ns'] and a['generation'] != r['generation']
                  for r in requests for a in arrivals)
    reasons = []
    if not ready: reasons.append('Hook readiness was not recorded in the text log.')
    if not complete: reasons.append('Normal session completion was not recorded.')
    if lost: reasons.append(f'{lost} dropped, overwritten or incomplete events.')
    if off_main: reasons.append(f'{off_main} off-main calls were not traced individually.')
    if requests and not escaped: reasons.append('A local request has no later observed Nexus arrival.')
    if not events: reasons.append('No diagnostic events were recovered.')
    usable = ready and complete and not lost and not off_main and bool(events)
    outcome = 'failed' if deaths else 'escaped' if escaped and usable else 'observed' if usable and not requests else 'inconclusive'
    return dict(schema=1, outcome=outcome, reasons=reasons, hp_decreases=decreases,
        notification_paths=candidates, context_trace=context_trace, death_events=deaths,
        nexus_arrival_observed=bool(arrivals), automatic_escape_observed=escaped,
        nexus_request_results=[dict(event_id=e['id'], ns=e['ns'], generation=e['generation'],
            local_nexusing=bool(e['flag0']), error=e['flag2']) for e in requests],
        nexus_arrivals=[dict(event_id=e['id'], ns=e['ns'], generation=e['generation']) for e in arrivals],
        lethal_prevention_proven=False, event_count=len(events),
        limitation='Native paths and meter values are observations, not proof of damage cause, server acceptance or lethal-hit prevention.')


def inspect(log):
    log = Path(log)
    raw = log.read_text()
    detail = analysis.analyze(log)
    events = analysis.read_events(raw)
    malformed = sum(line.startswith(('hit_probe_v2\t', 'hit_probe_v3\t', 'hit_probe_v4\t')) for line in raw.splitlines()) - len(events)
    lost = detail['completion_counters'].get('dropped', 0) + malformed
    result = summarize(events, ready='hit_probe_ready\t' in raw,
        complete='status\tcomplete' in raw, lost=lost,
        off_main=detail['completion_counters'].get('off_main_calls', 0))
    result['environment_trace'] = detail['environment_trace']
    if detail['environment_trace']['counters'].get('skipped',0):
        result['reasons'].append('Environment trace reached a capture limit; missing stacks/events are inconclusive.')
    expected = json.loads((HERE / 'damage_paths.json').read_text())['game_sha256']
    fingerprints = [line.split('sha256=', 1)[1] for line in raw.splitlines() if line.startswith('damage_build\tsha256=')]
    result['recorded_game_sha256'] = fingerprints[0] if len(fingerprints) == 1 else None
    if fingerprints != [expected]:
        result['reasons'].append('Missing or mismatched diagnostic build fingerprint.')
        if result['outcome'] != 'failed': result['outcome'] = 'inconclusive'
        for row in result['hp_decreases'] + result['notification_paths']:
            row['native_path'] = 'unmapped'
    return result


def bundle(log, destination, test_id):
    log, destination = Path(log), Path(destination).resolve()
    if log.is_symlink() or not log.is_file() or log.suffix != '.tsv':
        raise ValueError('Select a completed guard-<pid>.tsv log.')
    log = log.resolve()
    pid = log.stem.removeprefix('guard-')
    if not log.stem.startswith('guard-') or not pid.isdecimal() or not 0 < int(pid) <= 2147483647:
        raise ValueError('Expected guard-<pid>.tsv with a valid process ID')
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        pass
    except PermissionError:
        raise ValueError('Session process may still be running; quit it before bundling.')
    else:
        raise ValueError('Session process is still running; quit it before bundling.')
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copy2(log, destination / log.name)
    flight = log.with_name(f'hit-flight-{pid}.bin')
    if flight.is_file() and not flight.is_symlink(): shutil.copy2(flight, destination / flight.name)
    report = inspect(destination / log.name)
    copied_flight = destination / flight.name
    if copied_flight.exists():
        recovered = analysis.analyze(copied_flight)
        report['flight_recovery'] = recovered['flight_recovery']
        # Flight records deliberately retain only the tail. Never merge or double-count it with text.
        report['flight_tail_event_count'] = recovered['flight_recovery'].get('retained', 0)
        report['flight_tail_only'] = True
        if recovered['death_screen_entries']:
            report['outcome'] = 'failed'
            report['reasons'].append('Death-screen entry is present in the recovered flight tail.')
    fingerprints = {}
    for path in sorted(destination.iterdir()):
        fingerprints[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['test_id'] = test_id
    (destination / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    manifest = dict(schema=1, test_id=test_id, source_log=log.name, sha256=fingerprints,
        expected_game_sha256=json.loads((HERE / 'damage_paths.json').read_text())['game_sha256'],
        recorded_game_sha256=report['recorded_game_sha256'])
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    text = f"# Damage test {test_id}\n\nOutcome: **{report['outcome']}**\n\n"
    text += f"HP decreases: {len(report['hp_decreases'])}. Notification observations: {len(report['notification_paths'])}.\n\n"
    text += '\n'.join('- ' + reason for reason in report['reasons']) + '\n\n'
    text += report['limitation'] + '\n\nSee report.json for the event evidence and manifest.json for file fingerprints.\n'
    (destination / 'report.md').write_text(text)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New session bundle directory')
    parser.add_argument('--test-id', required=True)
    args = parser.parse_args()
    try:
        result = bundle(args.log, args.output, args.test_id)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    print(f"{result['outcome']}: {args.output / 'report.md'}")


if __name__ == '__main__':
    main()
