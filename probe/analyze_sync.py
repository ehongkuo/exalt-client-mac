#!/usr/bin/env python3
"""Decode synchronization observations; matching IDs never imply HP coverage."""
import argparse
import json
from pathlib import Path
from analyze import read_events


def summarize(log):
    events=read_events(log)
    ticks=[e for e in events if e['phase']==40]
    responses=[e for e in events if e['phase']==41]
    reports=[e for e in events if e['phase']==42]
    received=[e for e in events if e['phase']==43]
    def scope(e):return e['generation'],e['update_context']
    def hit_key(e):return scope(e)+(e['owner'] & 0xffffffff,e['bullet'] & 0xffff)
    damage=[]
    for e in received:
        own=(e['projectile'] & 0xffffffff)==e['update_context']
        matches=[r for r in reports if own and hit_key(r)==hit_key(e) and r['ns']<=e['ns']]
        damage.append(dict(event_id=e['id'],ns=e['ns'],target_id=e['projectile'],own_player_id=e['update_context'],
            own_target=own,shooter_id=e['owner'],projectile_id=e['bullet'],damage=e['value'],
            flags=[e['flag0'],e['flag1'],e['flag2']],handler=e['flag3'],
            earlier_same_key_reports=[r['id'] for r in matches],ambiguous=len(matches)>1,
            proves_snapshot_coverage=False))
    tick_rows=[]
    for e in ticks:
        matches=[r for r in responses if scope(r)==scope(e) and r['tick_sequence']==e['tick_sequence'] and
                 r['server_time']==e['server_time'] and r['ns']>=e['ns']]
        hp=[h for h in events if h['phase']==6 and h['update_source']==1 and h['update_context']==e['correlation'] and e['correlation']]
        tick_rows.append(dict(event_id=e['id'],ns=e['ns'],tick_id=e['tick_sequence'],server_value=e['server_time'],
            timing_field=e['value'],quality_field=e['bullet'],hp_assignments=[h['hp'] for h in hp],
            client_responses=[r['id'] for r in matches],proves_hit_acknowledgement=False))
    entries={e['id']:e for e in events if e['phase']==5}
    increases=[]
    for e in events:
        before=entries.get(e['correlation']) if e['phase']==6 else None
        if before and e['hp']>before['hp']:
            increases.append(dict(event_id=e['id'],before=before['hp'],after=e['hp'],source=e['update_source'],
                caller=hex(before['callsite']),context=e['update_context']))
    counters={}
    for line in log.splitlines():
        if line.startswith('hit_probe_summary\t'):
            counters={k:int(v) for k,v in (cell.split('=',1) for cell in line.split()[1:]) if v.isdecimal()}
    return dict(schema=1,trace_ready='sync_trace_ready\t' in log,limit_reached='sync_trace_limit\t' in log,
        counters=counters,ticks=tick_rows,
        outgoing_hit_reports=[dict(event_id=e['id'],ns=e['ns'],generation=e['generation'],own_player_id=e['update_context'],
            shooter_id=e['owner'],projectile_id=e['bullet']) for e in reports],
        received_damage=damage,hp_increases=increases,
        snapshot_hit_coverage='unverified',
        limitation='Client-observed ordering and equal packet identifiers are evidence for investigation only. No server processing times or per-snapshot hit acknowledgements are inferred. Missing, capped, off-main or dropped observations cannot establish absence. Healing-source attribution remains unverified.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    args=parser.parse_args()
    print(json.dumps(summarize(args.log.read_text()),indent=2))
