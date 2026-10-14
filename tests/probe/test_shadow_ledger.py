import importlib.util
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('shadow',ROOT/'probe/shadow_ledger.py')
shadow=importlib.util.module_from_spec(spec);spec.loader.exec_module(shadow)

def event(identity,phase=4,hp=1000,value=0,generation=1,maximum=1000,context=0,source=0):
 return dict(id=identity,phase=phase,hp=hp,max=maximum,value=value,generation=generation,ns=identity*1000,
  valid=int(0<=hp<=maximum),in_nexus=0,update_context=context,update_source=source,tick_sequence=0,server_time=0)

class ShadowTests(unittest.TestCase):
 def test_burst_crosses_without_waiting_for_hp(self):
  s=shadow.ShadowLedger(25);s.feed(event(1))
  rows=[s.feed(event(i+2,12,value=250)) for i in range(3)]
  self.assertEqual([r['debit_estimate'] for r in rows],[750,500,250])
  self.assertTrue(rows[-1]['debit_crossed'])
  s.feed(event(5,3,value=250))
  self.assertEqual(s.damage_total,750)
 def test_heal_preserves_pending_and_net_debit_is_only_hypothesis(self):
  s=shadow.ShadowLedger(25);s.feed(event(1,hp=1027,maximum=1100))
  for i in range(5):s.feed(event(i+2,12,hp=1027,maximum=1100,value=45))
  heal=s.feed(event(7,6,hp=1032,maximum=1100))
  self.assertEqual(heal['held_damage'],225);self.assertEqual(heal['debit_pending'],225)
  drop=s.feed(event(8,6,hp=811,maximum=1100))
  self.assertEqual(drop['held_damage'],225);self.assertEqual(drop['debit_pending'],4)
  self.assertEqual(drop['debit_estimate'],807)
  self.assertFalse(drop['acknowledged']);self.assertEqual(drop['status'],'ambiguous')
 def test_same_hp_tick_never_acknowledges_pending_hits(self):
  s=shadow.ShadowLedger(20);s.feed(event(1));s.feed(event(2,12,value=100))
  s.feed(event(3,17,context=3,source=1))
  self.assertEqual(s.debit_pending,100)
  self.assertEqual(s.held_damage,100)
 def test_map_reset_and_max_change(self):
  s=shadow.ShadowLedger(20);s.feed(event(1));s.feed(event(2,12,value=100))
  changed=s.feed(event(3,6,maximum=1100))
  self.assertEqual(changed['held_damage'],100)
  reset=s.feed(event(4,generation=2))
  self.assertEqual(reset['held_damage'],0)
 def test_invalid_or_uncovered_observations_do_not_become_ack(self):
  s=shadow.ShadowLedger(20);s.feed(event(1));s.feed(event(2,12,value=50))
  s.feed(event(3,12,value=-1))
  self.assertEqual(s.damage_total,50)
  drop=s.feed(event(4,6,hp=700))
  self.assertEqual(drop['unexplained_debit'],250)
  self.assertFalse(drop['acknowledged'])
 def test_terminal_hp_stops_shadow_prediction(self):
  s=shadow.ShadowLedger(20);s.feed(event(1));s.feed(event(2,12,value=100))
  death=s.feed(event(3,6,hp=0,source=3))
  self.assertEqual(death['status'],'terminal')
  self.assertIsNone(death['debit_estimate'])

 def test_negative_hp_is_terminal_and_cannot_reactivate_same_generation(self):
  s=shadow.ShadowLedger(20);s.feed(event(1));s.feed(event(2,12,value=100))
  terminal=s.feed(event(3,6,hp=-20))
  self.assertEqual(terminal['status'],'terminal')
  later=s.feed(event(4,hp=1000))
  self.assertEqual(later['status'],'terminal')
  fresh=s.feed(event(5,hp=1000,generation=2))
  self.assertEqual(fresh['status'],'baseline_only')
 def test_death_screen_stops_prediction_even_before_zero_observation(self):
  s=shadow.ShadowLedger(20);s.feed(event(1))
  terminal=s.feed(event(2,13))
  self.assertEqual(terminal['status'],'terminal')
  self.assertIsNone(terminal['held_estimate'])

if __name__=='__main__':unittest.main()
