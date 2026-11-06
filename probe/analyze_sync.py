#!/usr/bin/env python3
"""Decode synchronization observations; matching IDs never imply HP coverage."""
import argparse
import json
from pathlib import Path
from analyze import read_events

TEXT_KINDS=('xp','damage','fame','level_up','quest_complete','new_class_unlock','condition_effect',
            'notification','exaltation','bxp')  # DGKAANOAENH on 2ce88d8b.


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
    texts={}
    for line in log.splitlines():
        if line.startswith('sync_object_text\t'):
            cells=dict(c.split('=',1) for c in line.rstrip('\n').split('\t')[1:3])
            texts[int(cells['event'])]=line.rstrip('\n').split('\ttext=',1)[-1]
    updates=[h for h in events if h['phase']==6 and h['update_source']==1]
    object_text=[]
    for e in (e for e in events if e['phase']==47):
        after=next((h for h in updates if h['ns']>=e['ns']),None)
        object_text.append(dict(event_id=e['id'],ns=e['ns'],handler=e['flag3'],
            kind=TEXT_KINDS[e['flag2']] if 0<=e['flag2']<len(TEXT_KINDS) else e['flag2'],
            color=hex(e['owner'] & 0xffffffff),text=texts.get(e['id']),amount=e['value'] if e['flag0'] else None,
            signed_plus=bool(e['flag1']),hp_at_text=e['hp'],max_hp=e['max'],
            next_server_hp=after and after['hp'],ms_to_next_server_hp=after and round((after['ns']-e['ns'])/1e6,1)))
    counters={}
    for line in log.splitlines():
        if line.startswith('hit_probe_summary\t'):
            counters={k:int(v) for k,v in (cell.split('=',1) for cell in line.split()[1:]) if v.isdecimal()}
    return dict(schema=1,trace_ready='sync_trace_ready\t' in log,limit_reached='sync_trace_limit\t' in log,
        counters=counters,ticks=tick_rows,
        outgoing_hit_reports=[dict(event_id=e['id'],ns=e['ns'],generation=e['generation'],own_player_id=e['update_context'],
            shooter_id=e['owner'],projectile_id=e['bullet']) for e in reports],
        received_damage=damage,hp_increases=increases,own_object_text=object_text,
        snapshot_hit_coverage='unverified',
        limitation='Client-observed ordering and equal packet identifiers are evidence for investigation only. No server processing times or per-snapshot hit acknowledgements are inferred. Missing, capped, off-main or dropped observations cannot establish absence. Healing-source attribution remains unverified; own object text (phase 47) is what the game displayed, not what the server applied.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    args=parser.parse_args()
    print(json.dumps(summarize(args.log.read_text()),indent=2))
