#!/bin/zsh
set -eu
setopt NO_BG_NICE
here="${0:A:h}"
launcher='/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/MacOS/RotMG Exalt Launcher'
game_library="$HOME/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib"
if pgrep -x RotMGExalt >/dev/null || pgrep -xf '.*RotMG Exalt Launcher' >/dev/null; then
    print 'Quit the game and DECA launcher before starting this diagnostic.'
    read -r '?Press Return to close.'
    exit 1
fi
probe_library="$here/ExaltHitProbe.dylib"
if [[ "${1:-}" == '--sync' ]]; then probe_library="$here/ExaltSyncProbe.dylib"; fi
if [[ ! -x "$launcher" || ! -f "$game_library" || ! -f "$probe_library" ]]; then
    print 'A required game or probe file is missing.'
    read -r '?Press Return to close.'
    exit 1
fi
expected="$(cat "$here/game-build.sha256")"
actual="$(/usr/bin/shasum -a 256 "$game_library")"
if [[ "${actual%% *}" != "$expected" ]]; then
    print 'The game build changed. The probe has not been started.'
    read -r '?Press Return to close.'
    exit 1
fi
fatal_mode=0
verify_mode=0
sync_mode=0
if [[ "${1:-}" == '--intervene' ]]; then
    fatal_mode=1
elif [[ "${1:-}" == '--verify' ]]; then
    fatal_mode=1
    verify_mode=1
elif [[ "${1:-}" == '--observe' ]]; then
    fatal_mode=0
elif [[ "${1:-}" == '--sync' ]]; then
    sync_mode=1
elif [[ -n "${1:-}" ]]; then
    print 'Usage: Start Hit Diagnostic.command [--observe | --verify | --intervene | --sync]'
    exit 1
fi
print 'Exalt damage-path diagnostic'
if [[ "$verify_mode" == 1 ]]; then
    print 'VERIFICATION: prediction uses 1 HP; actual game HP is unchanged.'
    print 'One small positive hit on an audited path should request Nexus.'
    print 'Start at full health. Do not approach lethal HP.'
elif [[ "$fatal_mode" == 1 ]]; then
    print 'LIVE INTERVENTION: predicted lethal projectile, ground and radius/AOE damage requests Nexus before reporting.'
    print 'After the local Nexusing flag is set, the audited fatal and subsequent damage reports are withheld.'
    print 'Incoming HP updates rebase pending damage. Meter limits alone do not trigger escape.'
    print 'Other damage sources are not covered by this prototype.'
else
    print 'Observation-only mode. Gameplay automation is off.'
fi
print 'Auto potions and party Join remain disabled.'
print 'Click Play, enter Nexus, and wait for Probe installed before testing.'
if (( sync_mode )); then
    print "Trace details: $here/hp-sync-investigation.md"
else
    print "Test instructions: $here/damage-testing.md"
fi
if (( sync_mode )); then
    print 'Play briefly while healthy, include healing and a few small hits, then manually Nexus.'
else
    print 'Begin with a fresh realm/map and one nonlethal source at a time. Escape manually.'
fi
print 'If escape stalls or the local request fails, stop and quit normally. Report what happened.'
print 'This prototype runs until the game is closed. The file-backed recorder preserves recent events.'
if (( sync_mode )); then
    test_id=SYNC
    print 'Synchronization observation: normal healing and a few weak hits while healthy; manually Nexus afterward.'
    print 'No automatic escape or damage cancellation. No test labels are required.'
else
    read -r 'test_id?Test ID from the checklist [D00]: '
fi
test_id="${test_id:-D00}"
if [[ "$test_id" == *[^A-Za-z0-9_-]* || ${#test_id} -gt 32 ]]; then
    print 'Use a test ID containing letters, numbers, underscores or hyphens (maximum 32).'
    exit 1
fi
read -r '?Press Return to open the launcher, or Control-C to cancel.'
mkdir -p "$here/data/sessions"
session_dir="$(mktemp -d "$here/data/sessions/$test_id-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
EXALT_VERIFY_ONE_HP="$verify_mode" EXALT_FATAL_INTERVENTION="$fatal_mode" EXALT_GUARD='armed=0,potion=0,nexus=0' EXALT_GUARD_DIR="$session_dir" \
DYLD_INSERT_LIBRARIES="$probe_library" "$launcher" >/dev/null 2>&1 &!
print "Session: $session_dir"
print 'Return to the chat after a damage test. The game can be quit normally.'

python3 "$here/watch_probe.py" "$session_dir/logs"
for i in {1..50}; do
    pgrep -x RotMGExalt >/dev/null || break
    sleep 0.1
done
logs=("$session_dir"/logs/guard-*.tsv(N))
if (( ${#logs} == 1 )) && ! pgrep -x RotMGExalt >/dev/null; then
    python3 "$here/damage_session.py" "$logs[1]" --output "$session_dir/bundle" --test-id "$test_id"
else
    print 'Quit the game before bundling. The raw session is preserved at:'
    print "$session_dir"
fi
