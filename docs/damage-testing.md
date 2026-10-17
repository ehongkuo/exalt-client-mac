# Damage-path verification

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

## Minimum check for the expanded protection

Automated fixtures exercise damage accumulation, fatal crossings, repeated hits, successful and failed
Nexus requests, Dry Run, disabled protection, and matching versus unrelated sockets/messages.
They cannot demonstrate that the live server accepted an escape or that a named game attack uses a
particular native path. One example per distinct interception boundary is sufficient for this check.

1. Quit the game, double-click `Verify Damage Protection.command` in the built package, then enter Nexus and wait for readiness.
2. At full health with a disposable character, take one small familiar projectile hit (X01).
3. In separate sessions, take one small damaging-ground tick (X02), then one small radius/AOE hit (X03).
4. After each escape, wait five seconds in Nexus and quit normally. Send the three printed session directories
   and the enemy or hazard names. The launcher bundles the logs automatically.

Verification mode calculates against **1 HP without changing actual game HP**, so the first positive
hit on a protected path should trigger the real escape and report cancellation while the character
still has ample actual health. Automated tests cover the real lethal arithmetic. This checks live
wiring and Nexus arrival without deliberately approaching death. It cannot prove server-side lethal survival.

Do not use a valuable character to establish an unverified escape. Stop after a refused hook, failed
request, or missing Nexus transition. These are validation attempts, not a guarantee of survival.
There is no need to repeat different enemies or ground tiles once their traces show the same boundary.
A report containing only incoming HP updates does not demonstrate that a new damage source is protected.

The reason for three examples is native ordering, not the number of damage sources:

| Family | Interception and cancellation |
|---|---|
| Projectile | Calculator return `0x6538a2`, existing player-hit report hook |
| Ground | Notification return `0x196ed65`, report helper tail-call retains return `0x196ed90` |
| Radius/AOE | Notification return `0x183f7be`, outgoing report return `0x183f880` |

All three use the same pending-damage policy and Nexus request. Different native call sites and report
orders require separate wiring; fixture success cannot establish the live attack identity or server result.
Bleeding alone is nonlethal and D03 is no longer required for lethal-source coverage. Environmental guards escape at full frostbite or exhausted oxygen after positive breath was observed. Citadel observation is recorded; oxygen and the newly added live escape remain unverified. The historical investigation checklist remains below; there is no reason to test every dungeon before reviewing the implemented protection.

## Optional investigation: one source per session

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

## Launch verification explicitly

```sh
open 'build/damage-diagnostic/Verify Damage Protection.command'
```

This enables audited projectile, ground and radius/AOE intervention using the diagnostic 1-HP prediction.
Use `--intervene` only for ordinary real-HP prediction. The production client always uses real HP. Double-clicking the launcher uses
observation mode. Restarting the game normally removes the diagnostic. The new code is also compiled
into the integrated client, but building this diagnostic does not replace the installed client app.
