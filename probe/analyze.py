#!/usr/bin/env python3
"""Summarize local observations without claiming server acknowledgement."""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics

FIELDS=('id','ns','epoch','phase','generation','callsite','correlation','bullet','owner','value','hp','max','in_nexus','valid','projectile','flag0','flag1','flag2','flag3','work_ns','update_context','tick_sequence','server_time','update_source')

def read_events(log):
    events=[];threshold=None
    for line in log.splitlines():
        row=line.split('\t')
        if row[0]=='guard_config':
            for cell in row[1:]:
                if cell.startswith('nexus='):
                    try:threshold=int(cell[6:])
                    except ValueError:pass
        if row[0] in ('hit_probe_v2','hit_probe_v3','hit_probe_v4') and len(row) in (21,25):
            try:
                event=dict.fromkeys(FIELDS,0)
                event.update({key:(float(value) if key=='epoch' else int(value)) for key,value in zip(FIELDS,row[1:])})
                event['threshold_percent']=threshold
                events.append(event)
            except ValueError:
                continue
    return events

def incident_summary(events):
    """Decode the bounded production history without replaying it as live damage."""
    def signed(value):return value-(1<<64) if value>=(1<<63) else value
    result=[];history=[]
    for e in events:
        if 100<=e['phase']<199:
            history.append(e)
        elif e['phase']==199:
            result.append(dict(trigger_phase=e['value'],armed=bool(e['flag0']),
                blocking=bool(e['flag1']),enabled=bool(e['flag2']),
                complete=not e['flag3'] and len(history)==e['owner'],
                history=[dict(id=row['id'],before_trigger_ms=(e['ns']-row['ns'])/1e6,
                    phase=row['phase']-100,caller=hex(row['callsite']),hp=row['hp'],correlation=row['correlation'],
                    eligibility_bits=row['valid'] if row['phase']!=127 else None,
                    value=row['value'],source=row['update_source'],context=row['update_context'],
                    pending=signed(row['work_ns']),projected=signed(row['projectile']),
                    flag0=row['flag0'],flag1=row['flag1'],flag2=row['flag2'],flag3=row['flag3']) for row in history],
                limitation='Last 64 main-thread boundaries only; manual or confirmed automatic Nexus also saves history. A terminal incoming event does not identify the original damage producer. Queue drops or abrupt process exit can lose the incident.'))
            history=[]
    return result

def analyze(path,threshold=None):
    if Path(path).suffix=='.bin':
        spec=importlib.util.spec_from_file_location('recover_flight',Path(__file__).with_name('recover_flight.py'))
        recovery=importlib.util.module_from_spec(spec);spec.loader.exec_module(recovery)
        log=recovery.recover(path)
    else:log=Path(path).read_text()
    events=read_events(log)
    counters={}
    for line in log.splitlines():
        row=line.split('\t')
        if row[0]=='hit_probe_summary':
            for cell in row[1:]:
                key,_,value=cell.partition('=')
                if value.isdecimal():counters[key]=int(value)
    environment_types={}
    environment_counters={}
    for line in log.splitlines():
        cells=line.split('\t')
        if cells[0]=='environment_message_type':
            fields=dict(cell.split('=',1) for cell in cells[1:] if '=' in cell)
            if fields.get('id','').isdigit():environment_types[int(fields['id'])]=fields.get('name')
        if cells[0]=='environment_trace_summary':
            environment_counters=dict((k,int(v)) for k,v in (cell.split('=',1) for cell in cells[1:]) if v.isdecimal())
    environment=dict(enabled='environment_trace_ready\t' in log, message_types=environment_types,
        counters=environment_counters,
        sends=[dict(event_id=e['id'],ns=e['ns'],generation=e['generation'],caller=hex(e['callsite']),
                    type_id=e['owner'],type_name=environment_types.get(e['owner'])) for e in events if e['phase']==31],
        frames=[dict(event_id=e['id'],trigger_id=e['correlation'],trigger_phase=e['value'],
                     frame_index=e['owner'],return_address=hex(e['callsite'])) for e in events if e['phase']==32],
        limitation='Stacks are best effort and send stacks are deduplicated by caller/type. Meter proximity is not causation. Missing events or frames cannot establish absence of a local producer.')
    reports={e['id']:e for e in events if e['phase']==1}
    notifications=[e for e in events if e['phase']==3]
    returns={e['correlation']:e for e in events if e['phase']==2}
    paired=[]
    for e in notifications:
        r=reports.get(e['correlation']);end=returns.get(e['correlation'])
        if r and end and r['generation']==e['generation'] and r['ns']<=end['ns']<=e['ns']:
            paired.append({'report_id':r['id'],'bullet':r['bullet'],'owner':r['owner'],
                'notification_value':e['value'],'report_to_notification_us':(e['ns']-r['ns'])/1000,
                'report_duration_us':(end['ns']-r['ns'])/1000})
    changes=[e for e in events if e['phase']==4]
    leads=[]
    for e in notifications:
        after=next((h for h in changes if h['generation']==e['generation'] and h['ns']>e['ns'] and h['valid'] and e['valid'] and h['hp']<e['hp']),None)
        if after:leads.append((after['ns']-e['ns'])/1e6)
    assignments={e['id']:e for e in events if e['phase']==5}
    assignments_after=[{'caller':hex(assignments[e['correlation']]['callsite']),
        'before':assignments[e['correlation']]['hp'],'argument':e['value'],'after':e['hp']}
        for e in events if e['phase']==6 and e['correlation'] in assignments]
    nexus=[]
    for e in events:
        if e['phase']!=7 or e['flag0']:continue
        transition=next((h for h in events if h['phase']==9 and h['ns']>e['ns'] and h['generation']!=e['generation']),None)
        following=[h['id'] for h in reports.values() if h['ns']>e['ns'] and (not transition or h['ns']<transition['ns'])]
        nexus.append({'entry_id':e['id'],'reports_before_next_identity_or_map_transition':following,
            'next_transition_ms':(transition['ns']-e['ns'])/1e6 if transition else None,
            'next_transition_in_nexus':transition['in_nexus'] if transition else None})
    zero=[e for e in events if e['phase']==15]
    death=[e for e in events if e['phase']==13]
    damage=[e for e in events if e['phase']==12 and (not e['flag1'] or e['flag0'])]
    unclassified_damage=[e for e in events if e['phase']==12 and e['flag1'] and not e['flag0']]
    damage_pairs=[]
    report_calculations={}
    previous_report={}
    for report in reports.values():
        lower=previous_report.get(report['generation'],-1)
        candidates=[d for d in damage if d['generation']==report['generation'] and lower<d['ns']<=report['ns'] and report['ns']-d['ns']<10000000]
        if len(candidates)==1:report_calculations[report['id']]=candidates[0]
        previous_report[report['generation']]=report['ns']
    for e in notifications:
        report=reports.get(e['correlation']);prior=report_calculations.get(e['correlation'])
        if prior and report and prior['ns']<=report['ns']<=e['ns'] and e['generation']==report['generation']:
            damage_pairs.append({'calculation_id':prior['id'],'report_id':report['id'],'notification_id':e['id'],
                'calculated_value':prior['value'],'notification_value':e['value'],'values_match':prior['value']==e['value'],
                'before_report_us':(report['ns']-prior['ns'])/1000,'association':'temporal_only'})
    recovery_info={}
    for line in log.splitlines():
        cells=line.split('\t')
        if cells[0]=='hit_probe_recovery':
            recovery_info=dict((k,int(v)) for k,v in (cell.split('=',1) for cell in cells[1:]))
    spec=importlib.util.spec_from_file_location('shadow_ledger',Path(__file__).with_name('shadow_ledger.py'))
    shadow=importlib.util.module_from_spec(spec);spec.loader.exec_module(shadow)
    update_entries={e['id']:e for e in events if e['phase']==16}
    updates=[{'context':e['update_context'],'before_sequence':update_entries[e['correlation']]['tick_sequence'],
        'after_sequence':e['tick_sequence'],'before_time':update_entries[e['correlation']]['server_time'],'after_time':e['server_time'],
        'before_hp':update_entries[e['correlation']]['hp'],'after_hp':e['hp']}
        for e in events if e['phase']==17 and e['correlation'] in update_entries]
    fatal_counters={};quiet_rebases=[]
    for line in log.splitlines():
        cells=line.split('\t')
        if cells[0]=='guard_quiet_rebase':
            fields={key:int(value) for key,value in (cell.split('=',1) for cell in cells[1:] if '=' in cell)
                    if value.isdecimal() or (value.startswith('-') and value[1:].isdecimal())}
            quiet_rebases.append(fields)
        if cells[0]=='fatal_summary':
            for cell in cells[1:]:
                key,_,value=cell.partition('=')
                if value.isdecimal():fatal_counters[key]=int(value)
    def signed64(value):return value-(1<<64) if value>=(1<<63) else value
    fatal=dict(quiet_rebases=quiet_rebases,decisions=[{'event_id':e['id'],'ns':e['ns'],'hp':e['hp'],'damage':e['value'],
            'retained_damage':e['projectile'],'projected_hp':signed64(e['update_context']),
            'reason':{1:'projected_lethal',2:'stale_updates',3:'ledger_capacity'}.get(e['flag3'],'legacy_or_unknown')} for e in events if e['phase']==20],
        request_results=[{'event_id':e['id'],'ns':e['ns'],'calculation_id':e['correlation'],'local_nexusing':bool(e['flag0']),
            'exception_or_handle_error':e['flag2']} for e in events if e['phase']==22],
        suppressed_reports=[{'event_id':e['id'],'ns':e['ns'],'bullet':e['bullet'],'owner':e['owner']} for e in events if e['phase']==23],
        suppressed_secondary_reports=[{'event_id':e['id'],'ns':e['ns'],'caller':hex(e['callsite'])} for e in events if e['phase']==30],
        server_hp_updates=[{'event_id':e['id'],'hp':e['hp'],'retained_damage':e['projectile'],
            'projected_hp':signed64(e['update_context']),'blocking':bool(e['flag1'])} for e in events if e['phase']==28],
        suppressed_notifications=sum(e['phase']==24 for e in events),
        observed_transitions=[{'event_id':e['id'],'ns':e['ns'],'reason':e['flag0'],'was_blocking':bool(e['value'])} for e in events if e['phase']==25],
        deaths_while_blocking=[e['id'] for e in events if e['phase']==26],counters=fatal_counters,
        limitation='A local Nexusing flag is not server acceptance. Suppression covers audited projectile, ground and radius/AOE paths. Other HP-loss mechanisms are unproven. The retained-damage model can escape early and does not establish true HP.')
    return {'schema':4,'incidents':incident_summary(events),'fatal_intervention':fatal,'shadow_ledger':({'trace':[],'limitation':'Live intervention changed damage handling; the legacy observation-only hypotheses are not replayed for this session.'} if fatal['decisions'] or any(e['phase']==27 for e in events) else shadow.replay(events,threshold)),'update_boundaries':updates,
        'hp_update_contexts':[{'event_id':e['id'],'hp':e['hp'],'context':e['update_context'],'source':e['update_source']} for e in events if e['phase']==6],'damage_calculations':len(damage),'pre_report_damage_pairs':damage_pairs,
        'unclassified_damage_calculations':[{'id':e['id'],'caller':hex(e['callsite']),'value':e['value']} for e in unclassified_damage],
        'damage_contexts':[{'id':e['id'],'ns':e['ns'],'generation':e['generation'],
            'conditions_raw':hex(e['projectile']) if e['flag0']&1 and e['flag2']==1 else None,
            'legacy_sprite_key_raw':hex(e['projectile']) if e['flag0']&1 and e['flag2']!=1 else None,
            'breath':e['value'] if e['flag0']&2 else None,'frostbite':e['owner'] if e['flag0']&4 else None,
            'local_nexusing':bool(e['flag1']) if e['flag0']&8 else None} for e in events if e['phase']==29],
        'notification_returns':sum(e['phase']==10 for e in events),'death_screen_entries':len(death),
        'nonpositive_hp_observations':[{'id':e['id'],'ns':e['ns'],'source_phase':e['value']} for e in zero],
        'reports_after_first_nonpositive_hp':sum(e['generation']==zero[0]['generation'] and e['ns']>zero[0]['ns'] for e in reports.values()) if zero else None,
        'reports_after_first_death_screen':sum(e['generation']==death[0]['generation'] and e['ns']>death[0]['ns'] for e in reports.values()) if death else None,
        'flight_recovery':recovery_info,'reports':len(reports),'notifications':len(notifications),'paired_notifications':len(paired),
        'unpaired_notifications':len(notifications)-len(paired),'pairs':paired,
        'report_callsites':sorted({hex(e['callsite']) for e in reports.values()}),
        'notification_callsites':sorted({hex(e['callsite']) for e in notifications}),
        'hp_assignments':assignments_after,'manual_nexus_entries':nexus,
        'notification_to_next_sampled_hp_decrease_ms_median':statistics.median(leads) if leads else None,
        'probe_snapshot_work_us_max':max((e['work_ns']/1000 for e in events if e['phase']<100),default=None),
        'completion_counters':counters,'environment_trace':environment,
        'limitation':'Pairing is a temporal association. HP assignments and map transitions are local observations, not verified server acknowledgements. Only audited projectile calculations enter shadow estimates; unknown callers are listed separately. Context values do not establish damage cause. Intervened sessions are not replayed as observation-only estimates.'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    parser.add_argument('--threshold',type=int,default=None,help='Override shadow threshold percentage; default follows recorded settings')
    args=parser.parse_args()
    print(json.dumps(analyze(args.log,args.threshold),indent=2))

if __name__=='__main__':main()
