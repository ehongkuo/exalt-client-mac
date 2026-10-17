# Status damage and HP reconciliation audit

This audit applies to the fingerprint in `probe/damage_paths.json`. The native map verifies the
installed binary, matching metadata identities, jump-table entries and instruction ranges.

## Incoming state paths

`HJMBOMEHGDJ.NAMGODOEDBO` (`0x184ae90`) reads each stat's byte identifier and integer value at
`0x184b1be`, rotates the identifier by 128, and dispatches through the signed-offset table at
`0x184d67c`.

| Stat | Handler | Result |
|---|---|---|
| 1 | `0x184c104`, call `0x184c110` | HP assignment `LKHPPBEGNOM.NIDPCHCNDLJ` at `0x1af1670` |
| 29 | `0x184c517` | Condition mask word 0; controlled player routes through `KFCLEPFKFAL` at `0x1964c30` |
| 69 | `0x184ca58` | Condition mask word 1 through the same controlled-player setter |
| 64 | `0x184cb5d`, call `0x184cb6f` | Breath setter at `0x196c150`, store player `+0x52c` |
| 150 | `0x184c7c8`, call `0x184c7da` | Frostbite setter at `0x1979920`, store player `+0x530` |

The two base mask setters store Int32 values at array `+0x20` / `+0x24`, through the living entity's
`COHCKAPOLCA` Int32 array at `+0x250`. Condition predicates read those same words. This establishes
storage and update routing; individual condition names, bleeding's lethal floor, and DOT timing are
not decoded by this audit. The diagnostic records the first two words with a length check.

The direct HP displacement search in the audited player/living/base entity and connection classes
found the known setter, initializers, reads/comparisons and the base notification's terminal zero
store. It did not find a local HP subtraction loop for bleeding, suffocation or frostbite. This bounded
search does not rule out other classes, indirect writes, inlining or future game changes.

The two incoming damage notification sites (`0x18407cf` and `0x18413af`) load the amount from message
`+0x20` and the flag passed as notification argument 4 from message `+0x24`. They return after the
notification without the separate outgoing damage report found in the ground/area paths. The base
notification can set HP to zero when that flag is set. This is received state, not an established
local calculation/report boundary. Suppressing it would not establish that the server reversed death.

No source-specific damage cancellation is established for bleeding, suffocation or frostbite. The later proactive meter guard described below is separate from cancellation.
The source of their HP changes remains unresolved. A labeled live trace may narrow that routing, but
testing every dungeon or hazard is not justified by the current evidence.

## Corrected condition provenance

The original phase-29 diagnostic read `KJMONHENJEN.JJDEDAFLGHC` at `+0xf8`. Native code at
`0x223362f` copies that value from `IPKAMAAPAGA.HFEABLMKNCG` at `+0x30` during sprite/texture updates.
It is not a condition mask. Previous raw values must not be interpreted as bleeding or other effects.

Corrected phase-29 events use `flag2=1`, and pack Int32 mask words 0 and 1 into the existing 64-bit
numeric field. Null or short arrays are unavailable. Older events remain readable as
`legacy_sprite_key_raw`, with `conditions_raw` unset. No old logs or report artifacts are rewritten.
This correction does not invalidate X01-X03's escape evidence, which uses native caller identities,
request results, report suppression and map transitions rather than these raw values.

## Conservative policy version 2

The previous policy erased pending damage on every incoming HP assignment, including unchanged HP.
There is no per-hit acknowledgement in that assignment. The following native fixture demonstrates
why a shared budget must survive mixed damage and delayed stats:

| Step | Observed HP | Retained damage | Conservative bound |
|---|---:|---:|---:|
| Projectile 50 | 200 | 50 | 150 |
| Repeated server HP 200 | 200 | 50 | 150 |
| Ground 60 | 200 | 110 | 90 |
| Server HP 180 of unknown attribution | 180 | 110 | 70 |
| Area 70 | 180 | 180 | 0: request Nexus |

Previously, the repeated update erased the projectile and the later update erased the ground damage,
so the area hit alone predicted 110 HP and did not request Nexus.

Version 2 retains uncertain damage until confirmed Nexus arrival or validated player/connection/map
replacement. Each damage subtracts from the prior bound; an HP update can only lower that bound.
Healing and higher stale assignments do not raise it. This is deliberately pessimistic: it can count
already-applied damage twice and Nexus early during long fights, even after healing to full HP.
It must not be advertised as exact remaining HP or as acknowledgement-aware reconciliation.

A still-positive incoming HP assignment can itself reveal a nonpositive bound while prior local damage
is retained. That requests Nexus immediately after recording the assignment, without changing or
suppressing the authoritative HP value. With no pending local damage, a positive HP assignment alone
does not trigger this path; server-only DOT is still not covered universally. Already-zero HP is not
represented as a preventable escape.

Failed requests preserve original damage and continue accumulating it. Another positive incoming HP
update permits a retry, while multiple hits within one update do not repeatedly request Nexus. Once
Nexusing is confirmed, no update or setting change clears the escape latch. Integer bounds saturate
safely and overflow/invalid damage is rejected.

These policy changes have automated coverage; the earlier X01-X03 tests validate the underlying live
hook wiring, not the new policy's false-positive rate in extended gameplay. No additional in-game test
is required to reproduce the arithmetic regression above. The installed app is not replaced by this
source change or the standalone package build.

## Citadel observation and proactive environmental guard

Session `D06-20261017T000048Z-AQqfYg` was a Citadel run despite the D06 label; source identification
comes from the user's report and frostbite readings, not the label. Its raw log SHA-256 is
`edea76561d645b70442af1fd9f47ec6322ce80e949f080337640c91e3bf8501a`, matching the bundle manifest.
All 57 recorded HP decreases came through incoming HP assignments at `0x184c115`; 29 had frostbite
100 or 101. Mixed attacks later in the run prevent attributing every decrease to frostbite.

At event 347389 (`531416446167000 ns`), frostbite was 100, breath -1, HP 740/740, conditions zero.
The first following recorded decrease, event 347508 (`531416624203000 ns`), assigned HP 726 through
the incoming stat path, about 178 ms later. This is an observed opportunity to request Nexus at the
meter limit; it is not evidence of sufficient time for server acceptance under every connection.
The recording ends in Nexus at positive HP. The bundle remains inconclusive for whole-session
completion because the diagnostic lacks an exit completion marker; raw evidence was not rewritten.

The implementation now samples the mapped meters on the existing main-thread guard tick and uses
the validated normal Nexus request and local blocking latch. Frostbite >= 100 triggers regardless
of HP. Oxygen == 0 triggers only after positive breath was observed in the same scope. No server HP
assignment is suppressed. These are proactive hazard escapes, not newly discovered cancellable DOT
functions. Oxygen routing and live environmental escape remain unverified; no OT run is required
to prepare this MR, and no shared server-side damage function is claimed.
