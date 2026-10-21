"""Production incident decoding, independent of the native game fixture."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'probe'))
import analyze

def event(phase,**values):
    row=dict.fromkeys(analyze.FIELDS,0)
    row.update(phase=phase,**values)
    return row

class IncidentTests(unittest.TestCase):
    def test_signed_budget_and_original_caller_are_preserved(self):
        history=event(127,id=8,ns=1000,work_ns=150,projectile=(1<<64)-42,
                      callsite=0x6538a2,hp=108,value=150)
        marker=event(199,id=9,ns=2000,value=6,flag0=1,flag2=1,owner=1)
        result=analyze.incident_summary([history,marker])[0]
        self.assertEqual(result['history'][0]['pending'],150)
        self.assertEqual(result['history'][0]['projected'],-42)
        self.assertEqual(result['history'][0]['caller'],'0x6538a2')
        self.assertEqual(result['history'][0]['before_trigger_ms'],0.001)
        self.assertTrue(result['armed'] and result['enabled'])
        self.assertFalse(result['blocking'])
        self.assertTrue(result['complete'])

    def test_incomplete_history_is_not_reported_as_a_complete_incident(self):
        self.assertEqual(analyze.incident_summary([event(106,hp=0)]),[])

    def test_histories_are_not_combined_across_incidents(self):
        result=analyze.incident_summary([event(105,id=1),event(199,value=7),
                                         event(113,id=2),event(199,value=13)])
        self.assertEqual([[e['id'] for e in r['history']] for r in result],[[1],[2]])

    def test_dropped_history_is_explicitly_incomplete(self):
        self.assertFalse(analyze.incident_summary([event(106),event(199,owner=2)])[0]['complete'])
        self.assertFalse(analyze.incident_summary([event(106),event(199,owner=1,flag3=1)])[0]['complete'])

if __name__=='__main__':unittest.main()
