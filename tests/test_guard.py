import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
ROOT=Path(__file__).resolve().parent.parent   # repository root
# Columns appended to the timing row: 15 player_hp, 16 player_max, 17 bar_aux, 18 action, 19 result, 20 slot
ACTION,RESULT,SLOT=18,19,20
POTION,NEXUS='1','2'
DUMP=None
CONTROL=None

def live_control(path,request,armed,potion,ceiling,nexus):
 global CONTROL
 if CONTROL is None:
  CONTROL=Path(tempfile.mkdtemp(prefix='exalt-live-control-'))/'live-control'
  subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tools'/'live_control.c'),'-o',str(CONTROL)],check=True)
 args=[str(path),str(request),str(armed),str(potion),str(ceiling),str(nexus)]
 if request=='join':args=args[:4]   # FILE join REQUEST NAME
 subprocess.run([str(CONTROL),*args],check=True)

def live_join(path,request,name):
 live_control(path,'join',request,name,'','')

def live_dump(path):
 global DUMP
 if DUMP is None:
  DUMP=Path(tempfile.mkdtemp(prefix='exalt-live-dump-'))/'live-dump'
  subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tools'/'live_dump.c'),'-o',str(DUMP)],check=True)
 out=subprocess.run([str(DUMP),str(path)],check=True,capture_output=True,text=True).stdout
 state={'event':[]}
 for line in out.splitlines():
  k,v=line.split('=',1)
  if k=='event':state['event'].append(v.split(','))
  else:state[k]=v
 return state

class GuardTests(unittest.TestCase):
 def run_fixture(self, config=None, *defines, during=None, data_dir=False):
  with tempfile.TemporaryDirectory(prefix='exalt-guard-') as folder:
   p=Path(folder)
   # data_dir: the app's way, no compiled-in folder; EXALT_GUARD_DIR names the data folder.
   logdir=p/'data'/'logs' if data_dir else p
   flags=[] if data_dir else [f'-DPROBE_LOG_DIR="{p}"']
   subprocess.run(['clang','-arch','x86_64','-O2','-Wall','-Wextra','-Werror','-dynamiclib','-DEXALT_CLIENT_FATAL',
    *flags,'-DSESSION_NS=3500000000ULL',str(ROOT/'guard'/'guard.c'),'-o',str(p/'guard.dylib')],check=True)
   cmd=['clang','-arch','x86_64','-Wall','-Wextra','-Werror','-Wl,-export_dynamic',str(ROOT/'tests'/'fixture.c'),'-o',str(p/'RotMGExalt')]
   cmd+=[f'-D{d}' for d in defines]
   subprocess.run(cmd,check=True)
   env=os.environ.copy();env['DYLD_INSERT_LIBRARIES']=str(p/'guard.dylib');env.pop('EXALT_GUARD',None)
   if config is not None:env['EXALT_GUARD']=config
   env.pop('EXALT_GUARD_DIR',None)
   if data_dir:(p/'data').mkdir();env['EXALT_GUARD_DIR']=str(p/'data')
   game=subprocess.Popen([str(p/'RotMGExalt')],env=env,stdout=subprocess.PIPE,text=True)
   if during:
    time.sleep(during[0]); during[1](logdir/'guard-live.bin')
   out,_=game.communicate(timeout=12)
   self.assertEqual(game.returncode,0)
   log=next(logdir.glob('guard-*.tsv')).read_text()
   self.assertIn('status\tcomplete',log)
   calls=dict(kv.split('=') for kv in out.split())
   rows=[l.split('\t') for l in log.splitlines() if l.startswith('timing\t')]
   self.live=live_dump(logdir/'guard-live.bin')
   # Join results are checked on their own, so the exact potion/Nexus comparisons stay as they were.
   self.join={'calls':int(calls.pop('join_calls')),'cooldown':int(calls.pop('join_cooldown_arg')),'name':calls.pop('join_name')}
   return log,rows,{k:int(v) for k,v in calls.items()}
 def actions(self,rows):
  return [(r[ACTION],r[RESULT]) for r in rows if r[ACTION]!='0']
 def test_dry_run_decides_but_never_calls(self):
  log,rows,calls=self.run_fixture()
  self.assertEqual(calls['potion_calls'],0);self.assertEqual(calls['nexus_calls'],0)
  acts=self.actions(rows)
  # Dry run drinks nothing, so no heal shows: one decision, then it waits for the 1 s heal window.
  potions=[a for a in acts if a[0]==POTION]
  self.assertEqual(potions,[(POTION,'0')])
  self.assertEqual([a for a in acts if a[0]==NEXUS],[(NEXUS,'0')])
  self.assertEqual({r[SLOT] for r in rows if r[ACTION]==POTION},{'1'})
  self.assertIn('guard_config\tarmed=0\tpotion=50\tceiling=0\tnexus=25\tdeath=0\tquickslots=sequential',log)
  self.assertIn('guard_ready\n',log)
  self.assertIn('guard_quickslot_base\t1000001',log)
 def test_armed_drinks_once_without_heal_then_nexus(self):
  # 400 HP from 1.3 s; this script's potions never heal, so after one drink the guard waits for
  # a heal that never shows. HP drops to 20% at 1.8 s, before the 1 s heal window ends: Nexus.
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25')
  self.assertEqual(calls,{'potion_calls':1,'potion_arg':1000002,'nexus_calls':1})
  self.assertNotIn('guard_disarmed',log)
  self.assertEqual(self.actions(rows),[(POTION,'1'),(NEXUS,'1')])
 def drink_times(self,rows):
  return [float(r[2]) for r in rows if r[ACTION]==POTION]
 def test_one_potion_per_heal_up_to_ceiling(self):
  # The live bug: 7 potions in 316 ms because HP only updates every ~200 ms. Here each potion
  # heals 100 HP 200 ms after the drink. Expected: drink, wait for the heal, drink again, at
  # least 250 ms apart: 1.3, 1.55, 1.8, 2.05 s (40% -> 70%; player changes at 2.2 s).
  log,rows,calls=self.run_fixture('armed=1,potion=50,ceiling=80,nexus=25','HEALING')
  self.assertEqual(calls['potion_calls'],4)
  times=self.drink_times(rows)
  self.assertTrue(all(b-a>=0.249 for a,b in zip(times,times[1:])),times)
  self.assertEqual([r[15] for r in rows if r[ACTION]==POTION],['400','500','600','700'])
 def test_one_potion_per_heal_without_ceiling(self):
  # Without a ceiling it stops once HP is back above 50%: 400 -> 500 (still 50%) -> 600.
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25','HEALING')
  self.assertEqual(calls['potion_calls'],2)
 def test_ceiling_keeps_drinking_until_over_it(self):
  log,rows,calls=self.run_fixture('armed=1,potion=50,ceiling=80,nexus=25','CEILING_SCRIPT')
  self.assertEqual(calls['potion_calls'],2)        # at 40% and again at 70%
  self.assertEqual([r[15] for r in rows if r[ACTION]==POTION],['400','700'])
 def test_without_ceiling_stops_above_trigger(self):
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25','CEILING_SCRIPT')
  self.assertEqual(calls['potion_calls'],1)
 def test_never_acts_in_nexus(self):
  log,rows,calls=self.run_fixture('armed=1')
  self.assertEqual(calls['nexus_calls'],1)
  self.assertIn('guard_map\tBeach\t{s.beac',log)
  self.assertIn('guard_map\tNexus\t{s.nexus}',log)
  self.assertLess(log.index('guard_map\tBeach'),log.index('guard_map\tNexus'))
 def test_new_player_settles_before_acting(self):
  # Player 41 stays on the beach: its stale 180/1100 readings must be ignored, and the real
  # drop to 10% is acted on once max HP has been stable for 500 ms.
  log,rows,calls=self.run_fixture('armed=1','BEACH_AFTER')
  self.assertEqual(calls['nexus_calls'],2)
  acted=[(r[ACTION],r[15],r[16]) for r in rows if r[ACTION]!='0']
  self.assertFalse(any(hp=='180' or mx=='1100' for _,hp,mx in acted))
  self.assertEqual(acted[-1],(NEXUS,'100','1000'))
 def test_unknown_map_still_protects(self):
  log,rows,calls=self.run_fixture('armed=1','NO_MAP')
  self.assertIn('guard_map_unknown',log)
  self.assertEqual(calls['nexus_calls'],2)
 def test_all_quickslots_empty_never_drinks_but_still_nexus(self):
  log,rows,calls=self.run_fixture('armed=1','ALL_EMPTY')
  self.assertEqual(calls['potion_calls'],0);self.assertEqual(calls['nexus_calls'],1)
  self.assertEqual(self.actions(rows),[(NEXUS,'1')])
 def test_offset_mismatch_refuses_to_arm(self):
  log,rows,calls=self.run_fixture('armed=1','BAD_OFFSET')
  self.assertEqual(calls['potion_calls']+calls['nexus_calls'],0)
  self.assertIn('guard_refused',log)
 def test_invalid_config_stays_dry(self):
  log,rows,calls=self.run_fixture('armed=1,potion=10,nexus=30')
  self.assertEqual(calls['potion_calls']+calls['nexus_calls'],0)
  self.assertIn('guard_config_invalid',log)
 def test_missing_gui_never_acts(self):
  log,rows,calls=self.run_fixture('armed=1','NO_GUI')
  self.assertEqual(calls['potion_calls']+calls['nexus_calls'],0)
  self.assertEqual(self.actions(rows),[])
 def test_wrong_hp_field_never_acts(self):
  log,rows,calls=self.run_fixture('armed=1','HUD_WRONG')
  self.assertEqual(calls['potion_calls']+calls['nexus_calls'],0)
  self.assertEqual(self.actions(rows),[])
 def test_lagging_hud_does_not_delay_actions(self):
  # The HUD matches once at full HP and then lags; the guard must still act on time.
  log,rows,calls=self.run_fixture('armed=1','HUD_FROZEN')
  self.assertEqual(calls,{'potion_calls':1,'potion_arg':1000002,'nexus_calls':1})
 def test_game_exception_is_logged_and_disarms_potions_only(self):
  log,rows,calls=self.run_fixture('armed=1','BAD_INDEX')
  self.assertEqual(calls['potion_calls'],0);self.assertEqual(calls['nexus_calls'],1)
  self.assertIn('guard_exception\tpotion\tSystem.IndexOutOfRangeException: Index was outside the bounds of the array.',log)
  self.assertIn('guard_disarmed\tpotion_exception',log)
  self.assertEqual(self.actions(rows),[(POTION,'-1'),(NEXUS,'1')])
 def test_log_records_changes_and_heartbeat_only(self):
  log,rows,calls=self.run_fixture()
  self.assertLess(len(rows),300)        # about 3,500 checks in 3.5 s
  seq=[int(r[1]) for r in rows]
  self.assertTrue(all(b>a for a,b in zip(seq,seq[1:])))
  times=[float(r[2]) for r in rows]
  self.assertTrue(all(b-a<=1.05 for a,b in zip(times,times[1:])))
  hp=[r[15] for r in rows if r[6]=='0']
  for value in ['1000','400','200','180','100']: self.assertIn(value,hp)
 def test_live_state_and_check_rate(self):
  log,rows,calls=self.run_fixture('armed=1,potion=50,ceiling=80,nexus=25')
  live=self.live
  self.assertEqual((live['armed'],live['potion'],live['ceiling'],live['nexus']),('1','50','80','25'))
  self.assertEqual((live['map'],live['in_nexus'],live['map_known']),('Nexus','1','1'))
  self.assertEqual((live['hp'],live['max_hp'],live['slot_count']),('100','1000','3'))
  self.assertEqual((live['slot0'],live['slot1'],live['slot2']),('0/0','1/0','5/0'))
  self.assertEqual(live['next_slot'],'1')
  self.assertGreater(int(live['ticks']),2500)      # 1 ms checks for 3.5 s
  events=[(e[1],e[2],e[3],e[4]) for e in live['event']]
  self.assertEqual(events,[(POTION,'1','1','400'),(NEXUS,'1','-1','200')])
 def test_settings_from_app_apply_live(self):
  # Starts in dry run; the app arms it at 0.8 s, before the 1.3 s potion window.
  log,rows,calls=self.run_fixture('armed=0,potion=50,nexus=25',
   during=(0.8,lambda f:live_control(f,1,1,50,0,25)))
  self.assertEqual(calls,{'potion_calls':1,'potion_arg':1000002,'nexus_calls':1})
  self.assertIn('guard_config\tarmed=1\tpotion=50\tceiling=0\tnexus=25\tdeath=0\tsource=app\trequest=1',log)
  self.assertEqual((self.live['control_request'],self.live['control_result'],self.live['armed']),('1','1','1'))
 def test_invalid_settings_from_app_are_rejected(self):
  log,rows,calls=self.run_fixture('armed=0,potion=50,nexus=25',
   during=(0.8,lambda f:live_control(f,1,1,50,0,60)))
  self.assertEqual(calls['potion_calls']+calls['nexus_calls'],0)
  self.assertIn('guard_config_rejected\tarmed=1\tpotion=50\tceiling=0\tnexus=60\trequest=1',log)
  self.assertEqual((self.live['control_request'],self.live['control_result'],self.live['armed']),('1','2','0'))
 def test_thresholds_change_mid_session(self):
  # Lowering the potion trigger to 30% at 0.8 s means 40% HP no longer drinks.
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25',
   during=(0.8,lambda f:live_control(f,1,1,30,0,25)))
  self.assertEqual(calls['potion_calls'],0);self.assertEqual(calls['nexus_calls'],1)
  self.assertEqual(self.live['potion'],'30')
 def test_quickslot_changes_are_logged(self):
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25')
  slot1=[l for l in log.splitlines() if l.startswith('guard_slot\t1\t')]
  self.assertEqual([l.split('\t')[2:4] for l in slot1],[['stack=2','cooldown=0'],['stack=1','cooldown=0']])
 def test_session_summary(self):
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25')
  live=self.live
  self.assertEqual((live['potions_sent'],live['nexus_sent'],live['potions_dry'],live['nexus_dry']),('1','1','0','0'))
  # Closest call outside the Nexus: 200/1000 on the beach (the 100/1000 later is in the Nexus).
  self.assertEqual((live['lowest_hp'],live['lowest_max_hp']),('200','1000'))
  self.assertTrue(live['log_name'].startswith('guard-') and live['log_name'].endswith('.tsv'))
  self.assertGreater(float(live['lowest_epoch']),float(live['session_start_epoch']))
 def test_session_summary_dry_run(self):
  log,rows,calls=self.run_fixture()
  live=self.live
  self.assertEqual((live['potions_sent'],live['nexus_sent'],live['potions_dry'],live['nexus_dry']),('0','0','1','1'))
 def test_data_folder_from_app(self):
  # Launched by the app: logs and the live file go to EXALT_GUARD_DIR/logs.
  log,rows,calls=self.run_fixture('armed=1,potion=50,nexus=25',data_dir=True)
  self.assertEqual(calls['nexus_calls'],1)
  self.assertEqual(self.live['armed'],'1')
 def test_party_calls_from_others_only(self):
  # Message objects are reused, so new messages are content changes. History at start, normal
  # chat, the user's own call and a word that only starts with j never count.
  log,rows,calls=self.run_fixture()
  self.assertIn('guard_chat_ready',log)
  calls=[l.split('\t')[1] for l in log.splitlines() if l.startswith('guard_party_call\t')]
  self.assertEqual(calls,['Dana','Eve','Frank'])
  self.assertEqual(self.live['chat_status'],'1')
  self.assertEqual(self.live['party_calls'],'3')
  self.assertEqual(self.live['party_caller'],'Frank')
  self.assertEqual(self.live['party_text'],'Join now \u2192')
  self.assertGreater(float(self.live['party_call_epoch']),0)
  # Message text never reaches the log.
  for text in ('j cit','JJJJ','Join now','jump'): self.assertNotIn(text,log)
 def test_party_calls_without_chat_manager(self):
  log,rows,calls=self.run_fixture("armed=1","NO_CHAT")
  self.assertNotIn('guard_party_call',log)
  self.assertEqual(self.live['chat_status'],'0')
  self.assertEqual(self.live['party_calls'],'0')
  self.assertEqual(calls['nexus_calls'],1)        # the guard itself is unaffected

 def test_join_runs_the_menu_handler(self):
  # A Join click from the app runs what the menu's "Join dungeon" button runs: the party
  # manager joins the named member, then the character's LMCLHOGGKKG(1000).
  log,rows,calls=self.run_fixture(None,during=(1.2,lambda f:live_join(f,1,'Teratopositor')))
  self.assertEqual(self.join,{'calls':1,'cooldown':1000,'name':'Teratopositor'})
  self.assertIn('guard_join\tTeratopositor\tsent',log)
  self.assertEqual((self.live['join_request'],self.live['join_result'],self.live['join_name']),('1','1','Teratopositor'))
  self.assertEqual(calls['potion_calls'],0)   # dry run still never drinks: Join is a separate click
 def test_join_runs_once_per_click(self):
  def clicks(f):
   live_join(f,1,'Ann'); time.sleep(0.3); live_join(f,1,'Ann'); time.sleep(0.3); live_join(f,2,'Bo')
  log,rows,calls=self.run_fixture(None,during=(1.0,clicks))
  self.assertEqual(self.join['calls'],2)
  self.assertEqual(self.join['name'],'Bo')
 def test_join_game_error_disables_only_join(self):
  def clicks(f):
   live_join(f,1,'Ann'); time.sleep(0.3); live_join(f,2,'Bo')
  log,rows,calls=self.run_fixture('armed=1',"JOIN_THROWS",during=(1.0,clicks))
  self.assertEqual(self.join['calls'],1)                 # the second click is refused
  self.assertIn('guard_exception\tjoin\t',log)
  self.assertIn('guard_join\tAnn\tgame_error',log)
  self.assertIn('guard_join\tBo\tunsupported',log)
  self.assertEqual(calls['nexus_calls'],1)              # the HP guard keeps working
 def test_join_without_party_expires(self):
  log,rows,calls=self.run_fixture(None,"NO_PARTY",during=(0.8,lambda f:live_join(f,1,'Ann')))
  self.assertEqual(self.join['calls'],0)
  self.assertIn('guard_join\tAnn\tunavailable',log)
  self.assertEqual(self.live['join_result'],'-2')
 def test_join_refused_on_unexpected_build(self):
  log,rows,calls=self.run_fixture(None,"JOIN_BAD_OFFSET",during=(1.0,lambda f:live_join(f,1,'Ann')))
  self.assertIn('guard_join_unavailable',log)
  self.assertEqual(self.join['calls'],0)
  self.assertEqual(self.live['join_result'],'-4')
if __name__=='__main__': unittest.main()
