# Damage-path diagnostic

The diagnostic records player HP, incoming updates, projectile calculations, notification callers,
the first two condition-mask words, breath and frostbite meters, Nexus requests, map transitions and death-screen events.
It includes audited projectile, ground and radius/AOE intervention. It also proactively escapes at frostbite >= 100 or exhausted oxygen after observing positive breath in the same player/map/connection scope. This does not cancel server damage; the oxygen trigger is not live-verified. Bleeding alone is nonlethal. Use `--verify` to check an escape on a small hit using a synthetic 1-HP
prediction; actual game HP is unchanged. Start with the [in-game checklist](../docs/damage-testing.md) and
[damage-source map](../docs/damage-sources.md).

## Build and run

Run build commands from the repository root. In a built package, open `Start Hit Diagnostic.command`
in that folder; no terminal build command is needed.

```sh
sh probe/build-probe.sh
open 'build/damage-diagnostic/Start Hit Diagnostic.command'
```

Double-clicking the launcher starts observation only. Auto-potions, automatic Nexus and party Join
are disabled. Use a disposable character and escape manually. The signed diagnostic and logs stay
under this checkout's `build/damage-diagnostic/`; the installed app is not replaced.

Quit the game and DECA launcher before starting. Enter a checklist test ID, click Play, enter Nexus
and wait for readiness. Optional missing context fields are shown as unavailable. Unknown game builds
and mismatched hook prefixes are refused. Restarting the game normally removes the injected hooks.

After each isolated nonlethal test, manually Nexus, wait five seconds and quit normally. The launcher
creates a session bundle containing the raw text/flight logs, fingerprints and evidence report.
No account credentials or packet payloads are collected by these additions.

For manual bundling after a crash or closed monitor, run `damage_session.py LOG --test-id D04 --output NEW_DIRECTORY`.
It refuses a live session process and an existing output directory. Send the raw session if bundling fails.

## Existing intervention control

Only after the observation control is reviewed:

```sh
'build/damage-diagnostic/Start Hit Diagnostic.command' --intervene
```

This explicitly enables the audited projectile, ground and radius/AOE intervention. It estimates possible lethal damage,
requests the normal Nexus function before the fatal hit report, and suppresses the audited projectile
path only after confirming the local Nexusing flag. That flag does not establish server acceptance.

```text
projected HP = current observed HP - audited damage since the last incoming HP assignment
request Nexus when projected HP <= 0
```

Each incoming authoritative HP assignment starts a fresh prediction window, including unchanged
or higher HP (damage may be offset by healing). This restores the previously working client's
baseline behavior and prevents old combat damage from causing full-health escapes. Hits between
updates still accumulate across projectile, ground and area paths. An HP update is not a per-report
acknowledgement, so late/in-flight report ordering remains a limitation. A positive update rearms a
failed request; an already confirmed escape remains latched. See the [audit](../docs/damage-status-audit.md).

## Trace and analysis

The existing version-4 flight layout remains readable. Phase 29 records optional raw context with an
availability mask. New calculator observations distinguish the audited caller from unknown callers;
unknown calls never enter prediction or shadow budgets. No opaque native argument is inspected.
See [the native map](../docs/damage-sources.md) for the full encoding and evidence locations.

```sh
python3 probe/map_damage.py
python3 probe/map_damage.py --dump /absolute/path/to/dump.cs
python3 probe/analyze.py /absolute/path/to/guard-12345.tsv
python3 probe/analyze.py /absolute/path/to/hit-flight-12345.bin
```

The flight recorder keeps the latest 8,192 completed events. Its recovery reports overwritten/incomplete
slots separately. It is a tail, not a complete session; it is never silently merged with the text trace.
Off-main calls are counted but not individually traced. Missed samples, unreadable context, or a lost
window prevent claims of complete coverage.

`damage_session.py` reports observed, escaped, failed or inconclusive. HP loss is grouped by observed
setter/notification/sampling boundary, without inferring the cause from a test label or nearby event.
Native caller labels require the recorded build fingerprint. A death event overrides a successful
escape, including deaths found in the binary tail. Every report says lethal prevention is unproven.

The binary fingerprint, 15 mapped method entries, five notification dispatch sites, four
field declarations (including the retained legacy sprite-key identity) and selected instruction evidence live in `damage_paths.json`. `map_damage.py`
verifies those facts without changing runtime approval. Projectile, terrain and AOE escape wiring has live evidence; Citadel observations establish meter/HP-update timing. See VALIDATION.md for remaining limits.
