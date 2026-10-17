#!/usr/bin/env python3
"""Resolve captured native return addresses against this build's IL2CPP script.json."""
import argparse
import bisect
import json
from pathlib import Path
from analyze import analyze

def report(log, script):
    result=analyze(log)['environment_trace']
    methods={}
    for method in json.loads(Path(script).read_text())['ScriptMethod']:
        methods.setdefault(method['Address'],set()).add(method['Name'])
    addresses=sorted(methods)
    for frame in result['frames']:
        address=int(frame['return_address'],16)-1
        index=bisect.bisect_right(addresses,address)-1
        if index>=0:
            start=addresses[index]
            frame['nearest_preceding_symbols']=sorted(methods[start])
            frame['offset_from_symbol']=hex(address-start)
    result['symbol_warning']='Nearest preceding metadata symbol only; validate instruction boundaries and method extent in disassembly before attributing a producer.'
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    parser.add_argument('--script',required=True,type=Path)
    args=parser.parse_args()
    print(json.dumps(report(args.log,args.script),indent=2))
