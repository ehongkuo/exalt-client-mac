import copy
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compat', ROOT / 'compatibility/manage.py')
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)

class ProfileTests(unittest.TestCase):
    def test_reviewed_profile_is_required_for_generation(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        text = compat.render_header(profile)
        self.assertIn('#define DAMAGE_CALLER 0x6538a2UL', text)
        self.assertIn('hp_prologue', text)
        historical = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-12.json')
        with self.assertRaises(ValueError): compat.render_header(historical)
        profile['review_state'] = 'candidate'
        with self.assertRaises(ValueError): compat.render_header(profile)

    def test_schema_rejects_duplicate_constants_and_bad_prefixes(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        bad = copy.deepcopy(profile)
        bad['methods'][1]['constant'] = bad['methods'][0]['constant']
        with self.assertRaises(ValueError): compat.validate_profile(bad)
        bad = copy.deepcopy(profile)
        next(m for m in bad['methods'] if m.get('hook'))['entry_prefix'] = '55'
        with self.assertRaises(ValueError): compat.validate_profile(bad)
        bad = copy.deepcopy(profile)
        bad['callsites'][0]['target'] = 'potion'
        with self.assertRaises(ValueError): compat.validate_profile(bad)

    def test_dump_preserves_overloads_defaults_and_generic_parameters(self):
        dump = '''// Namespace: Demo
public class Thing // TypeDefIndex: 1
{
 private int amount; // 0x60
 // RVA: 0x1000 Offset: 0x1000 VA: 0x1000 Slot: 3
 public bool Check(List<byte> items, bool enabled = False) { }
 // RVA: 0x1100 Offset: 0x1100 VA: 0x1100
 public bool Check(int amount) { }
}
'''
        parsed = compat.parse_dump(dump)
        self.assertEqual(len(parsed['methods']), 2)
        self.assertEqual(parsed['methods'][0]['parameters'], ['List<byte>', 'bool'])
        self.assertEqual(parsed['methods'][0]['slot'], 3)
        self.assertEqual(parsed['fields'][0]['offset'], 0x60)

    def test_macho_bounds_and_architecture_are_checked(self):
        with self.assertRaises(ValueError): compat.MachO(b'not a binary')
        binary = fixture_binary()
        self.assertEqual(binary.read(0x1000, 4), b'\x55\x48\x89\xe5')
        with self.assertRaises(ValueError): binary.read(0x10ff, 10)
        with self.assertRaises(ValueError): binary.read(-1, 4)
        with self.assertRaises(ValueError): compat.MachO(fixture_bytes(cpu=0x100000c))

    def test_comparison_reports_missing_ambiguous_moved_and_changed(self):
        expected = dict(namespace='Demo', owner='Thing', name='Check', parameters=['int'], returns='bool', offset='0x1000', entry_prefix='554889e5')
        method = dict(namespace='Demo', owner='Thing', name='Check', parameters=['int'], returns='bool', offset=0x1000, slot=None)
        self.assertEqual(compat.compare_method(expected, [method], fixture_binary())['status'], 'unchanged')
        self.assertEqual(compat.compare_method(expected, [], fixture_binary())['status'], 'missing')
        self.assertEqual(compat.compare_method(expected, [method, method], fixture_binary())['status'], 'ambiguous')
        moved = dict(method, offset=0x1010)
        self.assertEqual(compat.compare_method(expected, [moved], fixture_binary())['status'], 'moved')
        changed = dict(method, parameters=['float'])
        self.assertEqual(compat.compare_method(expected, [changed], fixture_binary())['status'], 'changed')
        expected['entry_prefix'] = '554889e5ff'
        self.assertEqual(compat.compare_method(expected, [method], fixture_binary())['status'], 'changed')

    def test_field_movement_type_change_and_ambiguity(self):
        old = dict(namespace='Demo', owner='Thing', name='amount', type='int', offset='0x60')
        field = dict(old, offset=0x60)
        self.assertEqual(compat.compare_field(old, [field])['status'], 'unchanged')
        self.assertEqual(compat.compare_field(old, [dict(field, offset=0x64)])['status'], 'moved')
        self.assertEqual(compat.compare_field(old, [dict(field, type='float')])['status'], 'changed')
        self.assertEqual(compat.compare_field(old, [dict(field, is_static=True)])['status'], 'changed')
        self.assertEqual(compat.compare_field(old, [])['status'], 'missing')
        self.assertEqual(compat.compare_field(old, [field, field])['status'], 'ambiguous')

    def test_ambiguous_calls_are_never_selected(self):
        instructions = [dict(address=0x1000, bytes='e80b000000', text='callq 0x1010'),
                        dict(address=0x1020, bytes='e8ebffffff', text='callq 0x1010')]
        self.assertEqual(compat.call_candidates(instructions, target=0x1010), [0x1005, 0x1025])
        self.assertEqual(compat.call_candidates(instructions, target=0x1040), [])

    def test_array_and_nested_generic_parameter_types_are_not_erased(self):
        dump = """// Namespace: Demo
public class Thing // TypeDefIndex: 1
{
 // RVA: 0x1000 Offset: 0x1000 VA: 0x1000
 public void Read(byte[] bytes, Dictionary<int, List<byte>> map) { }
}
"""
        parsed = compat.parse_dump(dump)
        self.assertEqual(parsed['methods'][0]['parameters'], ['byte[]', 'Dictionary<int, List<byte>>'])

    def test_incomplete_reviewed_profile_is_rejected(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        profile['methods'] = profile['methods'][1:]
        with self.assertRaises(ValueError): compat.validate_profile(profile)

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'profile.json'
            path.write_text('{"schema_version":1,"schema_version":2}')
            with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
                compat.load_profile(path)

    def test_stale_generated_header_and_hash_are_rejected(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        real_root = compat.ROOT
        with tempfile.TemporaryDirectory() as folder:
            compat.ROOT = Path(folder)
            try:
                (compat.ROOT / 'guard').mkdir()
                compat.generate(profile)
                compat.generate(profile, check=True)
                header = compat.ROOT / 'guard/build_profile.h'
                header.write_text(header.read_text().replace('0x6538a2', '0x6538a3'))
                with self.assertRaisesRegex(ValueError, 'Stale generated file'):
                    compat.generate(profile, check=True)
                compat.generate(profile)
                (compat.ROOT / 'guard/game-build.sha256').write_text('0' * 64)
                with self.assertRaisesRegex(ValueError, 'Stale generated file'):
                    compat.generate(profile, check=True)
            finally:
                compat.ROOT = real_root

    def test_malformed_binary_load_commands_are_rejected(self):
        data = bytearray(fixture_bytes())
        struct.pack_into('<I', data, 36, 0)
        with self.assertRaises(ValueError): compat.MachO(bytes(data))
        data = bytearray(fixture_bytes())
        struct.pack_into('<Q', data, 32 + 48, 0xfffffff)
        with self.assertRaises(ValueError): compat.MachO(bytes(data))

    def test_unknown_build_fails_verification(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        with self.assertRaisesRegex(ValueError, 'unsupported game build'):
            compat.verify_binary(profile, fixture_binary())

    def test_ambiguous_target_marks_its_callers_ambiguous(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        target = dict(profile['methods'][0])
        target['offset'] = 0x1000
        target['slot'] = None
        profile['callsites'][0]['target'] = target['id']
        report = compat.make_report(profile, fixture_binary(), {'methods': [target, target], 'fields': []}, lambda a,b: [])
        self.assertEqual(report['callsites'][0]['status'], 'ambiguous')

    def test_analyze_generates_dump_and_report_without_changing_profile(self):
        before = (ROOT / 'compatibility/profiles/2026-10-15.json').read_bytes()
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            binary, metadata, runner = base / 'GameAssembly.dylib', base / 'global-metadata.dat', base / 'dumper.sh'
            binary.write_bytes(fixture_bytes())
            metadata.write_bytes(b'test metadata')
            runner.write_text('mkdir -p "$3"\ncat > "$3/dump.cs" <<\'DUMP\'\n// Namespace: Demo\npublic class Thing // TypeDefIndex: 1\n{\n // RVA: 0x1000 Offset: 0x1000 VA: 0x1000\n public void Read() { }\n}\nDUMP\n')
            command = [sys.executable, str(ROOT / 'compatibility/manage.py'), 'analyze', '--binary', str(binary), '--metadata', str(metadata), '--dumper', str(runner), '--output', str(base / 'result')]
            run = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            report = json.loads((base / 'result/report.json').read_text())
            self.assertFalse(report['approved_for_runtime'])
            self.assertTrue(report['manual_review_required'])
            self.assertIn('metadata_sha256', report['inputs'])
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual((ROOT / 'compatibility/profiles/2026-10-15.json').read_bytes(), before)
            runner.write_text('printf changed > \"$2\"\n' + runner.read_text())
            command[-1] = str(base / 'changed-input')
            mutated = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(mutated.returncode, 0)
            self.assertIn('Metadata changed during analysis', mutated.stderr)
            self.assertFalse((base / 'changed-input/report.json').exists())

    def test_reports_never_approve_or_modify_a_profile(self):
        profile = compat.load_profile(ROOT / 'compatibility/profiles/2026-10-15.json')
        before = json.dumps(profile, sort_keys=True)
        report = compat.make_report(profile, fixture_binary(), {'methods': [], 'fields': []}, lambda a,b: [])
        self.assertTrue(report['manual_review_required'])
        self.assertFalse(report['approved_for_runtime'])
        self.assertEqual(json.dumps(profile, sort_keys=True), before)
        self.assertIn('does not establish behavioral compatibility', compat.render_report(report))

def fixture_bytes(cpu=0x1000007):
    header = struct.pack('<IIIIIIII', 0xfeedfacf, cpu, 3, 6, 1, 72, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__TEXT', 0x1000, 0x100, 0x100, 0x100, 7, 5, 0, 0)
    data = bytearray(header + segment)
    data.extend(b'\0' * (0x200 - len(data)))
    data[0x100:0x104] = bytes.fromhex('554889e5')
    data[0x110:0x114] = bytes.fromhex('554889e5')
    return bytes(data)

def fixture_binary():
    return compat.MachO(fixture_bytes())

if __name__ == '__main__': unittest.main()
