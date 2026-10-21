#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$repo_dir/build/damage-diagnostic"
mkdir -p "$out" "$repo_dir/build/probe-tests"
python3 "$repo_dir/compatibility/manage.py" generate --check
python3 "$repo_dir/probe/map_damage.py"
python3 "$repo_dir/tests/probe/test_sync_analysis.py"
clang -arch x86_64 -O2 -Wall -Wextra -Werror "$repo_dir/tests/probe/sync_trace_tests.c" -o "$repo_dir/build/probe-tests/sync-trace-tests"
"$repo_dir/build/probe-tests/sync-trace-tests"
temp=$(mktemp "$out/ExaltSyncProbe.XXXXXX")
trap 'rm -f "$temp"' EXIT
clang -arch x86_64 -O2 -Wall -Wextra -Werror -dynamiclib -DEXALT_HIT_PROBE -DEXALT_SYNC_TRACE -DSESSION_NS=0 "$repo_dir/guard/guard.c" -o "$temp"
codesign --force --sign - "$temp"
codesign --verify --strict "$temp"
mv "$temp" "$out/ExaltSyncProbe.dylib"
cp "$repo_dir/probe/Start Hit Diagnostic.command" "$repo_dir/probe/analyze_sync.py" "$repo_dir/probe/analyze.py" "$repo_dir/probe/shadow_ledger.py" "$repo_dir/probe/watch_probe.py" "$repo_dir/probe/recover_flight.py" "$repo_dir/probe/damage_session.py" "$repo_dir/guard/game-build.sha256" "$repo_dir/docs/hp-sync-investigation.md" "$out/"
printf '%s\n' 'Built observation-only sync trace. Launch existing diagnostic with --sync.'
