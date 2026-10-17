# Status damage and HP reconciliation audit

## Current policy: authoritative HP windows (version 3)

The live installed version-2 policy produced a false projectile escape at event 11005 in
`guard-93129.tsv`: HP 1206/1206, incoming calculated damage 110, retained damage 1043, projected HP
-108. Before the final three 110 hits, its old retained damage was 713 and projected bound 222,
even as authoritative HP recovered through 1169, 1174, 1189, 1204 and 1206. The 330-damage burst
was nonlethal at actual HP 1206. No environmental trigger or synthetic-HP override caused this event.

Version 3 restores the prior client's authoritative-window behavior: every incoming HP assignment
clears the prior pending budget and adopts that HP baseline, including unchanged or higher values.
Unchanged values can include damage offset by healing. Only audited hits between updates accumulate;
all three local damage paths share the same budget. Already-confirmed escape latches survive updates.
A failed request can retry after a positive update. Environmental full-meter guards are unchanged.

This is a deliberate correction of version 2, not proof that incoming HP acknowledges particular
reports. Clearing a window can omit still-in-flight reports; the client/server ordering limitation
remains. The prior conservative approach did not establish universal safety and caused confirmed
full-health false positives. The native policy regression reproduces its -108 bound and now yields
876 HP after the three 110 hits; an integration fixture verifies no automatic Nexus after recovery.

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
