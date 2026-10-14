#!/usr/bin/env python3
"""Recover completed recent hit events after quitting the diagnostic game."""
import argparse
from pathlib import Path
import struct

HEADER=struct.Struct('<8sIIQQdQQQ')
EVENT=struct.Struct('<7Q11iI')
SLOT_SIZE=112
EVENT4=struct.Struct('<7Q11iIQiIi4x')

def recover(path):
    data=Path(path).read_bytes()
    if len(data)<HEADER.size:raise ValueError('Truncated flight header')
    magic,version,event_size,capacity,start,epoch,count,dropped,off_main=HEADER.unpack_from(data)
    if (magic,version,event_size)==(b'EXHPRB3\0',3,EVENT.size):decoder=EVENT;slot_size=112
    elif (magic,version,event_size)==(b'EXHPRB4\0',4,EVENT4.size):decoder=EVENT4;slot_size=136
    else:raise ValueError('Unsupported flight recorder format')
    if capacity!=8192:raise ValueError('Unsupported flight capacity')
    if len(data)!=HEADER.size+capacity*slot_size:raise ValueError('Truncated flight recorder')
    records=[];incomplete=0
    for i in range(capacity):
        offset=HEADER.size+i*slot_size
        seq=struct.unpack_from('<Q',data,offset)[0]
        if not seq:continue
        if seq&1:incomplete+=1;continue
        ordinal=seq//2
        if ordinal>count or ordinal<=max(0,count-capacity):continue
        values=decoder.unpack_from(data,offset+8)
        identity,ns,generation,caller,correlation,projectile,work=values[:7]
        phase,owner,value,hp,maximum,nexus,valid,f0,f1,f2,f3,bullet=values[7:19]
        row=[identity,ns,epoch+(ns-start)/1e9,phase,generation,caller,correlation,bullet,owner,value,hp,maximum,nexus,valid,projectile,f0,f1,f2,f3,work]
        if version==4:row.extend(values[19:23])
        records.append((ordinal,f'hit_probe_v{version}\t'+'\t'.join(map(str,row))))
    records.sort()
    lines=[row for _,row in records]
    lines.append(f'hit_probe_recovery\tretained={len(records)}\toverwritten={max(0,count-capacity)}\tincomplete_slots={incomplete}\tpublished={count}')
    lines.append(f'hit_probe_summary\tdropped={dropped}\toff_main_calls={off_main}\tcomplete=0')
    return '\n'.join(lines)+'\n'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('flight',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args();log=recover(args.flight)
    if args.output:args.output.write_text(log)
    else:print(log,end='')

if __name__=='__main__':main()
