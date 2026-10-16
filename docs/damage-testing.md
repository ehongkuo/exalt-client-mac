# Damage-path in-game checklist

This build collects evidence. Double-clicking its launcher starts **observation only**. It does not
provide the integrated app's auto-potions or Nexus protection. Use a disposable character and leave
hazards manually. The first round does not require approaching lethal HP.

## Build and launch

From the diagnostics worktree root:

```sh
sh probe/build-probe.sh
open 'build/damage-diagnostic/Start Hit Diagnostic.command'
```

The build verifies the installed game and native map, runs diagnostic tests, then signs a standalone
library. It does not replace the installed app or modify installed game files. Unknown builds are refused.
All generated files and session logs stay under this repository's ignored `build/` directory.

Quit Exalt and DECA's launcher first. When prompted, enter the test ID below and press Return. Click Play,
enter Nexus, and wait for **Probe installed. Observation only**. The terminal also reports which optional
context fields are available. A missing field is not a zero meter reading. Stop if installation is refused.

## First round: one source per session

| ID | Action | Evidence needed |
|---|---|---|
| D00 | Stay in Nexus for 10 seconds, enter a safe map, manually Nexus, wait five seconds and quit | Readiness, context availability, map generations and normal completion |
| D01 | Take one small, familiar projectile hit, move out of danger, then repeat separately with a modest burst | Audited calculator, report and notification ordering |
| D02 | Take one nonlethal hit from a visible grenade/radial explosion, avoiding simultaneous projectiles | Whether the area candidate caller appears; exact enemy and attack |
| D03 | Obtain a familiar bleeding effect, retreat from other hazards and observe a few ticks | HP change pattern, raw flag changes, and whether any notification is emitted |
| D04 | Briefly touch familiar damaging ground, then step onto safe ground | Terrain caller, damage values, HP assignment timing |
| D05 | Repeat for another accessible dungeon hazard | Exact dungeon/tile/trap/attack name; whether it shares a known path |
| D06 | In Ocean Trench, observe breath depletion and, only with ample HP and a nearby escape, one HP-drain tick; return to oxygen or manually Nexus | Breath readings before and during the HP decrease |
| D07 | In Ice Citadel, observe the frostbite meter and, only with ample HP and a nearby escape, one HP-drain tick; return to warmth or manually Nexus | Frostbite readings and the damage path |
| D08 | In Nexus, change equipment affecting max HP, then restore it | Distinguish max-HP changes and HP clamping from incoming damage |
| D09 | After one isolated nonlethal hit, heal once without other hazards | Healing and repeated HP assignments do not become extra damage |
| D10 | Only after isolated tests: briefly combine two already observed nonlethal sources | Distinct callers, updates and raw context under overlap |

If access to a dungeon is inconvenient, skip it and report that it was not tested. Do not buy keys or
consume valuable items for this checklist. For bleeding, this round does not attempt to establish a
lethal floor: report how much HP was lost and when the effect ended.

After every run, manually return to Nexus if possible, wait five seconds, then quit Exalt normally.
Leave the monitor running until it reports completion. The launcher writes a bundle automatically once
the game process has exited. If the character dies, wait on the death screen for five seconds and quit.
If a request stalls, stop exposing the character to damage and quit normally.

## What to send back

Give the test ID, exact enemy/hazard/dungeon, observed result, and the printed session directory. Include
any active effects or equipment that might change damage/healing. A short recording showing the HUD
and hazard is useful when attacks overlap; it is optional. No account details are needed.

Each directory is unique:

```text
build/damage-diagnostic/data/sessions/D04-<UTC timestamp>-<unique suffix>/
|-- logs/guard-<pid>.tsv
|-- logs/hit-flight-<pid>.bin
`-- bundle/
    |-- guard-<pid>.tsv
    |-- hit-flight-<pid>.bin
    |-- manifest.json
    |-- report.json
    `-- report.md
```

If the monitor was closed early, quit the game and bundle the preserved text log manually:

```sh
python3 build/damage-diagnostic/damage_session.py \
  /absolute/path/to/session/logs/guard-12345.tsv \
  --test-id D04 --output /absolute/path/to/session/bundle
```

The command refuses an existing bundle and a live session process. Text and flight files are copied,
not moved. A manifest fingerprints the raw files and records the diagnostic's expected/recorded game
build identity. The binary flight recorder retains only its latest 8,192 events and cannot replace a
complete trace. After a crash, send the raw session even if bundling reports a problem.

## Reading the result

- **observed:** complete usable observations; no automatic escape was evaluated.
- **escaped:** a local automatic request was followed by an observed Nexus arrival in a new generation.
- **failed:** a death-screen entry was observed, including one recovered from the binary tail.
- **inconclusive:** missing readiness/build identity, incomplete trace, event loss, off-main coverage
  gaps, or an automatic request without a later Nexus arrival.

Every report keeps `lethal_prevention_proven: false`. A test label, nearby notification, full frostbite
meter or empty breath meter is not itself proof of damage cause. Server HP assignments cannot identify
the processed hit reports. Review raw events before deciding the next intervention.

## Later: existing projectile intervention control

After D00/D01 observation is reviewed, the existing projectile protection can be tested explicitly:

```sh
'build/damage-diagnostic/Start Hit Diagnostic.command' --intervene
```

Use test ID X01 and a disposable character. This enables the existing audited projectile escape only.
New terrain, AOE, bleeding, oxygen and frostbite protection has not been implemented. Double-clicking
the launcher again returns to observation mode. Restarting the game normally removes the diagnostic.
