"""Runs unittest files' test methods in parallel threads; exits non-zero on any failure.
Usage: python3 tests/parallel.py [-j WORKERS] FILE...
Most tests wait on a real-time fake game session, so threads overlap the waiting, not CPU work."""
import argparse
import concurrent.futures
import importlib.util
from pathlib import Path
import sys
import time
import unittest

def flatten(suite):
    for test in suite:
        yield from flatten(test) if isinstance(test, unittest.TestSuite) else [test]

def load(path):
    path = Path(path).resolve()
    sys.path.insert(0, str(path.parent))   # as `python3 FILE` would
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    tests = list(flatten(unittest.defaultTestLoader.loadTestsFromModule(module)))
    for test in tests:
        # Each test runs on its own, so class fixtures would never run.
        if type(test).setUpClass.__func__ is not unittest.TestCase.setUpClass.__func__:
            sys.exit(f'{path.name}: {type(test).__name__} uses setUpClass; run it serially')
    return tests

def run(test):
    result = unittest.TestResult()
    start = time.monotonic()
    test(result)
    return test, result, time.monotonic() - start

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-j', type=int, default=6, dest='workers')
    parser.add_argument('files', nargs='+')
    args = parser.parse_args()
    tests = [test for path in args.files for test in load(path)]
    start = time.monotonic()
    problems = 0
    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        for test, result, seconds in pool.map(run, tests):
            failures = result.errors + result.failures + [(test, 'unexpected success\n')] * len(result.unexpectedSuccesses)
            for case, trace in failures:   # case is the subtest when one failed
                print(f'FAIL: {case.id()} ({seconds:.1f} s)\n{trace}', file=sys.stderr, flush=True)
            problems += bool(failures)
    names = ', '.join(Path(path).name for path in args.files)
    print(f'{names}: {len(tests)} tests in {time.monotonic() - start:.1f} s with {args.workers} workers, '
          + (f'{problems} FAILED' if problems else 'OK'))
    sys.exit(1 if problems else 0)

if __name__ == '__main__':
    main()
