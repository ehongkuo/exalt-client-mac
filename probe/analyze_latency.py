#!/usr/bin/env python3
"""Read-only damage visibility calibration. HP matches are not acknowledgements."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics
from analyze import read_events


def fields(line):
    return dict(cell.split('=', 1) for cell in line.split('\t')[1:] if '=' in cell)


def percentiles(values):
    if not values:
        return dict(count=0)
    ordered = sorted(values)
    return dict(count=len(values), min_ms=ordered[0], median_ms=statistics.median(ordered),
                observed_p90_ms=ordered[math.ceil(.9 * len(ordered)) - 1],
                observed_p99_ms=ordered[math.ceil(.99 * len(ordered)) - 1], max_ms=ordered[-1])


def current_fingerprint():
    local = Path(__file__).with_name('game-build.sha256')
    if not local.exists():
        local = Path(__file__).resolve().parents[1] / 'guard/game-build.sha256'
    return local.read_text().split()[0]


def inspect_log(text, expected_sha=None):
    lines = text.splitlines()
    ready = [fields(line) for line in lines if line.startswith('hit_probe_ready\t')]
    counters = [fields(line) for line in lines if line.startswith('hit_probe_summary\t')]
    configurations = [fields(line) for line in lines if line.startswith('guard_config\t')]
    events = read_events(text)
    reasons = []
    fingerprints = [fields(line).get('sha256') for line in lines if line.startswith('damage_build\t')]
    if expected_sha and fingerprints != [expected_sha]:
        reasons.append('missing_or_mismatched_game_build')
    if not ready or any(row.get('fatal_intervention') != '0' for row in ready):
        reasons.append('not_explicitly_passive')
    if any(line.startswith('damage_verification\t') for line in lines):
        reasons.append('synthetic_verification')
    if not configurations or any(row.get('armed') != '0' or row.get('potion') != '0' for row in configurations):
        reasons.append('gameplay_automation_not_disabled')
    try:
        incomplete = not counters or any(int(row.get('dropped', '0')) or int(row.get('off_main_calls', '0')) for row in counters)
    except ValueError:
        incomplete = True
    if incomplete:
        reasons.append('missing_or_incomplete_observation_counters')
    if 'sync_trace_limit\t' in text:
        reasons.append('trace_capped')
    if any(e['phase'] in (20, 21, 22, 23, 24, 30) for e in events):
        reasons.append('intervention_events_present')
    if reasons:
        return dict(eligible=False, excluded_reasons=reasons, samples=[], unresolved=[], positive_reports=0)

    by_id = {e['id']: e for e in events}
    latest_calculation = {}
    report_calculations = {}
    starts = {}
    pipeline_exclusions = Counter()
    used_calculations = set()
    for e in events:
        if e['phase'] == 12 and e['flag0'] and e['flag1']:
            latest_calculation[e['generation']] = e
        elif e['phase'] == 1:
            calculation = latest_calculation.pop(e['generation'], None)
            if calculation:
                report_calculations[e['id']] = calculation
        elif e['phase'] == 3 and e['value'] > 0 and e['correlation']:
            report = by_id.get(e['correlation'])
            calculation = report_calculations.get(e['correlation'])
            if not report or not calculation or calculation['value'] != e['value'] or calculation['id'] in used_calculations:
                pipeline_exclusions['unpaired_calculator_report_notification'] += 1
                continue
            if not (calculation['generation'] == report['generation'] == e['generation'] and
                    calculation['ns'] <= report['ns'] <= e['ns'] and e['valid'] and not e['in_nexus']):
                pipeline_exclusions['invalid_scope_or_order'] += 1
                continue
            used_calculations.add(calculation['id'])
            starts[calculation['id']] = dict(calculation_id=calculation['id'], report_id=report['id'],
                notification_id=e['id'], generation=e['generation'], damage=e['value'],
                start_ns=calculation['ns'], report_ns=report['ns'], healing_observed=False)

    pending = []
    samples = []
    unresolved = []
    generation = None
    other_losses = 0
    uncertain_prior_reports = False

    def abandon(reason, end_ns):
        nonlocal uncertain_prior_reports
        if pending:
            uncertain_prior_reports = True
        for item in pending:
            unresolved.append(dict(**item, reason=reason, observation_ended_ns=end_ns))
        pending.clear()

    for e in events:
        if generation is not None and e['generation'] != generation:
            abandon('scope_changed', e['ns'])
            uncertain_prior_reports = False
        generation = e['generation']
        if e['id'] in starts:
            pending.append(starts[e['id']].copy())
        if e['phase'] in (7, 13):
            abandon('nexus_or_death_transition', e['ns'])
        if e['phase'] == 3 and e['value'] > 0 and not e['correlation']:
            abandon('other_damage_notification', e['ns'])
        if e['phase'] != 6:
            continue
        before = by_id.get(e['correlation'])
        if not before or e['update_source'] != 1 or before['callsite'] != 0x184c115:
            if before and e['hp'] < before['hp']:
                abandon('non_tick_hp_loss', e['ns'])
            continue
        delta = e['hp'] - before['hp']
        if delta > 0:
            for item in pending:
                item['healing_observed'] = True
        elif delta < 0:
            if not pending:
                other_losses += 1
                continue
            if len(pending) != 1:
                abandon('overlapping_reports', e['ns'])
                continue
            item = pending.pop()
            if -delta > item['damage'] or e['hp'] <= 0:
                uncertain_prior_reports = True
                unresolved.append(dict(**item, reason='excess_or_terminal_hp_loss', observation_ended_ns=e['ns']))
                continue
            quality = ('isolated_exact' if -delta == item['damage'] and not item['healing_observed']
                       else 'isolated_healing_compatible')
            samples.append(dict(**item, hp_assignment_id=e['id'], hp_before=before['hp'], hp_after=e['hp'],
                net_hp_loss=-delta, quality=quality, visibility_ms=(e['ns'] - item['start_ns']) / 1e6,
                report_handoff_ms=(item['report_ns'] - item['start_ns']) / 1e6,
                confirmed_acknowledgement=False, prior_unresolved_reports=uncertain_prior_reports))
    if events:
        abandon('capture_ended_without_identifiable_decrease', events[-1]['ns'])
    fifo = []
    # Supplementary hypothesis only: never silently discard the slow overlapping
    # tail. Accept a one-for-one FIFO illustration only when each scope's whole
    # sequence has equal report/decrease counts and compatible amounts/order.
    for scope in sorted({item['generation'] for item in starts.values()}):
        shots = [item for item in starts.values() if item['generation'] == scope]
        decreases = [e for e in events if e['phase'] == 6 and e['generation'] == scope and
            e['update_source'] == 1 and e['correlation'] in by_id and
            by_id[e['correlation']]['callsite'] == 0x184c115 and e['hp'] < by_id[e['correlation']]['hp']]
        if len(shots) != len(decreases) or any(
                d['ns'] < shot['start_ns'] or not 0 < by_id[d['correlation']]['hp'] - d['hp'] <= shot['damage']
                for shot, d in zip(shots, decreases)):
            continue
        fifo.extend(dict(calculation_id=shot['calculation_id'], hp_assignment_id=d['id'],
            visibility_ms=(d['ns']-shot['start_ns'])/1e6, confirmed_acknowledgement=False)
            for shot, d in zip(shots, decreases))
    return dict(eligible=True, excluded_reasons=[], samples=samples, unresolved=unresolved,
                positive_reports=len(starts), fifo_hypothesis=fifo, pipeline_exclusions=dict(pipeline_exclusions),
                other_hp_losses=other_losses, exit_complete=counters[-1].get('complete') == '1',
                endpoint='audited calculator return to incoming HP setter return',
                recorded_game_sha256=fingerprints[0] if len(fingerprints)==1 else None)


def scan(paths, expected_sha=None):
    expected_sha = expected_sha or current_fingerprint()
    candidates = {}
    duplicates = []
    for source in paths:
        path = Path(source)
        files = sorted(path.rglob('guard-*.tsv')) if path.is_dir() else [path]
        for file in files:
            if not file.is_file():
                continue
            text = file.read_bytes().decode('utf-8')
            first_timing = next((line for line in text.splitlines() if line.startswith('timing\t')), '')
            key = (file.name, first_timing or hashlib.sha256(text.encode()).hexdigest())
            if key in candidates:
                old_file, old_text = candidates[key]
                if text.startswith(old_text) or old_text.startswith(text):
                    if len(text) > len(old_text):
                        duplicates.append(str(old_file)); candidates[key] = (file, text)
                    else:
                        duplicates.append(str(file))
                    continue
                # Divergent copies must not count as independent measurements.
                raise ValueError(f'Divergent copies of capture {file.name}; inspect before pooling')
            candidates[key] = (file, text)
    runs = []
    for file, text in candidates.values():
        run = inspect_log(text, expected_sha)
        run.update(path=str(file.resolve()), sha256=hashlib.sha256(text.encode()).hexdigest(), bytes=len(text.encode()))
        runs.append(run)
    samples = [dict(sample, capture=run['path']) for run in runs for sample in run['samples']]
    exact = [s['visibility_ms'] for s in samples if s['quality'] == 'isolated_exact' and not s['prior_unresolved_reports']]
    compatible = [s['visibility_ms'] for s in samples if s['quality'] == 'isolated_healing_compatible' and not s['prior_unresolved_reports']]
    quarantined = sum(s['prior_unresolved_reports'] for s in samples)
    fifo = [item['visibility_ms'] for r in runs for item in r.get('fifo_hypothesis', [])]
    unresolved = sum(len(r['unresolved']) for r in runs)
    return dict(schema=1, expected_game_sha256=expected_sha, runs=runs, duplicate_copies_excluded=duplicates,
        isolated_exact=percentiles(exact), isolated_healing_compatible=percentiles(compatible),
        positive_reports=sum(r['positive_reports'] for r in runs),
        damage_runs=sum(r['eligible'] and r['positive_reports']>0 for r in runs),
        unresolved_reports=unresolved, quarantined_candidates=quarantined, fifo_hypothesis=percentiles(fifo), usable_runs=sum(r['eligible'] for r in runs),
        reliable_p99_established=False, automatic_threshold_change=False,
        statistical_target=dict(quantile=.99, confidence=.95, minimum_independent_representative_samples=299,
            meaning='299 iid representative observations give a 95% chance that the sample maximum reaches the population p99. This is not a precise p99 estimate; correlated sessions and selective matching weaken it.'),
        limitation='Even exact isolated HP matches are inferred visibility, not keyed damage acknowledgements. Healing/other damage can mimic a match. Ambiguous and unmatched reports are excluded from latency percentiles but counted explicitly; selection can hide slow tails. Game-build and server-region provenance require separate verification. No hard delivery bound or production timing change is established.')


def markdown(result):
    lines = ['# Damage visibility calibration', '',
        f"Passive runs: {result['usable_runs']}, including {result['damage_runs']} with {result['positive_reports']} positive reports; duplicate copies excluded: {len(result['duplicate_copies_excluded'])}.", '',
        '| Evidence class | Samples | Median | Observed p90 | Observed maximum |',
        '|---|---:|---:|---:|---:|']
    for key, label in [('isolated_exact', 'Isolated exact HP decrease'), ('isolated_healing_compatible', 'Isolated decrease compatible with healing'), ('fifo_hypothesis', 'Complete-sequence FIFO hypothesis; ambiguous')]:
        row = result[key]
        values = [f"{row[k]:.1f} ms" if k in row else '—' for k in ['median_ms', 'observed_p90_ms', 'max_ms']]
        lines.append(f"| {label} | {row['count']} | {' | '.join(values)} |")
    lines += ['', f"Unresolved reports: {result['unresolved_reports']}; later candidates quarantined because prior reports are unresolved: {result['quarantined_candidates']}. Neither group establishes latency.", '',
        '**A reliable population p99 is not established. No production timing was changed.**', '', result['limitation'], '',
        result['statistical_target']['meaning'], '', '## Run eligibility', '']
    for run in result['runs']:
        status = 'passive; ' + str(run['positive_reports']) + ' paired positive reports' if run['eligible'] else ', '.join(run['excluded_reasons'])
        lines.append(f"- `{Path(run['path']).name}`: {status}.")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, action='append', required=True)
    parser.add_argument('--json', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = scan(args.input)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2) + '\n')
    args.report.write_text(markdown(result))
    print(json.dumps({k:result[k] for k in ['usable_runs', 'isolated_exact', 'isolated_healing_compatible', 'unresolved_reports', 'quarantined_candidates', 'fifo_hypothesis', 'reliable_p99_established']}, indent=2))


if __name__ == '__main__':
    main()
