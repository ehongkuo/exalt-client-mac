#!/bin/zsh
set -eu
setopt NO_BG_NICE

# Guard settings. armed=0 is a dry run: it logs what it would do and never acts.
#   potion / nexus: thresholds in percent of max HP (0 disables). nexus must be below potion.
#   ceiling: once HP drops to `potion`, keep drinking as fast as the game allows until HP is over
#            this percent. 0 = stop as soon as HP is back above `potion`.
#   Potions come from the quickslots in order: the first until it is empty, then the second, then the third.
GUARD_SETTINGS='armed=0,potion=50,ceiling=80,nexus=25'  # fallback when no saved settings: dry run
# Settings saved from Exalt Client Mac take precedence. The guard rejects anything invalid and
# then runs in dry run, so a damaged file can never arm it with unexpected values.
data_dir="$HOME/Library/Application Support/Exalt Client Mac"
settings_file="$data_dir/guard-settings.conf"
if [[ -f "$settings_file" ]]; then
    saved="$(head -n 1 "$settings_file" | tr -d '[:space:]')"
    [[ -n "$saved" ]] && GUARD_SETTINGS="$saved"
fi

guard_dir="${0:A:h}"
launcher='/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/MacOS/RotMG Exalt Launcher'
game_library="$HOME/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib"
# The GameAssembly build the guard was checked against (also read by Exalt Client Mac).
expected="$(tr -d '[:space:]' < "${0:A:h}/game-build.sha256" 2>/dev/null || true)"

if [[ ! -x "$launcher" || ! -f "$game_library" || ! -f "$guard_dir/ExaltGuard.dylib" ]]; then
    print 'A required app or guard file is missing. Return to the chat.'
    read -r '?Press Return to close.'
    exit 1
fi
actual="$(/usr/bin/shasum -a 256 "$game_library")"
if [[ "${actual%% *}" != "$expected" ]]; then
    print 'Exalt changed since inspection. The guard has not been started.'
    print 'Return to the chat so the new build can be checked.'
    read -r '?Press Return to close.'
    exit 1
fi

print 'Exalt HP guard'
print "Settings: $GUARD_SETTINGS"
if [[ "$GUARD_SETTINGS" == *armed=1* ]]; then
    print 'ARMED: it will drink potions and return to the Nexus automatically.'
else
    print 'DRY RUN: it only logs what it would do. No potions, no Nexus.'
fi
print 'Quit any existing game and DECA launcher before continuing.'
print 'Runs until you quit the game.'
read -r '?Press Return to open the launcher, or Control-C to cancel.'

mkdir -p "$data_dir/logs"
# Live view of the guard: HP, thresholds, quickslots, actions and latency.
open -a "$HOME/Applications/Exalt Client Mac.app" || print 'Could not open Exalt Client Mac; the guard still runs.'
# Apply the guard to this launch only; do not change the global environment.
EXALT_GUARD_DIR="$data_dir" EXALT_GUARD="$GUARD_SETTINGS" DYLD_INSERT_LIBRARIES="$guard_dir/ExaltGuard.dylib" "$launcher" >/dev/null 2>&1 &!
print 'Launcher started. You can close this Terminal window after the launcher opens.'
