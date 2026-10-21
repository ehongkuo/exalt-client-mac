# Status damage and HP reconciliation audit

## Current policy: bounded recent-hit reconciliation (version 7)

The beach death trace demonstrates that clearing pending damage on every HP update can miss a
lethal prediction. Version 7 retains recent timestamped estimates in a fixed ledger, credits observed
HP decreases against the oldest estimates, and retires old estimates only on fresh observations
beyond an adaptive timing window. Healing changes the baseline rather than accumulating synthetic
healing credits. This is conservative inference, not individual report acknowledgement; it may still
escape early, and sufficiently delayed processing can exceed the window. Full behavior and limits
are described in [Nexus integration](nexus-on-death.md) and the [incident audit](nexus-failure-2026-10-20.md).

## Previous authoritative HP-window policy (version 6)

The live installed version-2 policy produced a false projectile escape at event 11005 in
`guard-93129.tsv`: HP 1206/1206, incoming calculated damage 110, retained damage 1043, projected HP
-108. Before the final three 110 hits, its old retained damage was 713 and projected bound 222,
even as authoritative HP recovered through 1169, 1174, 1189, 1204 and 1206. The 330-damage burst
was nonlethal at actual HP 1206. No environmental trigger or synthetic-HP override caused this event.

Version 3 restores the prior client's authoritative-window behavior: every incoming HP assignment
clears the prior pending budget and adopts that HP baseline, including unchanged or higher values.
Unchanged values can include damage offset by healing. Only audited hits between updates accumulate;
all three local damage paths share the same budget. Already-confirmed escape latches survive updates.
A failed request can retry after a positive update. Version 6 retains this HP-window policy. Meter-limit escapes and incoming-HP escape attempts are removed.

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

## Client-side boundary audit

The working scope assumes damage is computed locally and then reported. The implementation does
not attempt to rescue received lethal HP/death messages. The former incoming-HP last-chance request,
its retry behavior, log row and test-only caller override are removed. Incoming HP still rebases the
prediction budget and never clears an already confirmed escape latch.

Native evidence is checked against GameAssembly SHA-256
`ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`. The archived current metadata dump
maps the exact methods/fields. The extended scan resolves ambiguities from the earlier bounded audit:

- The shared damage notification is virtual slot 118. Eleven matching immediate virtual-call byte
  candidates exist in the text segment. Metadata/disassembly resolves three local damage producers
  (projectile `0x653bca`, ground `0x196ed5f`, AOE `0x183f7b8`), two incoming notification handlers, and six
  unrelated guild UI/equipment calls through different receiver types. The three local routes are
  already intercepted. Raw displacement and direct-call searches are not proof against all indirect
  dispatch or future inlining.
- Sixteen direct HP-setter call candidates were instruction-verified. Twelve are player-tooltip clone
  updates. The two player-local calls writing constants 1 and 0 are static constructors
  `FKALGHJIADI.HANNHIFHJEA` (`0x1975590`) and `CEDFOHGDPEE` (`0x19775e0`), not damage loops. The remaining
  two are the known incoming stat and incoming death handlers.
- The HP setter writes entity `+0x20c` at `0x1af1674`, then dispatches virtual slot 135. Metadata resolves
  the controlled-player override to `FKALGHJIADI.JEIJMMIOFNK` (`0x196d6a0`); it updates presentation/state
  after assignment. The new local hatch runs before the write and callback.
- The normal Nexus path rejects nonpositive HP and a set dead flag. Therefore the local lethal-write
  hatch must request while current HP is still positive, and skip the local write only after the
  existing local Nexusing confirmation succeeds.

The new `guard_local_hp_blocked` row records current HP, computed local value and caller. A positive
nonlethal local setter is not charged again: its underlying hit may already be in the common damage
budget. Incoming contexts/caller, incoming death caller, non-controlled entities and off-main writes
are not reclassified as local damage. Existing atomic suppression applies to covered off-main damage
only after an escape latch has already been published.

Regression fixtures cover local zero/negative HP cancellation; following local HP reductions and
covered reports; healing/nonlethal writes; incoming state while latched; dry run/disabled/failure;
retry after a failed hit request; already nonpositive state; and incoming/death origin exclusion.

No separate local frostbite or suffocation producer has been located. A producer that uses the shared
guarded routes benefits from them, but there is no evidence yet that every status/environmental source
routes through those functions. Direct writes bypassing both the setter and notification/calculator
hooks, or different outgoing report routines, are not proven covered. This remains an explicit local
routing task; no server-computation workaround is retained or proposed here.


## F01: targeted Citadel frostbite trace (2026-10-17)

Session `F01-20261017T065644Z-EynDnj`, raw `guard-42155.tsv` SHA-256
`af1adc219c44d6192f555fb0d938aeca85abb3d928471fbeb7622d4e85a91078`, matches the
GameAssembly fingerprint above. The capture contains 2893 events; the text and flight recorder
report zero dropped/overwritten/incomplete events, zero observed off-main calls and zero trace-limit
skips. Normal completion was not logged, so the automatic whole-session outcome remains
inconclusive. The retained hazard interval is still usable for the following bounded routing findings;
no repeat exposure is needed merely to obtain an orderly-exit marker.

- 47 net HP decreases occurred with frostbite 100, over 12.116510 seconds. Each decreased HP by
  10–13; their median spacing was 200.1715 ms. The first followed the recorded full meter by
  176.973 ms. Minimum HP after these decreases was 1042 (maximum 1090); healing occurred between
  some decreases, so their summed 557 HP is not a net session loss or a direct per-proc damage claim.
- All 47 decreased through incoming stat assignment (`update_source=1`, HP setter return
  `0x184c115`), with identical eight-frame GameAssembly stack observations. No hooked damage
  calculator, damage notification or projectile-report events appeared anywhere in this capture.
- The observed chain, from outer caller toward the HP write, is
  `UnityThread.Update` → `SocketManager.GotMessageHandler` →
  `HJMBOMEHGDJ.LDKKFMBNOCN` → `DBCEHNAEDCH` → `NAMGODOEDBO` → the HP setter.
  Recorded return addresses are `0x1c29347`, `0x199f00a`, `0xad133`, `0x18498e7`,
  `0x1849c85`, `0x184c115` (plus two outer Unity invocation frames).
  Metadata and native instruction boundaries verify the handler call at `0x18498e2`, stat dispatcher
  call at `0x1849c80`, and HP setter call at `0x184c110`. At that last call, the already decoded
  integer is moved into the setter argument, with no damage calculation at that boundary.
- 176 outgoing sends were observed near the meter limit: 82 `AJCKDMICJJA` from `0x1850690`,
  69 `FKGDHGJDNAO` from `0x184a2fd`, 24 `LHNBLJLKPMJ` from `0x18543ac`, and one
  `IKFIMIBKGEP` during the manual Nexus call. Metadata shows the first/last have no declared
  payload fields; the second has integer/time and position-sample-list fields; the third's native
  ToString literal identifies it as `ShootAckCounter`. These observations do not identify a local
  frostbite damage producer or damage-report message. Payloads were not captured.
- A manual Nexus call was recorded at HP 1077, with a later Nexus map observed about 2.005 seconds
  afterward. No death-screen event was observed. This was a nonlethal routing test, not a lethal
  cancellation test; oxygen was not established by it.

**Coverage finding:** this capture does not support treating frostbite as an existing guarded
projectile/ground/AOE producer. Its observed HP reduction enters through received state, which the
current local-only hatch deliberately excludes. Therefore frostbite lethal protection remains
unverified and the observed route is not protected by that hatch. The trace does not prove absence
of arbitrary earlier inline calculations, other transports, or unobserved producer functions, nor
server-side lethal ordering. The client-first assumption cannot substitute for a located producer.
No speculative incoming-state rescue or meter-triggered escape was added in response to this test.


## F01 backward trace: decoded HP and meter consumers

Further native inspection locates where the received HP integer originates, before the main-thread
handler. All addresses below match the same pinned GameAssembly and archived metadata as F01.

| Stage | Native evidence | Meaning |
|---|---|---|
| Tick/status packet decoding | `BJEENKGELLO.JEFJDICFNBA`, `0x1950d60`; packet holds `List<BOEANEODCOA>` at `+0x20` | Decodes a batch of entity status records |
| Entity status decoding | `BOEANEODCOA.JEFJDICFNBA`, `0x22599b0`; record holds `List<CGOECEPGBBG>` at `+0x20` | Decodes each entity's stat list |
| Stat decoding | `CGOECEPGBBG.JEFJDICFNBA`, `0x1101e50` | Reads byte stat ID into `+0x10`; integer stat value into `+0x14` |
| Integer origin | Call `0x1101f3e` → `OODFCLBKDJJ.FKPJFEHLIDH` at `0x1fecda0`, then store at `0x1101f43` | Signed variable-length integer decoding from `BHFDLBOGHIB` byte reader, not subtraction from current player HP |
| Main-thread stat dispatch | `0x184b1be`: load stat `+0x14` into `%r14d`; `0x184b1c2`: load stat ID `+0x10` | Selects HP, breath, frostbite or another stat |
| HP assignment | `0x184c10b`: move `%r14d` to setter argument; `0x184c110`: call `0x1af1670` | Applies the decoded HP value; no HP subtraction at this boundary |

At stat ID 1 (HP), the decoder's numeric branch reads the integer into the same `+0x14` field consumed
by the HP dispatch. Its reader uses a six-bit initial magnitude, sign bit and seven-bit continuation
chunks. This is serialization arithmetic; it has no current-player HP argument. The earliest confirmed
entry of the HP value is the stat parser's store at `0x1101f43`, already within received-state decoding.
It is earlier than the setter, but is not an established local pre-report damage producer.

The meter branch was followed independently:

- Frostbite `+0x530` and breath `+0x52c` are incoming-backed player fields. Direct relative call/jump
  scans for their getter/setter aliases and frostbite-full predicate found two instruction-verified
  references: incoming dispatch calls frostbite setter `0x1979920` at `0x184c7da` and breath setter
  `0x196c150` at `0x184cb6f`. Aliases/getters may be unused or inlined; that result alone cannot exclude
  local consumers.
- To examine inlining, a whole-text displacement scan found 605 raw `0x52c`/`0x530` candidates;
  551 were matched to instruction extents within the audit's method-span limit. Those offsets also
  occur in unrelated types/vtables, so this is a candidate search, not 605 player accesses.
- `CharacterUIManager.Update` compares the actual player frostbite field to 100 at `0xbbc5ab` and
  tail-calls `BlizzardController.BumpIntensity` at `0xbbc5e5`. That destination is only
  `movl $0x3ecccccd, 0x44(%rdi)` plus return: it sets float intensity **0.4**, not HP. Inspection of
  `BlizzardController.LateUpdate` resolves its direct calls to particle size, transforms, camera,
  time and overlay alpha operations. The meter getters and bars likewise provide/display values.
- The inspected `MBPKMLMIJNI` meter branches call `OverlayController.ShowUnderwaterOverlay`,
  `ShowFrostOverlay`, `HideOverlay` and `UpdateAlpha`. They are presentation leads, not established
  damage producers. Some aliases use different thresholds; none should be selected as a protection
  boundary from a numeric threshold alone.

Rechecked instruction bytes: `0x1101f3e=e85daeee00894314`,
`0x184b1be=458b7714410fb65f10`, `0x184c10b=4489f631d2e85b552a00`,
`0x112c584=c74744cdcccc3e`. Detailed candidate instructions and verified direct references are retained
in ignored `build/damage-native-audit/f01-producer-backtrack.json`.

**Result:** a concrete earlier received-value boundary is located, and the apparent full-meter damage
lead resolves to graphics. A local frostbite subtraction/report producer is still not established.
Hooking the decoder or blocking its write would change received-state handling, which the current
local-only policy excludes; it would not demonstrate cancellation of the damage before the packet
was sent. No runtime hooks, meter escapes, forecasts, or incoming-state rescue behavior were added.
The F01 runtime evidence is specific to frostbite; the stat wiring does not prove oxygen damage shares
its complete producer path. No additional live exposure is requested by this static audit.
