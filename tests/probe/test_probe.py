import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('guard_tests',ROOT/'tests/test_guard.py')
guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
spec=importlib.util.spec_from_file_location('analysis',ROOT/'probe/analyze.py')
analysis=importlib.util.module_from_spec(spec);spec.loader.exec_module(analysis)
class ProbeTests(unittest.TestCase):
 def fixture(self,bad_bytes=False,lethal=False,crash=False,bad_argument=False,fatal=False,denied=False,exception=False,reconcile=False,unaudited=False,context_missing=False,verify_hp=False):
  with tempfile.TemporaryDirectory(prefix='exalt-hit-probe-') as folder:
   p=Path(folder)
   subprocess.run(['clang',*(['-DHIT_PROBE_BAD_ARGUMENT_TEST'] if bad_argument else []),*(['-DHIT_PROBE_UNAUDITED_TEST'] if unaudited else []),*(['-DHIT_PROBE_NO_CONTEXT_TEST'] if context_missing else []),'-arch','x86_64','-O2','-Wall','-Wextra','-Werror','-dynamiclib','-DEXALT_HIT_PROBE','-DHIT_PROBE_TEST','-DSESSION_NS=3500000000ULL',f'-DPROBE_LOG_DIR="{p}"',str(ROOT/'guard/guard.c'),'-o',str(p/'probe.dylib')],check=True)
   args=['clang','-arch','x86_64','-O2','-Wall','-Wextra','-Werror','-Wl,-export_dynamic',str(ROOT/'tests/probe/integration_fixture.c'),str(ROOT/'tests/probe/hook_fixture.S'),'-o',str(p/'RotMGExalt')]
   if fatal:args.append('-DFATAL_BURST')
   if verify_hp:args.append('-DVERIFY_EARLY')
   if reconcile:args.append('-DFATAL_RECONCILE')
   if denied:args.append('-DNEXUS_REQUEST_DENIED')
   if exception:args.append('-DNEXUS_REQUEST_EXCEPTION')
   if bad_argument:args.append('-DBAD_DAMAGE_ARGUMENT')
   if lethal:args.append('-DLETHAL_BURST')
   if crash:args.append('-DABRUPT_EXIT')
   if bad_bytes:args.append('-DBAD_REPORT_BYTES')
   subprocess.run(args,check=True)
   env=os.environ.copy();env['DYLD_INSERT_LIBRARIES']=str(p/'probe.dylib');env['EXALT_GUARD']='armed=1,potion=50,nexus=25'
   env['EXALT_VERIFY_ONE_HP']='1' if verify_hp else '0'
   env['EXALT_FATAL_INTERVENTION']='1' if fatal or unaudited else '0'
   game=subprocess.Popen([str(p/'RotMGExalt')],env=env,stdout=subprocess.PIPE,text=True)
   time.sleep(1.15)
   if not crash:
    guard.live_control(p/'guard-live.bin',1,1,50,80,25)
    guard.live_join(p/'guard-live.bin',1,'Caller')
   out,_=game.communicate(timeout=10)
   self.assertEqual(game.returncode,23 if crash else 0)
   if not crash and not fatal:self.assertIn('probe_report_forwarded=7 probe_notify_forwarded=6' if lethal else 'probe_report_forwarded=4 probe_notify_forwarded=3',out)
   if not crash:
    self.assertIn('potion_calls=0',out);self.assertIn(f'nexus_calls={int(fatal and not exception)}',out);self.assertIn('join_calls=0',out)
   logfile=next(p.glob('guard-*.tsv'))
   self.flight_summary=analysis.analyze(next(p.glob('hit-flight-*.bin')))
   self.last_output=out
   self.last_log=logfile.read_text()
   self.summary=analysis.analyze(logfile)
   return logfile.read_text()
 def test_one_hp_verification_escapes_before_first_small_hit_without_changing_hp(self):
  log=self.fixture(fatal=True,verify_hp=True)
  self.assertIn('damage_verification\teffective_hp=1\tgame_hp_unchanged=1',log)
  request=next(e for e in analysis.read_events(log) if e['phase']==20)
  self.assertEqual(request['hp'],200)
  self.assertEqual(request['value'],50)
  self.assertEqual(request['update_context'],(1<<64)-49)
  self.assertIn('fatal_report_forwarded=0 fatal_notify_forwarded=0',self.last_output)
 def test_context_round_trips_and_unmapped_calculations_never_intervene(self):
  log=self.fixture(unaudited=True);events=analysis.read_events(log)
  contexts=[e for e in events if e['phase']==29]
  self.assertTrue(contexts)
  self.assertTrue(all(e['projectile']==1<<45 and e['value']==0 and e['owner']==100 and e['flag0']==15 for e in contexts))
  self.assertFalse(any(e['phase'] in (20,23,24) for e in events))
  self.assertEqual(self.summary['damage_calculations'],0)
  self.assertEqual(len(self.summary['unclassified_damage_calculations']),3)
  self.assertEqual(self.flight_summary['damage_calculations'],0)
  self.assertEqual(len(self.flight_summary['unclassified_damage_calculations']),3)
  self.assertTrue(all(e['conditions_raw']==hex(1<<45) and e['breath']==0 and e['frostbite']==100 for e in self.flight_summary['damage_contexts']))
  self.assertEqual(self.summary['shadow_ledger']['trace'][-1]['held_damage'],0)
  self.assertEqual([e['id'] for e in events],sorted(e['id'] for e in events))
  self.assertTrue(any(e['phase']==9 and e['in_nexus'] for e in events))
 def test_missing_context_fields_preserve_original_game_calls(self):
  log=self.fixture(context_missing=True);events=analysis.read_events(log)
  contexts=[e for e in events if e['phase']==29]
  self.assertTrue(contexts)
  self.assertTrue(all(e['flag0']==8 and e['value']==-1 and e['owner']==-1 for e in contexts))
  self.assertIn('damage_context_ready\tconditions=0\tbreath=0\tfrostbite=0',log)
 def test_incoming_identifiers_are_not_damage(self):
  log=self.fixture();self.assertIn('hit_probe_ready\tv7',log)
  events=analysis.read_events(log)
  reports=[e for e in events if e['phase']==1]
  notifications=[e for e in events if e['phase']==3]
  self.assertEqual(len(reports),3)
  self.assertTrue(all(e['value']==0 for e in reports))
  self.assertEqual([e['value'] for e in notifications],[400]*3)
  self.assertEqual([e['correlation'] for e in notifications],[e['id'] for e in reports])
  self.assertTrue(all(e['bullet']==4000000000 for e in reports))
  self.assertTrue(all(e['owner']==7 for e in reports))
  self.assertEqual(self.summary['completion_counters']['off_main_calls'],1)
  self.assertEqual(self.summary['completion_counters']['dropped'],0)
  self.assertEqual(self.summary['reports'],3)
  self.assertEqual(self.summary['paired_notifications'],3)
  self.assertNotIn('provisional_crossings',self.summary)
  self.assertTrue(any(e['phase']==5 for e in events))
  self.assertTrue(any(e['phase']==6 for e in events))
  self.assertTrue(any(e['phase']==7 for e in events))
  self.assertTrue(any(e['phase']==8 for e in events))
  self.assertEqual([e['hp'] for e in notifications],[1000,1005,1005])
  self.assertEqual(len({e['generation'] for e in notifications}),1)
  self.assertEqual([e['after'] for e in self.summary['hp_assignments']],[1005,805])
 def test_notification_return_is_observed(self):
  log=self.fixture();events=analysis.read_events(log)
  before=[e for e in events if e['phase']==3]
  after=[e for e in events if e['phase']==10]
  self.assertEqual(len(after),len(before))
  self.assertEqual([e['correlation'] for e in after],[e['id'] for e in before])
 def test_lethal_burst_captures_zero_and_later_reports(self):
  self.fixture(lethal=True)
  result=self.summary
  self.assertEqual(result['damage_calculations'],6)
  self.assertEqual(len(result['pre_report_damage_pairs']),6)
  self.assertTrue(all(pair['values_match'] for pair in result['pre_report_damage_pairs']))
  self.assertTrue(all(pair['before_report_us']>=0 for pair in result['pre_report_damage_pairs']))
  self.assertEqual(result['death_screen_entries'],1)
  self.assertEqual(len(result['nonpositive_hp_observations']),1)
  self.assertEqual(result['nonpositive_hp_observations'][0]['source_phase'],10)
  self.assertEqual(result['reports_after_first_nonpositive_hp'],2)
  self.assertEqual(result['reports_after_first_death_screen'],2)
  self.assertEqual(self.flight_summary['reports'],6)
 def test_abrupt_exit_preserves_burst_without_log_drain(self):
  self.fixture(lethal=True,crash=True)
  self.assertEqual(self.flight_summary['reports'],6)
  self.assertEqual(self.flight_summary['notifications'],6)
  self.assertEqual(self.flight_summary['death_screen_entries'],1)
  self.assertEqual(self.flight_summary['completion_counters'].get('complete',0),0)
  self.assertGreater(self.flight_summary['reports'],self.summary['reports'])
 def test_invalid_native_argument_is_forwarded_without_inspection(self):
  self.fixture(lethal=True,bad_argument=True)
  self.assertEqual(self.summary['damage_calculations'],6)
  events=analysis.read_events(self.last_log)
  self.assertTrue(all(e['projectile']==0 and e['bullet']==0 and e['owner']==0 for e in events if e['phase'] in (11,12)))
  self.assertTrue(all(pair['values_match'] for pair in self.summary['pre_report_damage_pairs']))
 def test_update_boundaries_forward_opaque_payloads_and_tag_hp(self):
  log=self.fixture();events=analysis.read_events(log)
  before=[e for e in events if e['phase']==16];after=[e for e in events if e['phase']==17]
  self.assertEqual(len(before),1);self.assertEqual(len(after),1)
  self.assertEqual([before[0]['tick_sequence'],after[0]['tick_sequence']],[41,42])
  self.assertEqual([before[0]['server_time'],after[0]['server_time']],[1000,1200])
  nested=[e for e in events if e['phase']==6 and e['value']==1005]
  self.assertEqual(nested[0]['update_context'],before[0]['id']);self.assertEqual(nested[0]['update_source'],1)
  standalone=[e for e in events if e['phase']==6 and e['value']==805]
  self.assertEqual(standalone[0]['update_source'],2)
  self.assertEqual(len([e for e in events if e['phase']==18]),2)
 def test_fatal_request_precedes_suppression_and_preserves_other_events(self):
  log=self.fixture(fatal=True,bad_argument=True)
  self.assertIn('fatal_report_forwarded=3 fatal_notify_forwarded=3 fatal_damage_calls=6',self.last_output)
  events=analysis.read_events(log)
  phases=[e['phase'] for e in events]
  self.assertEqual(phases.count(20),1);self.assertEqual(phases.count(21),1)
  self.assertEqual(phases.count(23),3);self.assertEqual(phases.count(24),3)
  self.assertLess(phases.index(20),phases.index(21));self.assertLess(phases.index(21),phases.index(7))
  self.assertLess(phases.index(8),phases.index(22));self.assertLess(phases.index(22),phases.index(23))
  completed=next(e for e in events if e['phase']==22)
  self.assertEqual(completed['flag0'],1)
  self.assertEqual(completed['projectile'],200)
  self.assertEqual(completed['update_context'],0)
  self.assertEqual(self.summary['reports'],3)
  self.assertEqual(self.summary['death_screen_entries'],0)
  self.assertIn('off_main_reports_suppressed=1',log)
  self.assertIn('off_main_notifications_suppressed=1',log)
  self.assertTrue(any(e['phase']==6 for e in events))
  self.assertTrue(any(e['phase']==25 and e['flag0']==1 and e['value']==1 for e in events))
  self.assertEqual(self.summary['manual_nexus_entries'],[])
  self.assertEqual(len(self.summary['fatal_intervention']['decisions']),1)
  self.assertEqual(len(self.summary['fatal_intervention']['suppressed_reports']),3)
 def test_server_hp_replaces_budget_without_clearing_escape_latch(self):
  log=self.fixture(fatal=True,reconcile=True)
  self.assertIn('fatal_report_forwarded=4 fatal_notify_forwarded=4 fatal_damage_calls=7',self.last_output)
  events=analysis.read_events(log)
  resets=[e for e in events if e['phase']==28]
  self.assertEqual(len(resets),2)
  self.assertEqual([e['projectile'] for e in resets],[0,0])
  self.assertEqual([e['update_context'] for e in resets],[200,200])
  self.assertEqual([e['flag1'] for e in resets],[0,1])
  decision=next(e for e in events if e['phase']==20)
  self.assertEqual(decision['projectile'],200)
  self.assertEqual(len([e for e in events if e['phase']==23]),3)
 def test_rejected_nexus_does_not_suppress_or_repeat(self):
  log=self.fixture(fatal=True,denied=True)
  self.assertIn('fatal_report_forwarded=7 fatal_notify_forwarded=7',self.last_output)
  events=analysis.read_events(log)
  self.assertEqual(len([e for e in events if e['phase']==20]),1)
  self.assertFalse(any(e['phase'] in (23,24) for e in events))
  self.assertEqual(next(e for e in events if e['phase']==22)['flag0'],0)
 def test_nexus_exception_keeps_original_calls(self):
  log=self.fixture(fatal=True,exception=True)
  events=analysis.read_events(log)
  self.assertFalse(any(e['phase'] in (23,24) for e in events))
  result=next(e for e in events if e['phase']==22)
  self.assertEqual(result['flag2'],1)
 def test_mismatched_prologue_forwards_without_installing(self):
  log=self.fixture(True);self.assertIn('hit_probe_refused\tentry_bytes',log)
  self.assertNotIn('hit_probe_ready',log);self.assertNotIn('hit_probe\t',log)
class AnalysisTests(unittest.TestCase):
 def analyze_rows(self,rows):
  with tempfile.TemporaryDirectory() as folder:
   p=Path(folder)/'events.tsv';p.write_text('\n'.join(rows));return analysis.analyze(p)
 def event(self,identity,phase,ns,generation=1,correlation=0,hp=1000,value=0):
  e=dict.fromkeys(analysis.FIELDS,0)
  e.update(id=identity,phase=phase,ns=ns,generation=generation,correlation=correlation,hp=hp,max=1000,valid=1,value=value)
  return 'hit_probe_v2\t'+'\t'.join(str(e[key]) for key in analysis.FIELDS)
 def test_pairing_requires_order_and_same_map_generation(self):
  result=self.analyze_rows([self.event(1,1,10),self.event(2,2,20,correlation=1),
   self.event(3,3,30,generation=2,correlation=1,value=45),self.event(4,3,15,correlation=1,value=45)])
  self.assertEqual(result['paired_notifications'],0)
  self.assertEqual(result['unpaired_notifications'],2)
 def test_heal_is_not_reported_as_damage_latency(self):
  result=self.analyze_rows([self.event(1,3,1000000,hp=900,value=45),
   self.event(2,4,2000000,hp=905),self.event(3,4,6000000,hp=860)])
  self.assertEqual(result['notification_to_next_sampled_hp_decrease_ms_median'],5)
  self.assertEqual(result['completion_counters'],{})
 def test_manual_nexus_does_not_claim_server_acceptance(self):
  result=self.analyze_rows([self.event(1,7,100),self.event(2,1,150),self.event(3,9,200,generation=2),self.event(4,1,250,generation=2)])
  self.assertEqual(result['manual_nexus_entries'][0]['reports_before_next_identity_or_map_transition'],[2])
  self.assertEqual(result['manual_nexus_entries'][0]['next_transition_in_nexus'],0)
 def test_multiple_calculations_before_report_are_not_paired(self):
  result=self.analyze_rows([self.event(1,12,10,value=50),self.event(2,12,11,value=50),
   self.event(3,1,12),self.event(4,2,13,correlation=3),self.event(5,3,14,correlation=3,value=50)])
  self.assertEqual(result['pre_report_damage_pairs'],[])
 def test_calculation_pairing_is_temporal_only(self):
  result=self.analyze_rows([self.event(1,12,10,value=50),self.event(2,1,12),
   self.event(3,2,13,correlation=2),self.event(4,3,14,correlation=2,value=50)])
  self.assertEqual(len(result['pre_report_damage_pairs']),1)
  self.assertEqual(result['pre_report_damage_pairs'][0]['association'],'temporal_only')
class FlightRecoveryTests(unittest.TestCase):
 def setUp(self):
  spec=importlib.util.spec_from_file_location('recovery',ROOT/'probe/recover_flight.py')
  self.recovery=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.recovery)
 def recover_buffer(self,data):
  with tempfile.TemporaryDirectory() as folder:
   p=Path(folder)/'flight.bin';p.write_bytes(data);return self.recovery.recover(p)
 def header(self,count):
  import struct
  data=bytearray(64+8192*112)
  self.recovery.HEADER.pack_into(data,0,b'EXHPRB3\0',3,104,8192,100,1000.0,count,0,0)
  return data
 def slot(self,data,ordinal,seq=None):
  import struct
  offset=64+((ordinal-1)%8192)*112
  struct.pack_into('<Q',data,offset,ordinal*2 if seq is None else seq)
  self.recovery.EVENT.pack_into(data,offset+8,ordinal,100+ordinal,1,0,0,0,0,1,7,0,200,200,0,1,0,0,0,0,ordinal)
 def test_incomplete_slot_is_skipped(self):
  data=self.header(2);self.slot(data,1);self.slot(data,2,3)
  log=self.recover_buffer(data)
  self.assertEqual(len(analysis.read_events(log)),1)
  self.assertIn('incomplete_slots=1',log)
 def test_wrap_retains_latest_events_in_publication_order(self):
  data=self.header(8195)
  for ordinal in range(4,8196):self.slot(data,ordinal)
  log=self.recover_buffer(data);events=analysis.read_events(log)
  self.assertEqual([events[0]['id'],events[-1]['id']],[4,8195])
  self.assertEqual(len(events),8192);self.assertIn('overwritten=3',log)
 def test_truncated_file_is_refused(self):
  with self.assertRaises(ValueError):self.recover_buffer(self.header(0)[:-1])
if __name__=='__main__':unittest.main()
