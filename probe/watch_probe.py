#!/usr/bin/env python3
"""Display diagnostic status and numeric hit observations from the local log."""
from pathlib import Path
import sys
import os
import time
from analyze import read_events
from shadow_ledger import ShadowLedger


def main():
    folder=Path(sys.argv[1])
    started=time.time()
    selected=None
    offset=0
    pending=''
    ledger=ShadowLedger(25)
    fatal_live=False
    print('Waiting for the diagnostic game. Enter Nexus before testing damage.',flush=True)
    try:
        while True:
            files=[p for p in folder.glob('guard-*.tsv') if p.stat().st_mtime>=started-3]
            latest=max(files,key=lambda p:p.stat().st_mtime,default=None)
            if latest and latest!=selected:
                selected=latest;offset=0;pending=''
                print(f'Session: {selected.name}',flush=True)
            if selected:
                with selected.open() as f:
                    f.seek(offset);pending+=f.read();offset=f.tell()
                lines=pending.split('\n');pending=lines.pop()
                for line in lines:
                    row=line.split('\t')
                    if row[0]=='hit_probe_ready':
                        fatal_live='fatal_intervention=1' in row
                        print('Probe installed. Fatal Nexus intervention is ON.' if 'fatal_intervention=1' in row else 'Probe installed. Observation only; gameplay automation is off.',flush=True)
                    elif row[0]=='hit_probe_refused':
                        print('Probe refused to install: '+' '.join(row[1:]),flush=True)
                    elif row[0]=='damage_context_ready':
                        print('Optional context fields (1 available, 0 unavailable): '+' '.join(row[1:]),flush=True)
                    elif row[0]=='guard_config':
                        for cell in row[1:]:
                            if cell.startswith('nexus='):ledger.threshold=int(cell[6:])
                    elif row[0] in ('hit_probe_v2','hit_probe_v3','hit_probe_v4') and len(row) in (21,25):
                        phase=int(row[4])
                        if phase==29:
                            mask=int(row[16])
                            breath=row[10] if mask&2 else 'unavailable'
                            frostbite=row[9] if mask&4 else 'unavailable'
                            flags=hex(int(row[15])) if mask&1 and row[18]=='1' else 'unavailable (legacy sprite key)' if mask&1 else 'unavailable'
                            print(f'Context | breath {breath} | frostbite {frostbite} | raw flags {flags}',flush=True)
                        elif phase==4:
                            print(f'HP sample {row[11]}/{row[12]} | cause not inferred',flush=True)
                        if phase==20:
                            pending_hp=int(row[21]);projected=pending_hp-(1<<64) if pending_hp>=(1<<63) else pending_hp
                            print(f'FATAL PREDICTION | observed HP {row[11]} | damage {row[10]} | retained damage {row[15]} | projected {projected}',flush=True)
                        elif phase==22:
                            print('Nexus requested locally. Audited damage suppression is ON; awaiting map transition.' if row[16]=='1' else 'Nexus request FAILED locally. Damage remains enabled. Stop this test and report the result.',flush=True)
                        elif phase==23:print(f'Withheld projectile report | bullet {row[8]} | owner {row[9]}',flush=True)
                        elif phase==30:print(f'Withheld ground/area report | caller {hex(int(row[6]))}',flush=True)
                        elif phase==25:print('Nexus map observed; fatal budget reset.' if row[16]=='1' else 'Player/map changed; fatal budget reset.',flush=True)
                        elif phase==26:print('Server/client HP reached zero while escape was pending. Intervention did not protect this case.',flush=True)
                        elif phase==28:
                            print(f'Server HP baseline {row[11]} | uncertain damage retained | escape latch {row[17]}',flush=True)
                        elif phase==27:
                            raw=int(row[21]);projected=raw-(1<<64) if raw>=(1<<63) else raw
                            print(f'Fatal budget | observed HP {row[11]} | retained damage {row[15]} | projected {projected}',flush=True)
                        event=read_events(line)[0];estimate=ledger.feed(event)
                        if not fatal_live and estimate and (phase in (6,12,17) or estimate['held_crossed'] or estimate['debit_crossed']):
                            print(f"Shadow hypotheses | held {estimate['held_estimate']} | net-debit {estimate['debit_estimate']} | pending {estimate['debit_pending']} | {estimate['status']} (no confirmed acknowledgement)",flush=True)
                            if estimate['debit_crossed'] or estimate['held_crossed']:print('Shadow percentage threshold crossed in a diagnostic hypothesis.',flush=True)
                        if phase==17:print(f'Update returned | sequence field {event["tick_sequence"]} | time field {event["server_time"]}',flush=True)
                        if phase==1:
                            print(f'Incoming report | bullet {row[8]} | owner {row[9]} | HP {row[11]}',flush=True)
                        elif phase==3:
                            print(f'Player notification value {row[10]} | HP {row[11]} | paired report {row[7]}',flush=True)
                        elif phase==6:
                            print(f'HP assignment | requested {row[10]} | observed {row[11]}',flush=True)
                        elif phase==7:
                            print('Automatic Nexus function entered.' if row[16]=='1' else 'Manual Nexus function entered.',flush=True)
                        elif phase==12:
                            kind='Audited projectile calculation' if row[17]=='0' or row[16]=='1' else 'Unmapped calculator caller (player ownership unknown)'
                            print(f'{kind} {row[10]} | HP {row[11]} | caller {hex(int(row[6]))}',flush=True)
                        elif phase==10:
                            print(f'Notification returned | HP {row[11]}',flush=True)
                        elif phase==13:
                            print('Death screen function entered.',flush=True)
                        elif phase==15:
                            print('Observed HP transition to zero or below.',flush=True)
                        elif phase==9:
                            print(f'Map/character changed | in Nexus: {row[13]}',flush=True)
                    elif row[:2]==['status','complete']:
                        print('Diagnostic complete. Return to the chat for analysis.',flush=True)
                        return
            if selected:
                try:os.kill(int(selected.stem[6:]),0)
                except ProcessLookupError:
                    print('Game closed. Return to the chat for analysis.',flush=True);return
                except PermissionError:pass
            time.sleep(0.1)
    except KeyboardInterrupt:
        print('\nMonitor closed. The game can be quit normally.')


if __name__=='__main__':main()
