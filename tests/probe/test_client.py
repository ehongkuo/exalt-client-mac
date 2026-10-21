"""Exercise the app's guard build, including Arm/Dry Run, toggle settings and legacy Nexus migration."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'probe'))
import analyze

class ClientInterventionTests(unittest.TestCase):
 def run_client(self,settings,denied=False,exception=False,reconcile=False,toggle=False,boundary=None,mixed=False,hp_cross=False,environment=None,no_context=False,false_positive=False):
  with tempfile.TemporaryDirectory(prefix='exalt-client-fatal-') as folder:
   p=Path(folder)
   subprocess.run(['clang',*(['-DHIT_PROBE_NO_CONTEXT_TEST'] if no_context else []),*(['-DHIT_PROBE_MIXED_TEST'] if mixed else []),*([f'-DHIT_PROBE_BOUNDARY_TEST={boundary}'] if boundary else []),'-arch','x86_64','-O2','-Wall','-Wextra','-Werror','-dynamiclib',
    '-DEXALT_CLIENT_FATAL','-DHIT_PROBE_TEST','-DHIT_PROBE_BAD_ARGUMENT_TEST','-DSESSION_NS=3500000000ULL',
    f'-DPROBE_LOG_DIR="{p}"',str(ROOT/'guard/guard.c'),'-o',str(p/'guard.dylib')],check=True)
   args=['clang','-arch','x86_64','-O2','-Wall','-Wextra','-Werror','-Wl,-export_dynamic',
    '-DFATAL_BURST','-DBAD_DAMAGE_ARGUMENT',str(ROOT/'tests/probe/integration_fixture.c'),
    str(ROOT/'tests/probe/hook_fixture.S'),'-o',str(p/'RotMGExalt')]
   if false_positive:args.append('-DFATAL_FALSE_POSITIVE')
   if environment:args.append(f'-DFATAL_ENVIRONMENT={environment}')
   if environment in (10,11) and ('armed=0' in settings or 'death=0' in settings):args.append('-DLOCAL_HP_PASS')
   if hp_cross:args.append('-DFATAL_HP_CROSS')
   if mixed:args.append('-DFATAL_MIXED_BURST')
   if boundary:
    args.append('-DFATAL_BOUNDARY_BURST')
    if 'armed=0' in settings or 'death=0' in settings:args.append('-DBOUNDARY_PASS')
   if denied:args.append('-DNEXUS_REQUEST_DENIED')
   if exception:args.append('-DNEXUS_REQUEST_EXCEPTION')
   if reconcile:args.append('-DFATAL_RECONCILE')
   if toggle:args.append('-DFATAL_CLIENT_TOGGLE')
   subprocess.run(args,check=True)
   env=os.environ.copy();env['DYLD_INSERT_LIBRARIES']=str(p/'guard.dylib');env['EXALT_GUARD']=settings;env['EXALT_VERIFY_ONE_HP']='1' # production must ignore diagnostic threshold
   process=subprocess.Popen([str(p/'RotMGExalt')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   if toggle:
    tool=p/'control'
    subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tools/live_control.c'),'-o',str(tool)],check=True)
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
     logs=list(p.glob('guard-*.tsv'))
     if logs and any(e['phase']==22 and e['flag0']==1 for e in analyze.read_events(logs[0].read_text())):break
     time.sleep(0.02)
    else:self.fail('fixture did not begin Nexus escape')
    subprocess.run([str(tool),str(p/'guard-live.bin'),'1','0','0','0','0','0'],check=True)
   stdout,stderr=process.communicate(timeout=10)
   result=subprocess.CompletedProcess(process.args,process.returncode,stdout,stderr)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   self.output=result.stdout
   self.log=next(p.glob('guard-*.tsv')).read_text()
   self.events=analyze.read_events(self.log)
   self.secondary_reports=analyze.analyze(next(p.glob('guard-*.tsv')))['fatal_intervention']['suppressed_secondary_reports']
   self.assertFalse(list(p.glob('hit-flight-*.bin')),'client does not write diagnostic flight files')
   self.assertFalse(any(e['phase']<20 and e['phase']!=15 for e in self.events),'client records intervention and nonpositive-HP events')
   dump=p/'dump'
   subprocess.run(['clang','-Wall','-Wextra','-Werror',str(ROOT/'tools/live_dump.c'),'-o',str(dump)],check=True)
   text=subprocess.check_output([str(dump),str(p/'guard-live.bin')],text=True)
   self.live=dict(line.split('=',1) for line in text.splitlines() if '=' in line)
 def test_meter_limits_alone_do_not_escape(self):
  for environment in (1,2,3,4,5):
   with self.subTest(environment=environment):
    self.run_client('armed=1,potion=0,death=1',environment=environment)
    self.assertIn('nexus_calls=0',self.output)
    self.assertNotIn('guard_environment_nexus',self.log)
    self.assertFalse(any(e['phase']==20 for e in self.events))
    self.assertEqual(self.live['death_pending'],'0')
    self.assertFalse(any(e['phase']>=100 for e in self.events),'normal play keeps incident history in memory')
 def test_incident_history_wraps_and_dumps_once_on_incoming_zero(self):
  self.run_client('armed=1,potion=0,death=1',environment=17)
  history=[e for e in self.events if 100<=e['phase']<199]
  markers=[e for e in self.events if e['phase']==199]
  self.assertEqual(len(history),64)
  self.assertEqual(len(markers),1)
  self.assertTrue(analyze.incident_summary(self.events)[0]['complete'])
  self.assertEqual(markers[0]['value'],6)
  self.assertEqual((history[-1]['phase'],history[-1]['hp'],history[-1]['update_source']),(106,0,2))
  self.assertEqual([e['id'] for e in history],sorted(e['id'] for e in history))
  self.assertTrue(all(e['ns']>0 for e in history))
  self.assertIn('nexus_calls=0',self.output)
 def test_incident_catches_notification_that_bypasses_hp_setter(self):
  self.run_client('armed=1,potion=0,death=1',environment=18)
  markers=[e for e in self.events if e['phase']==199]
  self.assertEqual(len(markers),1)
  self.assertEqual(markers[0]['value'],10)
  notifications=[e for e in self.events if e['phase']==110]
  self.assertEqual([e['hp'] for e in notifications],[200,200,200,0])
  self.assertIn('nexus_calls=0',self.output)
 def test_incident_catches_death_screen_without_a_setter_or_notification(self):
  self.run_client('armed=1,potion=0,death=1',environment=19)
  self.assertEqual([e['value'] for e in self.events if e['phase']==199],[13])
  self.assertTrue(any(e['phase']==113 for e in self.events))
 def test_manual_nexus_saves_history_at_positive_hp(self):
  self.run_client('armed=1,potion=0,death=1',environment=20)
  self.assertEqual([e['value'] for e in self.events if e['phase']==199],[7])
  self.assertEqual([e['hp'] for e in self.events if e['phase']==107],[200])
 def test_poll_fallback_captures_direct_unhooked_terminal_write(self):
  self.run_client('armed=1,potion=0,death=1',environment=21)
  self.assertEqual([e['value'] for e in self.events if e['phase']==199],[4])
  self.assertEqual([e['hp'] for e in self.events if e['phase']==104],[0])
 def test_manual_request_does_not_hide_later_death_in_same_scope(self):
  self.run_client('armed=1,potion=0,death=1',environment=22)
  self.assertEqual([e['value'] for e in self.events if e['phase']==199],[7,6])
  self.assertTrue(all(e['complete'] for e in analyze.incident_summary(self.events)))
 def test_meter_limits_preserve_dry_run_disabled_and_missing_fields(self):
  for settings,no_context in (('armed=0,potion=0,death=1',False),('armed=1,potion=0,death=0',False),('armed=1,potion=0,death=1',True)):
   with self.subTest(settings=settings,no_context=no_context):
    self.run_client(settings,environment=1,no_context=no_context)
    self.assertIn('nexus_calls=0',self.output)
 def test_nonlethal_environment_hp_update_preserves_lethal_hit_protection(self):
  for environment in (6,7):
   with self.subTest(environment=environment):
    self.run_client('armed=1,potion=0,death=1',environment=environment)
    self.assertIn('meter_and_nonlethal_damage_did_not_escape=1',self.output)
    self.assertIn('lethal_covered_hit_and_following_damage_blocked=1',self.output)
    self.assertIn('nexus_calls=1',self.output)
    self.assertTrue(any(e['phase']==22 and e['flag0']==1 for e in self.events))
 def test_incoming_terminal_hp_never_requests_escape(self):
  for environment in (8,9):
   with self.subTest(environment=environment):
    self.run_client('armed=1,potion=0,death=1',environment=environment)
    self.assertIn('incoming_hp_forwarded_without_escape=1',self.output)
    self.assertIn('nexus_calls=0',self.output)
    self.assertNotIn('guard_incoming_lethal_hp',self.log)
 def test_local_lethal_hp_and_following_damage_are_cancelled(self):
  for environment in (10,11):
   with self.subTest(environment=environment):
    self.run_client('armed=1,potion=0,death=1',environment=environment)
    self.assertIn('local_lethal_and_following_hp_writes_cancelled=1',self.output)
    self.assertIn('local_hp_hatch_and_report_behavior_checked=1',self.output)
    self.assertIn('nexus_calls=1',self.output)
    self.assertIn('guard_local_hp_blocked',self.log)
 def test_local_hp_hatch_respects_dry_run_and_disabled(self):
  for settings in ('armed=0,potion=0,death=1','armed=1,potion=0,death=0'):
   with self.subTest(settings=settings):
    self.run_client(settings,environment=10)
    self.assertIn('local_hp_hatch_and_report_behavior_checked=1',self.output)
    self.assertIn('nexus_calls=0',self.output)
 def test_local_hp_failed_request_does_not_fake_cancellation(self):
  for failure in ('denied','exception'):
   with self.subTest(failure=failure):
    self.run_client('armed=1,potion=0,death=1',environment=10,**{failure:True})
    self.assertIn('local_hp_hatch_and_report_behavior_checked=1',self.output)
    self.assertNotIn('guard_local_hp_blocked',self.log)
 def test_local_lethal_hp_can_retry_a_failed_hit_request(self):
  self.run_client('armed=1,potion=0,death=1',environment=15,denied=True)
  self.assertIn('local_hp_hatch_and_report_behavior_checked=1',self.output)
  self.assertIn('nexus_calls=2',self.output)
 def test_nonlethal_local_writes_and_excluded_origins_pass(self):
  for environment in (12,13,14,16):
   with self.subTest(environment=environment):
    self.run_client('armed=1,potion=0,death=1',environment=environment)
    self.assertIn('nexus_calls=0',self.output)
    self.assertNotIn('guard_local_hp_blocked',self.log)
 def test_healed_full_hp_does_not_escape_on_three_nonlethal_hits(self):
  self.run_client('armed=1,potion=0,death=1',false_positive=True)
  self.assertIn('healed_full_hp_survived_3x110=1',self.output)
  self.assertIn('nexus_calls=0',self.output)
  self.assertFalse(any(e['phase']==20 for e in self.events))
 def test_authoritative_hp_rebases_prediction_before_the_next_hit(self):
  self.run_client('armed=1,potion=0,death=1',hp_cross=True)
  self.assertIn('authoritative_hp_rebased_before_next_hit=1',self.output)
  self.assertIn('nexus_calls=1',self.output)
  decision=next(e for e in self.events if e['phase']==20)
  self.assertEqual(decision['hp'],40)
  self.assertEqual(decision['value'],50)
  self.assertEqual(decision['projectile'],50)
 def test_mixed_paths_accumulate_in_one_authoritative_window(self):
  self.run_client('armed=1,potion=0,death=1',mixed=True)
  self.assertIn('mixed_paths_rebased_and_preserved_same_window_burst=1',self.output)
  self.assertIn('nexus_calls=1',self.output)
  decision=next(e for e in self.events if e['phase']==20)
  self.assertEqual(decision['projectile'],220)
  self.assertEqual(decision['update_context'],(1<<64)-40)
  self.assertEqual([e['caller'] for e in self.secondary_reports],['0x183f880'])
 def test_terrain_and_area_use_shared_escape_and_only_cancel_matching_reports(self):
  for boundary in ('0x196ed90UL','0x183f880UL'):
   with self.subTest(boundary=boundary):
    self.run_client('armed=1,potion=0,death=1',boundary=boundary)
    self.assertIn('boundary_sent=3 other_sent=12',self.output)
    self.assertIn('nexus_calls=1',self.output)
    self.assertEqual(sum(e['phase']==30 for e in self.events),3)
    self.assertEqual([e['caller'] for e in self.secondary_reports],[boundary[:-2]]*3)
 def test_boundary_dry_run_and_disabled_mode_preserve_damage(self):
  for settings in ('armed=0,potion=0,death=1','armed=1,potion=0,death=0'):
   with self.subTest(settings=settings):
    self.run_client(settings,boundary='0x196ed90UL')
    self.assertIn('boundary_sent=6 other_sent=12',self.output)
    self.assertIn('nexus_calls=0',self.output)
    self.assertFalse(any(e['phase'] in (24,30) for e in self.events))
 def test_boundary_request_failure_preserves_notifications_and_reports(self):
  for boundary in ('0x196ed90UL','0x183f880UL'):
   for failure in ('denied','exception'):
    with self.subTest(boundary=boundary,failure=failure):
     self.run_client('armed=1,potion=0,death=1',boundary=boundary,**{failure:True})
     self.assertIn('boundary_sent=6 other_sent=12',self.output)
     self.assertFalse(any(e['phase'] in (24,30) for e in self.events))
 def test_armed_toggle_protects_burst_with_legacy_nexus_ignored(self):
  self.run_client('armed=1,potion=50,ceiling=80,nexus=25,death=1')
  self.assertIn('nexus_calls=1',self.output);self.assertIn('potion_calls=0',self.output)
  self.assertEqual(self.live['armed'],'1');self.assertEqual(self.live['death'],'1')
  self.assertEqual(self.live['nexus'],'0');self.assertEqual(self.live['potion'],'50')
  self.assertEqual(self.live['nexus_sent'],'1')
  self.assertIn('guard_death_nexus',self.log)
  self.assertEqual(sum(e['phase']==23 for e in self.events),3)
  self.assertTrue(any(e['phase']==25 and e['flag0']==1 for e in self.events))
 def test_unarmed_toggle_only_records_dry_decision(self):
  self.run_client('armed=0,potion=0,nexus=100,death=1',denied=True)
  self.assertIn('nexus_calls=0',self.output)
  self.assertEqual(self.live['nexus_sent'],'0');self.assertEqual(self.live['nexus_dry'],'1')
  self.assertFalse(any(e['phase'] in (22,23,24) for e in self.events))
 def test_toggle_off_never_installs_or_changes_damage(self):
  self.run_client('armed=1,potion=0,nexus=100',denied=True)
  self.assertIn('nexus_calls=0',self.output)
  self.assertEqual(self.live['death'],'0');self.assertEqual(self.live['death_status'],'0')
  self.assertNotIn('hit_probe_ready',self.log)
  self.assertEqual(self.events,[])
 def test_server_reset_keeps_escape_latch(self):
  self.run_client('armed=1,potion=0,nexus=0,death=1',reconcile=True)
  resets=[e for e in self.events if e['phase']==28]
  self.assertEqual([e['flag1'] for e in resets],[0,1])
  self.assertEqual([e['projectile'] for e in resets],[0,0])
  self.assertEqual(self.live['nexus_sent'],'1')
 def test_disabling_toggle_mid_escape_keeps_pending_escape_blocked(self):
  self.run_client('armed=1,potion=0,nexus=0,death=1',toggle=True)
  self.assertEqual(sum(e['phase']==23 for e in self.events),4)
  self.assertEqual(self.live['death'],'0');self.assertEqual(self.live['armed'],'0')
  self.assertEqual(self.live['control_result'],'1');self.assertEqual(self.live['death_blocking'],'0')
  self.assertIn('nexus_calls=1',self.output)
 def test_failed_request_preserves_damage(self):
  self.run_client('armed=1,potion=0,nexus=0,death=1',denied=True)
  self.assertIn('nexus_calls=1',self.output);self.assertEqual(self.live['nexus_sent'],'0')
  self.assertFalse(any(e['phase'] in (23,24) for e in self.events))
 def test_exception_preserves_damage(self):
  self.run_client('armed=1,potion=0,nexus=0,death=1',exception=True)
  self.assertEqual(next(e for e in self.events if e['phase']==22)['flag2'],1)
  self.assertFalse(any(e['phase'] in (23,24) for e in self.events))

if __name__=='__main__':unittest.main()
