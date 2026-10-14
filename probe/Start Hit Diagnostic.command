#!/bin/zsh
set -eu
setopt NO_BG_NICE
here="${0:A:h}"
launcher='/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/MacOS/RotMG Exalt Launcher'
game_library='/Users/ehongkuo/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib'
if pgrep -x RotMGExalt >/dev/null || pgrep -xf '.*RotMG Exalt Launcher' >/dev/null; then
    print 'Quit the game and DECA launcher before starting this diagnostic.'
    read -r '?Press Return to close.'
    exit 1
fi
if [[ ! -x "$launcher" || ! -f "$game_library" || ! -f "$here/ExaltHitProbe.dylib" ]]; then
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
fatal_mode=1
if [[ "${1:-}" == '--observe' ]]; then
    fatal_mode=0
elif [[ -n "${1:-}" ]]; then
    print 'Usage: Start Hit Diagnostic.command [--observe]'
    exit 1
fi
print 'Exalt fatal-hit Nexus experiment'
if [[ "$fatal_mode" == 1 ]]; then
    print 'LIVE INTERVENTION: predicted lethal projectile damage requests Nexus before its hit report.'
    print 'After the local Nexusing flag is set, the fatal and subsequent projectile reports are withheld.'
    print 'No percentage threshold is used. Server HP assignments reset the pending damage budget.'
    print 'Other damage sources are not covered by this prototype.'
else
    print 'Observation-only mode. Gameplay automation is off.'
fi
print 'Auto potions and party Join remain disabled.'
print 'Click Play, enter Nexus, and wait for Probe installed before testing.'
print 'Use your throwaway character. Begin with a fresh realm/map and test the planned projectile burst.'
print 'If escape stalls or the local request fails, stop and quit normally. Report what happened.'
print 'This prototype runs until the game is closed. The file-backed recorder preserves recent events.'
read -r '?Press Return to open the launcher, or Control-C to cancel.'
mkdir -p "$here/data"
EXALT_FATAL_INTERVENTION="$fatal_mode" EXALT_GUARD='armed=0,potion=0,nexus=0' EXALT_GUARD_DIR="$here/data" \
DYLD_INSERT_LIBRARIES="$here/ExaltHitProbe.dylib" "$launcher" >/dev/null 2>&1 &!
print "Logs will appear in $here/data/logs"
print 'Return to the chat after a damage test. The game can be quit normally.'

python3 "$here/watch_probe.py" "$here/data/logs"
