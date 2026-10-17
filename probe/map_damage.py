#!/usr/bin/env python3
"""Verify the static damage map against its exact game binary and optional metadata dump."""
import argparse
import importlib.util
import json
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('compatibility', ROOT / 'compatibility/manage.py')
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


def verify(mapping, binary, dump=None):
    if mapping['schema'] != 1 or mapping['game_sha256'] != binary.sha256:
        raise ValueError('Damage map does not match this game build')
    for row in mapping['methods']:
        expected = bytes.fromhex(row['entry_prefix'])
        if binary.read(int(row['offset'], 16), len(expected)) != expected:
            raise ValueError('Method entry changed: ' + row['path'])
        if dump is not None:
            matches = [m for m in dump['methods'] if compatibility.method_key(m) == compatibility.method_key(row)]
            if len(matches) != 1 or matches[0]['offset'] != int(row['offset'], 16):
                raise ValueError('Method identity missing, changed or ambiguous: ' + row['path'])
    for row in mapping['notification_callers']:
        expected = bytes.fromhex(row['call_bytes'])
        if expected not in (bytes.fromhex('ff9098080000'), bytes.fromhex('ff9398080000')):
            raise ValueError('Unexpected notification dispatch encoding')
        if binary.read(int(row['return_address'], 16) - len(expected), len(expected)) != expected:
            raise ValueError('Notification caller changed: ' + row['path'])
    for row in mapping['evidence']:
        expected = bytes.fromhex(row['bytes'])
        if binary.read(int(row['address'], 16), len(expected)) != expected:
            raise ValueError('Native evidence changed: ' + row['finding'])
    routing=mapping.get('stat_dispatch')
    if routing:
        base=int(routing['table'],16)
        for case in routing['cases']:
            index=(case['stat']-routing['rotation']) & 255
            target=base+struct.unpack('<i',binary.read(base+4*index,4))[0]
            if target!=int(case['handler'],16):
                raise ValueError('Stat dispatch changed: '+case['role'])
    if dump is not None:
        for row in mapping['fields']:
            matches = [f for f in dump['fields'] if (f['namespace'], f['owner'], f['name']) ==
                       (row['namespace'], row['owner'], row['name'])]
            if len(matches) != 1 or any(matches[0][key] != row[key] for key in ('type', 'is_static')) or matches[0]['offset'] != int(row['offset'], 16):
                raise ValueError('Field identity changed: ' + row['role'])
    return dict(schema=1, game_sha256=binary.sha256, native_evidence_verified=True,
        metadata_verified=dump is not None, live_verified=False, approved_for_intervention=False,
        methods=len(mapping['methods']), fields=len(mapping['fields']),
        limitation=mapping['limitation'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path.home() / '.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib')
    parser.add_argument('--dump', type=Path)
    parser.add_argument('--output', type=Path, help='New JSON report file; refuses overwrite')
    args = parser.parse_args()
    try:
        mapping = json.loads((HERE / 'damage_paths.json').read_text())
        binary = compatibility.MachO(args.binary.read_bytes())
        dump = compatibility.parse_dump(args.dump.read_text()) if args.dump else None
        result = verify(mapping, binary, dump)
        if args.output:
            with args.output.open('x') as output: json.dump(result, output, indent=2); output.write('\n')
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
