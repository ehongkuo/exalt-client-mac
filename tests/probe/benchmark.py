#!/usr/bin/env python3
"""Compare production hook overhead using the Intel/Rosetta synthetic game, never the live game.
Prepare base and pr-before with git archive under build/performance, then run this script.
Results are wrapper/batch costs using fake IL2CPP APIs, not server or real-game latency.
"""
import argparse,hashlib,json,os,platform,statistics,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def run(cmd,**kwargs):return subprocess.run(cmd,check=True,**kwargs)
def main():
 p=argparse.ArgumentParser();p.add_argument('--runs',type=int,default=5);args=p.parse_args()
 out=ROOT/'build/performance';out.mkdir(parents=True,exist_ok=True)
 common=['clang','-arch','x86_64','-O2','-Wall','-Wextra','-Werror']
 fixture=out/'RotMGExalt'
 run(common+['-Wno-unused-function','-Wl,-export_dynamic','-DGUARD_BENCHMARK','-DFATAL_BURST','-DFATAL_RECONCILE','-DBAD_DAMAGE_ARGUMENT',str(ROOT/'tests/probe/integration_fixture.c'),str(ROOT/'tests/probe/hook_fixture.S'),'-o',str(fixture)])
 results={}
 for version,source in [('base',out/'base'),('pr-before',out/'pr-before'),('optimized',ROOT)]:
  folder=out/version;folder.mkdir(exist_ok=True)
  dylib=folder/'bench.dylib'
  build=common+['-dynamiclib','-undefined','dynamic_lookup','-DEXALT_CLIENT_FATAL','-DHIT_PROBE_TEST','-DHIT_PROBE_BAD_ARGUMENT_TEST','-DHIT_PROBE_MIXED_TEST','-DSESSION_NS=0',f'-DGUARD_BENCH_SOURCE="{source}/guard/guard.c"',f'-DPROBE_LOG_DIR="{folder}"']
  if version!='base':build+=['-DBENCH_HAS_SEND']
  run(build+[str(ROOT/'tests/probe/benchmark_guard.c'),'-o',str(dylib)])
  results[version]=[]
 for trial in range(args.runs):
  # Alternate the order to reduce systematic warmup/thermal bias.
  order=list(results) if trial%2==0 else list(reversed(results))
  for version in order:
   env=os.environ.copy();env.update(DYLD_INSERT_LIBRARIES=str(out/version/'bench.dylib'),EXALT_GUARD='armed=1,potion=0,death=1')
   text=run([str(fixture)],env=env,capture_output=True,text=True).stdout
   rows=[json.loads(line.removeprefix('BENCH ')) for line in text.splitlines() if line.startswith('BENCH ')]
   if len(rows)!=7:raise RuntimeError(text)
   results[version].append(rows)
   # Synthetic logs are disposable; retain numeric samples rather than grow the checkout.
   for log in (out/version).glob('guard-*.tsv'):log.unlink()
 summary={version:{row['name']:{key:statistics.median(r[i][key] for r in runs) for key in row if key!='name'} for i,row in enumerate(runs[0])} for version,runs in results.items()}
 metadata=dict(runs=args.runs,host=platform.platform(),fixture_arch='x86_64',
  source_sha256={version:{str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest()
    for p in (source/'guard/guard.c',source/'probe/hit_probe.h',source/'probe/fatal_policy.h')}
    for version,source in [('base',out/'base'),('pr-before',out/'pr-before'),('optimized',ROOT)]})
 (out/'results.json').write_text(json.dumps(dict(metadata=metadata,raw=results,median=summary),indent=2)+'\n')
 print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
