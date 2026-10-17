# Status damage and HP reconciliation audit

## Current policy: authoritative HP windows (version 5)

The live installed version-2 policy produced a false projectile escape at event 11005 in
`guard-93129.tsv`: HP 1206/1206, incoming calculated damage 110, retained damage 1043, projected HP
-108. Before the final three 110 hits, its old retained damage was 713 and projected bound 222,
even as authoritative HP recovered through 1169, 1174, 1189, 1204 and 1206. The 330-damage burst
was nonlethal at actual HP 1206. No environmental trigger or synthetic-HP override caused this event.

Version 3 restores the prior client's authoritative-window behavior: every incoming HP assignment
clears the prior pending budget and adopts that HP baseline, including unchanged or higher values.
Unchanged values can include damage offset by healing. Only audited hits between updates accumulate;
all three local damage paths share the same budget. Already-confirmed escape latches survive updates.
A failed request can retry after a positive update. Version 4 retains this HP-window policy and removes unconditional environmental meter escapes.

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

No source-specific damage cancellation is established for bleeding, suffocation or frostbite. Meter saturation is not a lethal input and does not request escape.
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

## Citadel observation and removal of premature meter escapes

Session `D06-20261017T000048Z-AQqfYg` was a Citadel run despite the D06 label; source identification
comes from the user's report and frostbite readings, not the label. Its raw log SHA-256 is
`edea76561d645b70442af1fd9f47ec6322ce80e949f080337640c91e3bf8501a`, matching the bundle manifest.
All 57 recorded HP decreases came through incoming HP assignments at `0x184c115`; 29 had frostbite
100 or 101. Mixed attacks later in the run prevent attributing every decrease to frostbite.

At event 347389 (`531416446167000 ns`), frostbite was 100, breath -1, HP 740/740, conditions zero.
The first following recorded decrease, event 347508 (`531416624203000 ns`), assigned HP 726 through
the incoming stat path, about 178 ms later. This directly demonstrates a full meter with positive HP
and a subsequent nonlethal decrease; the meter limit itself is not an appropriate lethal trigger.
The recording ends in Nexus at positive HP. The bundle remains inconclusive for whole-session
completion because the diagnostic lacks an exit completion marker; raw evidence was not rewritten.

The former implementation escaped at frostbite >= 100 or exhausted oxygen regardless of HP. That
behavior conflicted with lethal-only protection and has been removed, including production meter
lookups, retry state and meter-only requests. Diagnostic meter observation and per-tick scope/latch
cleanup remain. Regression fixtures cover meter saturation without escape, a nonlethal incoming HP
update followed by a correctly intercepted lethal local hit, and incoming zero HP that is not hidden
or falsely reported as prevented. These fixtures do not establish cancellable environmental DOT.

The installed binary's native damage map still verifies. HP, breath and frostbite values enter through
the incoming stat dispatch; no local environmental damage/report boundary or server request for a
client-provided alive/dead status has been established by this audit. Incoming state must not be
confused with a client-authoritative health response. Oxygen routing and lethal frostbite/suffocation
cancellation remain unresolved.

## Nonpositive HP and death: native trace

Rechecked against installed GameAssembly SHA-256
`ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`.
`probe/map_damage.py` validates the added instruction evidence in `probe/damage_paths.json`.
This is a static client trace plus the existing nonlethal Citadel trace, not a live lethal-hazard test.

| Boundary | Native behavior | Protection behavior |
|---|---|---|
| Incoming breath/frostbite stats | Calls setters at `0x184cb6f` / `0x184c7da`, storing `+0x52c` / `+0x530` | Meters alone never request escape |
| Incoming HP stat 1 | Calls the HP setter at `0x184c110`, returns `0x184c115` | Version 5 attempts normal Nexus first if the controlled player's current HP is positive and supplied HP is <= 0 |
| HP setter `0x1af1670` | Writes supplied integer to entity `+0x20c` at `0x1af1674`, then tail-dispatches the virtual callback at class slot `+0x9a8` | Supplied HP is still passed to the original setter unchanged |
| Normal Nexus `0x1841500` | At `0x1841731`, nonpositive player HP branches to return; helper `0x1841830` also refuses when the dead flag `+0x39` is set | The new request runs before the HP write; failed/unconfirmed calls do not activate suppression |
| Nexus send helper | Calls `0x199e040` at `0x18418ab`; that writes SocketManager Nexusing `+0x40 = 1`. Tail-calls `SendMessage` at `0x1841905` | Existing latch is published only after that local flag is confirmed; unrelated/Nexus messages still pass |
| Incoming death handler `0x1840c60` | Sets player `+0x39 = 1` at `0x1840e57`, sets HP 0 at `0x1840e5f`, then calls `ShowDeathScreenPanel` at `0x1840f1c` | This separate handler and the death screen are not hidden or treated as a cancellable local hit |

The incoming HP-stat path and incoming death-message path are separate; the trace does not establish
which arrives first for a lethal environmental event. The HP setter's type-specific virtual callback
is not fully resolved here. A raw relative-call scan found 16 candidate direct HP-setter callers,
confirmed as instructions; no direct caller of ShowDeathScreenPanel besides `0x1840f1c` was found.
This does not rule out indirect calls. The other player-local setter calls include constant 1 and 0,
not an identified environmental subtraction loop; their source mechanics remain unassigned.

Previously the shared HP hook observed nonpositive incoming assignments but did not request escape.
Version 5 closes that client-side omission without changing positive assignments or the HP-window
policy. It requires a controlled player, known validated map/connection, active toggle, main thread,
audited return address and incoming update context. Armed-off remains dry run. A terminal assignment
can make one final request after an earlier failed hit request. Already confirmed latches do not issue
duplicate requests. Already nonpositive HP and unmapped direct setter calls do not invent a revival.

The new `guard_incoming_lethal_hp` row records supplied HP, HP before assignment, local Nexusing result,
and `server_prevention_proven=0`. Automated fixtures verify request-before-write, zero and negative HP,
following covered-report suppression, disabled/dry-run modes, rejection/exception, failed-request retry,
and preservation of received terminal HP and subsequent death messages. They verify client ordering,
not that a server already reporting lethal HP accepts Nexus or cancels environmental damage. There is
still no proof of a cancellable frostbite/suffocation damage report before the incoming assignment.
