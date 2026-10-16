"""Generate reviewed build constants and report compatibility evidence without approving updates."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ACTIVE = ROOT / 'compatibility/active-profile.txt'
METHOD_CONSTANTS = {
    'potion': 'POTION_OFFSET', 'nexus': 'NEXUS_OFFSET', 'join': 'JOIN_OFFSET',
    'join_cooldown': 'JOIN_COOLDOWN_OFFSET', 'report': 'HIT_REPORT_OFFSET',
    'notify': 'HIT_NOTIFY_OFFSET', 'hp': 'HP_ASSIGN_OFFSET', 'damage': 'DAMAGE_OFFSET',
    'death': 'DEATH_SCREEN_OFFSET', 'update': 'UPDATE_OFFSET', 'stats': 'STATS_OFFSET',
    'collision': None, 'zero_hp_context': None,
}
HOOKS = {'nexus', 'report', 'notify', 'hp', 'damage', 'death', 'update', 'stats'}
CALL_LAYOUT = {
    'DAMAGE_CALLER': ('collision', 'damage', 'direct'),
    'NOTIFY_CALLER': ('collision', 'notify', 'virtual'),
    'ZERO_HP_CALLER': ('zero_hp_context', 'hp', 'direct'),
}


def address(value):
    if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-f]+', value):
        raise ValueError(f'Invalid address: {value!r}')
    result = int(value, 16)
    if result > 0xffffffffffffffff: raise ValueError('Address exceeds 64 bits')
    return result


def validate_profile(profile):
    if profile.get('schema_version') != 1 or profile.get('architecture') != 'x86_64':
        raise ValueError('Unsupported profile schema or architecture')
    if profile.get('review_state') not in ('native-audited', 'candidate', 'historical-reference'):
        raise ValueError('Missing review state')
    if not re.fullmatch(r'[a-f0-9]{64}', profile.get('game_sha256', '')):
        raise ValueError('Invalid GameAssembly SHA-256')
    if {m['id'] for m in profile['methods']} != set(METHOD_CONSTANTS):
        raise ValueError('Profile must contain every supported method and caller context')
    if {m.get('hook') for m in profile['methods'] if m.get('hook')} != HOOKS:
        raise ValueError('Profile must contain all audited hooks')
    if {c['constant'] for c in profile['callsites']} != set(CALL_LAYOUT):
        raise ValueError('Profile must contain all audited callers')
    constants, ids, hooks = set(), set(), set()
    for method in profile['methods']:
        if method['id'] in ids:
            raise ValueError('Duplicate method identity')
        ids.add(method['id'])
        address(method['offset'])
        for name in ('namespace', 'owner', 'name', 'returns'):
            if not isinstance(method[name], str):
                raise ValueError('Invalid method identity')
        if not isinstance(method['parameters'], list) or not all(isinstance(p, str) for p in method['parameters']):
            raise ValueError('Invalid method parameters')
        if not re.fullmatch(r'(?:[a-f0-9]{2})+', method['entry_prefix']):
            raise ValueError('Invalid entry prefix encoding')
        prefix = bytes.fromhex(method['entry_prefix'])
        if not prefix or (method.get('hook') and not 14 <= len(prefix) <= 32):
            raise ValueError('Invalid audited entry prefix')
        if method.get('hook') != (method['id'] if method['id'] in HOOKS else None):
            raise ValueError('Hook does not match its integration role')
        if method.get('hook') in hooks: raise ValueError('Duplicate hook identifier')
        if method.get('hook'): hooks.add(method['hook'])
        constant = method.get('constant')
        if constant != METHOD_CONSTANTS[method['id']]:
            raise ValueError('Method constant does not match its integration role')
        if constant:
            if not re.fullmatch(r'[A-Z][A-Z0-9_]+', constant) or constant in constants:
                raise ValueError('Invalid or duplicate method constant')
            constants.add(constant)
        if method.get('hook') and not re.fullmatch(r'[a-z]+', method['hook']):
            raise ValueError('Invalid hook identifier')
    for call in profile['callsites']:
        if call['container'] not in ids or call['target'] not in ids:
            raise ValueError('Unknown callsite method')
        constant = call['constant']
        if (call['container'], call['target'], call['kind']) != CALL_LAYOUT.get(constant):
            raise ValueError('Callsite does not match its integration role')
        if not re.fullmatch(r'[A-Z][A-Z0-9_]+', constant) or constant in constants:
            raise ValueError('Invalid or duplicate callsite constant')
        constants.add(constant)
        address(call['return_address'])
        if call['kind'] not in ('direct', 'virtual'):
            raise ValueError('Unknown call kind')
        if call['kind'] == 'virtual':
            address(call['vtable_base'])
            address(call['slot_offset'])
    for field in profile['fields']:
        address(field['offset'])
    return profile


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def load_profile(path=None):
    if path is None:
        selected = ACTIVE.read_text().strip()
        if Path(selected).name != selected or not selected.endswith('.json'):
            raise ValueError('Invalid active profile filename')
        path = ACTIVE.parent / 'profiles' / selected
    return validate_profile(json.loads(Path(path).read_text(), object_pairs_hook=unique_keys))


def render_header(profile):
    validate_profile(profile)
    if profile['review_state'] != 'native-audited':
        raise ValueError('Candidate profiles cannot generate runtime constants')
    lines = ['/* Generated from the reviewed compatibility profile. Run compatibility/manage.py generate. */',
             '#ifndef EXALT_BUILD_PROFILE_H', '#define EXALT_BUILD_PROFILE_H',
             '#define EXALT_GAME_SHA256 ' + json.dumps(profile['game_sha256'])]
    for method in profile['methods']:
        if method.get('constant'):
            lines.append(f"#define {method['constant']} {method['offset']}UL")
            lines.append(f"#define {method['constant']}_NAME {json.dumps(method['name'])}")
            lines.append(f"#define {method['constant']}_OWNER {json.dumps(method['owner'])}")
            lines.append(f"#define {method['constant']}_NAMESPACE {json.dumps(method['namespace'])}")
    for call in profile['callsites']:
        lines.append(f"#define {call['constant']} {call['return_address']}UL")
    lines.append('#ifdef EXALT_PROFILE_HOOK_BYTES')
    for method in profile['methods']:
        if not method.get('hook'):
            continue
        hook = method['hook']
        if hook in ('hp', 'death'):
            lines.extend(['#ifdef HIT_PROBE_TEST', f'#define {hook}_prologue notify_prologue', '#else'])
        values = ','.join(f'0x{b:02x}' for b in bytes.fromhex(method['entry_prefix']))
        lines.append(f'static const unsigned char {hook}_prologue[]={{' + values + '};')
        if hook in ('hp', 'death'):
            lines.append('#endif')
    lines.extend(['#endif', '#endif', ''])
    return '\n'.join(lines)


def split_types(text):
    parts, start, depth = [], 0, 0
    for i, char in enumerate(text):
        if char in '<[(': depth += 1
        elif char in '>])': depth -= 1
        elif char == ',' and depth == 0:
            parts.append(text[start:i].strip()); start = i + 1
    if text[start:].strip(): parts.append(text[start:].strip())
    return parts


def parse_dump(text):
    namespace, owner, rva, slot = '', '', None, None
    methods, fields = [], []
    modifiers = r'^(?:(?:public|private|protected|internal|static|virtual|override|sealed|abstract|extern|readonly|unsafe|new|async)\s+)+'
    for line in text.splitlines():
        if line.startswith('// Namespace:'):
            namespace = line.split(':', 1)[1].strip()
        if '// TypeDefIndex:' in line:
            match = re.search(r'\b(?:class|struct|interface|enum)\s+(.+?)\s*// TypeDefIndex:', line)
            owner = match[1].split(' : ', 1)[0].strip() if match else ''
            rva = None
        match = re.search(r'// RVA: (0x[0-9a-fA-F]+)', line)
        if match:
            rva = int(match[1], 16)
            found = re.search(r'\bSlot: (\d+)', line)
            slot = int(found[1]) if found else None
            continue
        stripped = line.strip()
        if rva is not None and stripped and not stripped.startswith(('//', '[')):
            match = re.search(r'(.+?)\s+([^\s(]+)\((.*)\)', re.sub(modifiers, '', stripped))
            if match:
                parameters = []
                for part in split_types(match[3]):
                    part = re.sub(r'^\[[^\]]+\]\s*', '', part).split(' = ', 1)[0]
                    parameters.append(part.rsplit(' ', 1)[0])
                methods.append(dict(namespace=namespace, owner=owner, name=match[2], parameters=parameters,
                                    returns=match[1].strip(), offset=rva, slot=slot))
            rva = None
        match = re.match(r'(.+?)\s+(\S+);\s*// (0x[0-9a-fA-F]+)', re.sub(modifiers, '', stripped))
        if match:
            fields.append(dict(namespace=namespace, owner=owner, name=match[2], type=match[1], offset=int(match[3], 16), is_static=bool(re.search(r'\bstatic\b', stripped))))
    return dict(methods=methods, fields=fields)


class MachO:
    def __init__(self, data):
        if len(data) < 32:
            raise ValueError('Truncated Mach-O header')
        magic, cpu, _, _, commands, command_size = struct.unpack_from('<6I', data)
        if magic != 0xfeedfacf or cpu != 0x1000007:
            raise ValueError('Expected an Intel 64-bit little-endian Mach-O')
        if commands > 4096 or command_size > len(data) - 32:
            raise ValueError('Invalid Mach-O load commands')
        self.data, self.segments = data, []
        pos, end = 32, 32 + command_size
        for _ in range(commands):
            if pos + 8 > end: raise ValueError('Truncated load command')
            command, size = struct.unpack_from('<II', data, pos)
            if size < 8 or pos + size > end: raise ValueError('Invalid load command size')
            if command == 0x19:
                if size < 72: raise ValueError('Truncated segment')
                vm, _, offset, length = struct.unpack_from('<QQQQ', data, pos + 24)
                if offset + length > len(data): raise ValueError('Segment exceeds file')
                self.segments.append((vm, length, offset))
            pos += size
        self.sha256 = hashlib.sha256(data).hexdigest()

    def read(self, address, size):
        if size < 0 or address < 0: raise ValueError('Invalid read range')
        matches = [s for s in self.segments if s[0] <= address and address + size <= s[0] + s[1]]
        if len(matches) != 1: raise ValueError(f'Unmapped or ambiguous address {address:#x}')
        vm, _, offset = matches[0]
        return self.data[offset + address - vm:offset + address - vm + size]


def method_key(method):
    return (method['namespace'], method['owner'], method['name'], tuple(method['parameters']), method['returns'])


def compare_method(expected, methods, binary):
    matches = [m for m in methods if method_key(m) == method_key(expected)]
    result = dict(id=expected.get('id', expected['name']), old_address=expected['offset'], status='missing')
    if len(matches) > 1:
        return dict(result, status='ambiguous', candidates=[hex(m['offset']) for m in matches])
    if not matches:
        related = [m for m in methods if (m['namespace'], m['owner'], m['name']) ==
                   (expected['namespace'], expected['owner'], expected['name'])]
        if related: result.update(status='changed', reason='Method signature changed')
        return result
    match = matches[0]
    try:
        prefix = binary.read(match['offset'], len(bytes.fromhex(expected['entry_prefix']))).hex()
    except ValueError as error:
        return dict(result, status='changed', reason=str(error))
    status = 'changed' if prefix != expected['entry_prefix'] else 'unchanged' if match['offset'] == address(expected['offset']) else 'moved'
    return dict(result, status=status, new_address=hex(match['offset']), observed_prefix=prefix, slot=match['slot'])


def compare_field(expected, fields):
    matches = [f for f in fields if (f['namespace'], f['owner'], f['name']) ==
               (expected['namespace'], expected['owner'], expected['name'])]
    result = dict(id=expected.get('id', expected['owner'] + '.' + expected['name']), status='missing', old_offset=expected['offset'])
    if len(matches) > 1: return dict(result, status='ambiguous')
    if not matches: return result
    field = matches[0]
    status = 'changed' if field['type'] != expected['type'] or field.get('is_static', False) != expected.get('is_static', False) else 'unchanged' if field['offset'] == address(expected['offset']) else 'moved'
    return dict(result, status=status, new_offset=hex(field['offset']), observed_type=field['type'], observed_static=field.get('is_static', False))


def call_candidates(instructions, target=None, slot=None):
    candidates = []
    for instruction in instructions:
        raw = bytes.fromhex(instruction['bytes'])
        if target is not None and len(raw) == 5 and raw[0] == 0xe8:
            returned = instruction['address'] + 5
            if returned + struct.unpack('<i', raw[1:])[0] == target: candidates.append(returned)
        elif slot is not None and len(raw) == 6 and raw[:2] == b'\xff\x90' and struct.unpack('<I', raw[2:])[0] == slot:
            candidates.append(instruction['address'] + 6)
    return candidates


def disassemble(binary_path, start, end):
    result = subprocess.run(['xcrun', 'llvm-objdump', '--disassemble', f'--start-address={start}',
                             f'--stop-address={end}', str(binary_path)], capture_output=True, text=True, check=True)
    instructions = []
    for line in result.stdout.splitlines():
        match = re.match(r'\s*([a-fA-F0-9]+):\s+((?:[a-fA-F0-9]{2}\s+)+)\s*(.*)', line)
        if match: instructions.append(dict(address=int(match[1], 16), bytes=''.join(match[2].split()), text=match[3]))
    return instructions


def make_report(profile, binary, dump, disassembler):
    methods = [compare_method(m, dump['methods'], binary) for m in profile['methods']]
    fields = [compare_field(f, dump['fields']) for f in profile['fields']]
    known = {m['id']: m for m in profile['methods']}
    matches, ambiguous = {}, set()
    for identity, expected in known.items():
        found = [m for m in dump['methods'] if method_key(m) == method_key(expected)]
        if len(found) == 1: matches[identity] = found[0]
        elif len(found) > 1: ambiguous.add(identity)
    offsets = sorted(set(m['offset'] for m in dump['methods']))
    calls = []
    for call in profile['callsites']:
        row = dict(id=call['id'], old_address=call['return_address'], status='missing', candidates=[])
        if call['container'] in ambiguous or call['target'] in ambiguous:
            calls.append(dict(row, status='ambiguous', reason='Container or target identity is ambiguous'))
            continue
        container, target = matches.get(call['container']), matches.get(call['target'])
        if container and target:
            start = container['offset']
            end = next((n for n in offsets if n > start), start)
            if 0 < end - start <= 1_000_000:
                instructions = disassembler(start, end)
                if call['kind'] == 'virtual':
                    slot = target.get('slot')
                    candidates = [] if slot is None else call_candidates(instructions, slot=address(call['vtable_base']) + slot * 16)
                else: candidates = call_candidates(instructions, target=target['offset'])
                row['candidates'] = [hex(n) for n in candidates]
                if len(candidates) == 1:
                    row.update(status='unchanged' if candidates[0] == address(call['return_address']) else 'moved', new_address=hex(candidates[0]))
                elif len(candidates) > 1: row['status'] = 'ambiguous'
        calls.append(row)
    return dict(schema_version=1, baseline_profile=profile['id'], game_sha256=binary.sha256,
                known_build=binary.sha256 == profile['game_sha256'], manual_review_required=True,
                approved_for_runtime=False, methods=methods, fields=fields, callsites=calls)


def render_report(report):
    lines = ['# Compatibility comparison', '', f"Baseline: `{report['baseline_profile']}`",
             f"Observed GameAssembly: `{report['game_sha256']}`", '',
             '**Read-only findings. This report does not establish behavioral compatibility or approve a build for runtime use.**', '',
             'Unchanged means the listed identity and entry/offset checks matched. It does not mean the whole method is unchanged.',
             'New-build candidates require a native-code audit and live readiness checks. No profile or installed app was modified.', '']
    for title, key in [('Methods', 'methods'), ('Fields', 'fields'), ('Call sites', 'callsites')]:
        lines += ['## ' + title, '', '| Item | Finding | Previous | Observed |', '|---|---|---|---|']
        for row in report[key]:
            old = row.get('old_address', row.get('old_offset', ''))
            new = row.get('new_address', row.get('new_offset', ', '.join(row.get('candidates', []))))
            # Metadata strings are data; do not render arbitrary Markdown from a dump.
            label = str(row['id']).replace('|', '\\|').replace('\n', ' ').replace('`', '')
            lines.append(f"| {label} | {row['status']} | `{old}` | `{new}` |")
        lines.append('')
    lines += ['🤖 Generated with Codex', '']
    return '\n'.join(lines)


def verify_binary(profile, binary):
    validate_profile(profile)
    if profile['review_state'] != 'native-audited' or binary.sha256 != profile['game_sha256']:
        raise ValueError('Unreviewed or unsupported game build')
    for method in profile['methods']:
        prefix = bytes.fromhex(method['entry_prefix'])
        if binary.read(address(method['offset']), len(prefix)) != prefix:
            raise ValueError('Entry prefix mismatch: ' + method['id'])
    methods = {m['id']: address(m['offset']) for m in profile['methods']}
    for call in profile['callsites']:
        returned = address(call['return_address'])
        if call['kind'] == 'direct':
            raw = binary.read(returned - 5, 5)
            if raw[0] != 0xe8 or returned + struct.unpack('<i', raw[1:])[0] != methods[call['target']]:
                raise ValueError('Direct call mismatch: ' + call['id'])
        else:
            expected = b'\xff\x90' + struct.pack('<I', address(call['slot_offset']))
            if binary.read(returned - 6, 6) != expected: raise ValueError('Virtual call mismatch: ' + call['id'])


def generate(profile, check=False):
    outputs = {ROOT / 'guard/build_profile.h': render_header(profile),
               ROOT / 'guard/game-build.sha256': profile['game_sha256'] + '\n'}
    for path, text in outputs.items():
        if check:
            if not path.exists() or path.read_text() != text: raise ValueError('Stale generated file: ' + str(path))
        else: path.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    gen = commands.add_parser('generate'); gen.add_argument('--check', action='store_true')
    verify = commands.add_parser('verify'); verify.add_argument('--binary', required=True, type=Path)
    compare = commands.add_parser('compare')
    compare.add_argument('--binary', required=True, type=Path)
    compare.add_argument('--dump', required=True, type=Path)
    compare.add_argument('--output', required=True, type=Path, help='New directory for report.json and report.md')
    analyze = commands.add_parser('analyze', help='Run an existing local dumper, then compare its output')
    analyze.add_argument('--binary', required=True, type=Path)
    analyze.add_argument('--metadata', required=True, type=Path)
    analyze.add_argument('--dumper', required=True, type=Path, help='Path to the trusted local run-mac.sh wrapper')
    analyze.add_argument('--output', required=True, type=Path, help='New directory for dump and reports')
    args = parser.parse_args()
    try:
        profile = load_profile(args.profile)
        if args.command == 'generate':
            generate(profile, args.check)
            print('Reviewed profile outputs ' + ('verified' if args.check else 'generated'))
        elif args.command == 'verify':
            generate(profile, check=True)
            verify_binary(profile, MachO(args.binary.read_bytes()))
            print('Reviewed profile and installed binary verified')
        else:
            binary = MachO(args.binary.read_bytes())
            inputs = {}
            if args.command == 'analyze':
                inputs['metadata_sha256'] = hashlib.sha256(args.metadata.read_bytes()).hexdigest()
                inputs['dumper_wrapper_sha256'] = hashlib.sha256(args.dumper.read_bytes()).hexdigest()
                args.output.mkdir(parents=True, exist_ok=False)
                dump_path = args.output / 'dump/dump.cs'
                subprocess.run(['/bin/sh', str(args.dumper.resolve()), str(args.binary.resolve()),
                                str(args.metadata.resolve()), str(dump_path.parent.resolve())], check=True)
            else:
                dump_path = args.dump
            dump_bytes = dump_path.read_bytes()
            inputs['dump_sha256'] = hashlib.sha256(dump_bytes).hexdigest()
            dump = parse_dump(dump_bytes.decode('utf-8'))
            if not dump['methods']: raise ValueError('No methods found in metadata dump')
            report = make_report(profile, binary, dump, lambda a,b: disassemble(args.binary, a, b))
            if hashlib.sha256(args.binary.read_bytes()).hexdigest() != binary.sha256:
                raise ValueError('GameAssembly changed during analysis; no report was written')
            if args.command == 'analyze' and hashlib.sha256(args.metadata.read_bytes()).hexdigest() != inputs['metadata_sha256']:
                raise ValueError('Metadata changed during analysis; no report was written')
            report['inputs'] = inputs
            if args.command == 'compare': args.output.mkdir(parents=True, exist_ok=False)
            (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            (args.output / 'report.md').write_text(render_report(report))
            print('Read-only report: ' + str(args.output / 'report.md'))
            print('Manual review required. Runtime approval was not changed.')
    except (ValueError, KeyError, OSError, struct.error, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Compatibility check failed: {error}\n')


if __name__ == '__main__':
    main()
