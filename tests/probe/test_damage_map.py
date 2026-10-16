import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('damage_map', ROOT / 'probe/map_damage.py')
mapping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapping)


class Binary:
    def __init__(self, data):
        self.sha256 = data['game_sha256']
        self.memory = {}
        for group, address, raw in [('methods', 'offset', 'entry_prefix'), ('evidence', 'address', 'bytes'), ('notification_callers', 'return_address', 'call_bytes')]:
            for row in data[group]:
                value = bytes.fromhex(row[raw])
                start = int(row[address], 16) - (len(value) if group == 'notification_callers' else 0)
                self.memory[start, len(value)] = value

    def read(self, address, length):
        return self.memory.get((address, length), b'')


class MapTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / 'probe/damage_paths.json').read_text())
        self.binary = Binary(self.data)
        self.dump = dict(methods=[dict(m, offset=int(m['offset'], 16)) for m in self.data['methods']],
                         fields=[dict(f, offset=int(f['offset'], 16)) for f in self.data['fields']])

    def test_matching_evidence_does_not_approve_intervention(self):
        result = mapping.verify(self.data, self.binary, self.dump)
        self.assertTrue(result['metadata_verified'])
        self.assertFalse(result['live_verified'])
        self.assertFalse(result['approved_for_intervention'])

    def test_unknown_build_is_rejected(self):
        self.binary.sha256 = '0' * 64
        with self.assertRaises(ValueError): mapping.verify(self.data, self.binary)

    def test_changed_native_evidence_is_rejected(self):
        self.binary.memory.clear()
        with self.assertRaises(ValueError): mapping.verify(self.data, self.binary)

    def test_ambiguous_method_or_changed_field_is_rejected(self):
        self.dump['methods'].append(copy.deepcopy(self.dump['methods'][0]))
        with self.assertRaises(ValueError): mapping.verify(self.data, self.binary, self.dump)
        self.dump['methods'].pop()
        self.dump['fields'][0]['type'] = 'int'
        with self.assertRaises(ValueError): mapping.verify(self.data, self.binary, self.dump)


if __name__ == '__main__':
    unittest.main()
