import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'probe'))
import environment_report

class EnvironmentReportTests(unittest.TestCase):
 def test_return_address_resolves_call_instruction_and_preserves_aliases(self):
  with tempfile.TemporaryDirectory() as folder:
   script=Path(folder)/'script.json'
   script.write_text(json.dumps({'ScriptMethod':[
    {'Address':100,'Name':'First'}, {'Address':100,'Name':'Alias'},
    {'Address':200,'Name':'Next'}]}))
   trace={'frames':[{'return_address':'0xc8'}, {'return_address':'0x63'}]}
   with patch.object(environment_report,'analyze',return_value={'environment_trace':trace}):
    result=environment_report.report('unused.tsv',script)
   self.assertEqual(result['frames'][0]['nearest_preceding_symbols'],['Alias','First'])
   self.assertEqual(result['frames'][0]['offset_from_symbol'],'0x63')
   self.assertNotIn('nearest_preceding_symbols',result['frames'][1])
   self.assertIn('validate',result['symbol_warning'])

if __name__=='__main__':unittest.main()
