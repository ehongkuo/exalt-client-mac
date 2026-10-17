#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$repo_dir/build/damage-diagnostic"}
mkdir -p "$out" "$repo_dir/build/probe-tests"
python3 "$repo_dir/compatibility/manage.py" generate --check
python3 "$repo_dir/probe/map_damage.py"
python3 "$repo_dir/tests/probe/test_damage_map.py"
python3 "$repo_dir/tests/probe/test_damage_session.py"
clang -arch x86_64 -O2 -Wall -Wextra -Werror "$repo_dir/tests/probe/hook_tests.c" "$repo_dir/tests/probe/hook_fixture.S" -o "$repo_dir/build/probe-tests/hook-tests"
"$repo_dir/build/probe-tests/hook-tests"
python3 "$repo_dir/tests/probe/test_probe.py"
python3 "$repo_dir/tests/probe/test_shadow_ledger.py"
clang -Wall -Wextra -Werror "$repo_dir/tests/probe/fatal_policy_tests.c" -o "$repo_dir/build/probe-tests/fatal-policy-tests"
"$repo_dir/build/probe-tests/fatal-policy-tests"
# Build to a new inode so a previously loaded diagnostic keeps its mapped library.
temp=$(mktemp "$out/ExaltHitProbe.XXXXXX")
trap 'rm -f "$temp"' EXIT
clang -arch x86_64 -O2 -Wall -Wextra -Werror -dynamiclib -DEXALT_HIT_PROBE -DSESSION_NS=0 "$repo_dir/guard/guard.c" -o "$temp"
codesign --force --sign - "$temp"
codesign --verify --strict "$temp"
mv "$temp" "$out/ExaltHitProbe.dylib"
cp "$repo_dir/guard/game-build.sha256" "$repo_dir/probe/Start Hit Diagnostic.command" "$repo_dir/probe/Verify Damage Protection.command" "$repo_dir/probe/analyze.py" "$repo_dir/probe/watch_probe.py" "$repo_dir/probe/recover_flight.py" "$repo_dir/probe/shadow_ledger.py" "$repo_dir/probe/damage_session.py" "$repo_dir/probe/damage_paths.json" "$repo_dir/probe/VALIDATION.md" "$repo_dir/docs/damage-testing.md" "$repo_dir/docs/damage-sources.md" "$repo_dir/docs/damage-status-audit.md" "$repo_dir/docs/performance-audit.md" "$repo_dir/docs/damage-live-validation.md" "$out/"
sed 's|\.\./docs/|./|g' "$repo_dir/probe/README.md" > "$out/README.md"
sed 's|\.\./docs/|./|g' "$repo_dir/probe/VALIDATION.md" > "$out/VALIDATION.md"
chmod +x "$out/Start Hit Diagnostic.command" "$out/Verify Damage Protection.command"
zsh -n "$out/Verify Damage Protection.command"
zsh -o NO_BG_NICE -n "$out/Start Hit Diagnostic.command"
printf '%s\n' "Built damage diagnostic in $out (observation by default)"
