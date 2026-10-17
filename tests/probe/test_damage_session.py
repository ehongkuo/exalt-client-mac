import importlib.util
from pathlib import Path
import unittest
import tempfile
import struct
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('damage_session', ROOT / 'probe/damage_session.py')
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


def event(identity, phase=4, hp=1000, generation=1, **values):
    row = dict.fromkeys(session.FIELDS, 0)
    row.update(id=identity, ns=identity * 1000000, epoch=identity / 1000,
               phase=phase, generation=generation, hp=hp, max=1000, valid=1)
    row.update(values)
    return row


class DamageSessionTests(unittest.TestCase):
    def write_log(self, folder, rows, complete=True):
        path = Path(folder) / 'guard-99999999.tsv'
        fingerprint = __import__('json').loads((ROOT / 'probe/damage_paths.json').read_text())['game_sha256']
        lines = ['hit_probe_ready\tv7\tfatal_intervention=0', 'damage_build\tsha256=' + fingerprint]
        lines += ['hit_probe_v4\t' + '\t'.join(str(e[key]) for key in session.FIELDS) for e in rows]
        if complete: lines += ['status\tcomplete']
        path.write_text('\n'.join(lines) + '\n')
        return path

    def test_bundle_preserves_raw_evidence_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_log(folder, [event(1), event(2, hp=900)])
            destination = Path(folder) / 'bundle'
            result = session.bundle(path, destination, 'D01')
            self.assertEqual(result['outcome'], 'observed')
            self.assertEqual(path.read_bytes(), (destination / path.name).read_bytes())
            self.assertTrue((destination / 'manifest.json').is_file())
            with self.assertRaises(FileExistsError): session.bundle(path, destination, 'D01')

    def test_bundle_refuses_a_running_session_and_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_log(folder, [event(1)])
            with patch.object(session.os, 'kill', return_value=None):
                with self.assertRaises(ValueError): session.bundle(path, Path(folder) / 'bundle', 'D01')
            link = Path(folder) / 'link.tsv'
            link.symlink_to(path)
            with self.assertRaises(ValueError): session.bundle(link, Path(folder) / 'bundle', 'D01')

    def environment_log(self, folder, rows, skipped):
        path = self.write_log(folder, rows)
        path.write_text(path.read_text() + 'environment_trace_ready\tversion=1\n'
            + f'environment_trace_summary\tevents=10\tstacks=3\tskipped={skipped}\n')
        return path

    def test_capture_limits_make_observation_inconclusive(self):
        for skipped, expected in ((0, 'observed'), (1, 'inconclusive')):
            with self.subTest(skipped=skipped), tempfile.TemporaryDirectory() as folder:
                path = self.environment_log(folder, [event(1), event(2, hp=900)], skipped)
                result = session.inspect(path)
                self.assertEqual(result['outcome'], expected)
                self.assertEqual(len(result['hp_decreases']), 1)
                if skipped: self.assertTrue(any('capture limit' in reason for reason in result['reasons']))

    def test_capture_limits_make_escape_inconclusive_without_hiding_arrival(self):
        rows = [event(1), event(2, 22, flag0=1), event(3, 9, generation=2, in_nexus=1)]
        for skipped, expected in ((0, 'escaped'), (1, 'inconclusive')):
            with self.subTest(skipped=skipped), tempfile.TemporaryDirectory() as folder:
                result = session.inspect(self.environment_log(folder, rows, skipped))
                self.assertEqual(result['outcome'], expected)
                self.assertTrue(result['automatic_escape_observed'])
                self.assertTrue(result['nexus_arrival_observed'])

    def test_capture_limits_preserve_confirmed_death(self):
        for skipped in (0, 1):
            with self.subTest(skipped=skipped), tempfile.TemporaryDirectory() as folder:
                result = session.inspect(self.environment_log(folder, [event(1), event(2, 13, hp=0)], skipped))
                self.assertEqual(result['outcome'], 'failed')
                self.assertEqual(result['death_events'], [2])

    def test_missing_build_identity_prevents_native_path_claim(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_log(folder, [event(1)])
            path.write_text('\n'.join(line for line in path.read_text().splitlines() if not line.startswith('damage_build')))
            self.assertEqual(session.inspect(path)['outcome'], 'inconclusive')

    def test_malformed_events_cannot_silently_pass_a_completed_session(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_log(folder, [event(1)])
            path.write_text(path.read_text() + 'hit_probe_v4\tbroken\n')
            self.assertEqual(session.inspect(path)['outcome'], 'inconclusive')

    def test_death_in_binary_tail_overrides_text_only_result(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.write_log(folder, [event(1)])
            data = bytearray(64 + 8192 * 112)
            struct.pack_into('<8sIIQQdQQQ', data, 0, b'EXHPRB3\0', 3, 104, 8192, 100, 1000.0, 1, 0, 0)
            struct.pack_into('<Q', data, 64, 2)
            struct.pack_into('<7Q11iI', data, 72, 1, 101, 1, 0, 0, 0, 0,
                             13, 0, 0, 1000, 1000, 0, 1, 0, 0, 0, 0, 0)
            path.with_name('hit-flight-99999999.bin').write_bytes(data)
            result = session.bundle(path, Path(folder) / 'bundle', 'D01')
            self.assertEqual(result['outcome'], 'failed')
            self.assertTrue(result['flight_tail_only'])

    def test_hp_assignment_and_duplicate_snapshots_count_once(self):
        rows = [event(1), event(2, 5), event(3, 6, hp=900, correlation=2, update_source=1), event(4, hp=900)]
        result = session.summarize(rows, ready=True, complete=True)
        self.assertEqual(len(result['hp_decreases']), 1)
        self.assertEqual(result['hp_decreases'][0]['path'], 'incoming_hp_assignment')
        self.assertEqual(result['hp_decreases'][0]['amount'], 100)
        self.assertEqual(result['outcome'], 'observed')

    def test_meter_context_is_raw_evidence_not_a_damage_cause(self):
        rows = [event(1), event(2, 29, value=0, owner=100, projectile=1 << 45, flag0=7, flag2=1), event(3, hp=800)]
        drop = session.summarize(rows, ready=True)['hp_decreases'][0]
        self.assertEqual(drop['path'], 'sampled_unattributed')
        self.assertEqual(drop['context']['breath'], 0)
        self.assertEqual(drop['context']['conditions_raw'], hex(1 << 45))
        self.assertIsNone(drop['cause'])

    def test_legacy_sprite_key_is_never_presented_as_condition_flags(self):
        rows = [event(1, 29, projectile=0x8500200080849772, flag0=1), event(2), event(3, hp=800)]
        context = session.summarize(rows)['hp_decreases'][0]['context']
        self.assertIsNone(context['conditions_raw'])
        self.assertEqual(context['legacy_sprite_key_raw'], '0x8500200080849772')

    def test_context_does_not_cross_generation_or_stale_window(self):
        rows = [event(1, 29, value=0, flag0=2), event(2, generation=2), event(3, hp=800, generation=2)]
        self.assertIsNone(session.summarize(rows)['hp_decreases'][0]['context'])
        rows = [event(1, 29, value=0, flag0=2), event(2), event(3, hp=800, ns=1000000000)]
        self.assertIsNone(session.summarize(rows)['hp_decreases'][0]['context'])

    def test_healing_and_new_map_do_not_become_damage(self):
        rows = [event(1, hp=800), event(2, hp=900), event(3, hp=200, generation=2)]
        self.assertEqual(session.summarize(rows)['hp_decreases'], [])

    def test_invalid_samples_break_the_hp_baseline(self):
        rows = [event(1), event(2, hp=1200, valid=0), event(3, hp=900)]
        self.assertEqual(session.summarize(rows)['hp_decreases'], [])

    def test_escape_needs_observed_nexus_arrival_after_local_request(self):
        rows = [event(1), event(2, 20), event(3, 22, flag0=1)]
        self.assertEqual(session.summarize(rows, ready=True, complete=True)['outcome'], 'inconclusive')
        rows.append(event(4, 9, generation=2, in_nexus=1))
        self.assertEqual(session.summarize(rows, ready=True, complete=True)['outcome'], 'escaped')
        self.assertFalse(session.summarize(rows)['lethal_prevention_proven'])

    def test_death_overrides_escape_and_incomplete_evidence(self):
        rows = [event(1, 22, flag0=1), event(2, 9, generation=2, in_nexus=1), event(3, 13, generation=2)]
        self.assertEqual(session.summarize(rows)['outcome'], 'failed')

    def test_loss_missing_readiness_and_incomplete_session_are_inconclusive(self):
        for kwargs in ({}, {'ready': True}, {'ready': True, 'complete': True, 'lost': 1}):
            self.assertEqual(session.summarize([event(1)], **kwargs)['outcome'], 'inconclusive')

    def test_missing_optional_fields_are_not_zero_readings(self):
        rows = [event(1), event(2, 29, value=-1, owner=-1, flag0=0), event(3, hp=900)]
        context = session.summarize(rows)['hp_decreases'][0]['context']
        self.assertIsNone(context['breath'])
        self.assertIsNone(context['frostbite'])
        self.assertIsNone(context['conditions_raw'])

    def test_notification_path_uses_exact_correlation_not_timing(self):
        rows = [event(1, 3, callsite=0x196ed65, value=50), event(2, 10, hp=950, correlation=1)]
        drop = session.summarize(rows)['hp_decreases'][0]
        self.assertEqual(drop['path'], 'notification_return')
        self.assertEqual(drop['notification_caller'], '0x196ed65')
        self.assertEqual(drop['native_path'], 'terrain')


if __name__ == '__main__':
    unittest.main()
