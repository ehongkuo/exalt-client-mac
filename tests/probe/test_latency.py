import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
spec = importlib.util.spec_from_file_location('latency', ROOT / 'probe/analyze_latency.py')
latency = importlib.util.module_from_spec(spec); spec.loader.exec_module(latency)
from analyze import FIELDS


def event(identity, phase, ms, **values):
    row = dict.fromkeys(FIELDS, 0)
    row.update(id=identity, phase=phase, ns=int(ms*1e6), generation=1, hp=100, max=200, valid=1)
    row.update(values)
    return row


def shot(identity, ms, damage=30):
    return [event(identity, 12, ms, value=damage, flag0=1, flag1=1),
            event(identity+1, 1, ms+.01),
            event(identity+2, 3, ms+.02, value=damage, correlation=identity+1)]


def hp(identity, ms, before, after):
    return [event(identity, 5, ms, hp=before, callsite=0x184c115, update_source=1),
            event(identity+1, 6, ms+.01, hp=after, correlation=identity, update_source=1)]


def log(events, intervention=0, dropped=0, complete=1):
    lines = ['guard_config\tarmed=0\tpotion=0\tdeath=0',
             f'hit_probe_ready\tv8\tfatal_intervention={intervention}',
             f'damage_build\tsha256={latency.current_fingerprint()}',
             'timing\t1\t1792557699.311566\t208149424529000']
    lines += ['hit_probe_v4\t'+'\t'.join(str(row[k]) for k in FIELDS) for row in events]
    lines += [f'hit_probe_summary\tdropped={dropped}\toff_main_calls=0\tcomplete={complete}']
    return '\n'.join(lines)+'\n'


class LatencyTests(unittest.TestCase):
    def test_exact_isolated_endpoint_starts_at_calculation(self):
        result = latency.inspect_log(log(shot(1, 10)+hp(4, 210, 100, 70)))
        sample = result['samples'][0]
        self.assertEqual(sample['quality'], 'isolated_exact')
        self.assertAlmostEqual(sample['visibility_ms'], 200.01)
        self.assertFalse(sample['confirmed_acknowledgement'])
        self.assertFalse(sample['prior_unresolved_reports'])

    def test_healing_is_separate_evidence_class(self):
        result = latency.inspect_log(log(shot(1, 10)+hp(4, 210, 100, 71)))
        self.assertEqual(result['samples'][0]['quality'], 'isolated_healing_compatible')

    def test_visible_healing_prevents_exact_classification(self):
        result = latency.inspect_log(log(shot(1, 10)+hp(4, 100, 100, 110)+hp(6, 210, 110, 80)))
        self.assertEqual(result['samples'][0]['quality'], 'isolated_healing_compatible')

    def test_overlap_not_silently_counted_as_isolated(self):
        result = latency.inspect_log(log(shot(1, 10)+shot(4, 20)+hp(7, 210, 100, 70)+hp(9, 300, 70, 40)))
        self.assertEqual(len(result['unresolved']), 2)
        self.assertFalse(result['samples'])
        self.assertEqual(len(result['fifo_hypothesis']), 2)
        self.assertAlmostEqual(result['fifo_hypothesis'][1]['visibility_ms'], 280.01)

    def test_prior_unresolved_damage_quarantines_future_matches(self):
        rows = shot(1, 10)+shot(4, 20)+hp(7, 210, 100, 70)+shot(9, 300)+hp(12, 500, 70, 40)
        result = latency.inspect_log(log(rows))
        self.assertTrue(result['samples'][0]['prior_unresolved_reports'])

    def test_active_guard_or_synthetic_capture_is_excluded(self):
        text = log(shot(1, 10)+hp(4, 210, 100, 70), intervention=1)
        self.assertFalse(latency.inspect_log(text)['eligible'])
        text = log([])+'damage_verification\teffective_hp=1\n'
        self.assertFalse(latency.inspect_log(text)['eligible'])

    def test_missing_or_dropped_events_are_not_usable(self):
        self.assertFalse(latency.inspect_log(log([], dropped=1))['eligible'])
        self.assertFalse(latency.inspect_log('guard_loaded\n')['eligible'])
        self.assertFalse(latency.inspect_log(log([]).replace('dropped=0', 'dropped='))['eligible'])

    def test_manual_nexus_marks_pending_unresolved(self):
        result = latency.inspect_log(log(shot(1, 10)+[event(4, 7, 100)]))
        self.assertEqual(result['unresolved'][0]['reason'], 'nexus_or_death_transition')

    def test_unmatched_healed_hit_remains_in_coverage_count(self):
        result = latency.inspect_log(log(shot(1, 10)+hp(4, 210, 100, 100)))
        self.assertEqual(result['positive_reports'], 1)
        self.assertEqual(len(result['unresolved']), 1)

    def test_no_positive_server_damage_is_invented_as_a_local_hit(self):
        result = latency.inspect_log(log([event(1, 3, 10, value=30)]+hp(2, 210, 100, 70)))
        self.assertFalse(result['samples'])
        self.assertEqual(result['positive_reports'], 0)

    def test_duplicates_and_partial_archives_do_not_inflate_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            a = Path(folder)/'a'; b = Path(folder)/'b'; a.mkdir(); b.mkdir()
            text = log(shot(1, 10)+hp(4, 210, 100, 70))
            (a/'guard-1.tsv').write_text(text)
            (b/'guard-1.tsv').write_text(text+'trailing_summary\n')
            result = latency.scan([Path(folder)])
            self.assertEqual(result['isolated_exact']['count'], 1)
            self.assertEqual(len(result['duplicate_copies_excluded']), 1)
            self.assertFalse(result['reliable_p99_established'])
            self.assertFalse(result['automatic_threshold_change'])

    def test_build_mismatch_is_not_pooled(self):
        self.assertFalse(latency.inspect_log(log([]), expected_sha='different-build')['eligible'])

    def test_small_sample_p99_is_not_presented_as_established(self):
        summary = latency.percentiles([100,200,600])
        self.assertEqual(summary['observed_p99_ms'], 600)
        self.assertEqual(summary['count'], 3)
        self.assertEqual(latency.percentiles([]), {'count': 0})


if __name__ == '__main__':
    unittest.main()
