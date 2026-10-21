import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'probe'))
from analyze import FIELDS
from analyze_sync import summarize

def row(phase,**values):
    e=dict.fromkeys(FIELDS,0);e.update(phase=phase,generation=1,update_context=5);e.update(values)
    return 'hit_probe_v4\t'+'\t'.join(str(e[f]) for f in FIELDS)+'\n'

class SyncAnalysisTests(unittest.TestCase):
    def test_tick_response_and_hp_context_are_observed_without_hit_ack(self):
        log='sync_trace_ready\tversion=1\n'+row(40,id=1,ns=100,tick_sequence=7,server_time=800,correlation=99)
        log+=row(41,id=2,ns=120,tick_sequence=7,server_time=800)
        log+=row(6,id=3,ns=110,hp=225,update_source=1,**{'update_context':99})
        result=summarize(log)
        self.assertEqual(result['ticks'][0]['client_responses'],[2])
        self.assertEqual(result['ticks'][0]['hp_assignments'],[225])
        self.assertFalse(result['ticks'][0]['proves_hit_acknowledgement'])
        self.assertEqual(result['snapshot_hit_coverage'],'unverified')

    def test_scope_target_and_order_are_required_for_same_key_candidate(self):
        log=row(42,id=1,ns=100,owner=90,bullet=3)
        log+=row(43,id=2,ns=90,owner=90,bullet=3,projectile=5,value=20)
        log+=row(43,id=3,ns=120,owner=90,bullet=3,projectile=6,value=20)
        log+=row(43,id=4,ns=130,owner=90,bullet=3,projectile=5,value=20)
        log+=row(43,id=5,ns=140,owner=90,bullet=3,projectile=5,value=20,**{'generation':2})
        result=summarize(log)['received_damage']
        self.assertEqual([x['earlier_same_key_reports'] for x in result],[[],[],[1],[]])
        self.assertFalse(any(x['proves_snapshot_coverage'] for x in result))

    def test_reused_keys_remain_ambiguous(self):
        log=row(42,id=1,ns=100,owner=90,bullet=3)+row(42,id=2,ns=110,owner=90,bullet=3)
        log+=row(43,id=3,ns=120,owner=90,bullet=3,projectile=5)
        result=summarize(log)['received_damage'][0]
        self.assertEqual(result['earlier_same_key_reports'],[1,2]);self.assertTrue(result['ambiguous'])

    def test_cap_and_drop_information_are_preserved(self):
        result=summarize('sync_trace_limit\tevents=12000\nhit_probe_summary\tdropped=3\toff_main_calls=2\tcomplete=0\n')
        self.assertTrue(result['limit_reached']);self.assertEqual(result['counters']['dropped'],3)
        self.assertFalse(result['trace_ready'])

if __name__=='__main__':unittest.main()
