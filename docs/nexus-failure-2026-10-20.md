# Advanced Kogbold death investigation — 2026-10-20

Status: the beach missed-prediction sequence is reproduced; version 7 adds bounded reconciliation.
Original boss attribution remains unresolved. Timing reconciliation is heuristic, not a survival guarantee.

## Preserved incident

The user identified the Advanced Kogbold boss. `guard-15108.tsv` records the same map.
At 18:17:13.236 Pacific, sampled HP changed from 108 to 0, with max HP 1228.
Protection was armed and enabled; there were no request events or suppressed reports in the session.
The installed guard matched the previously verified build, and GameAssembly matched the active profile.
No observed hook queue drops or off-main calls were reported. This does not prove every damage
source entered a hook.

The last received-HP rebase event was 123 ms before the zero-HP sample. The relevant HP history was
421 → 168 → 171 → 108 → 0. The rebase record discarded the previous pending budget, and production
logging discarded ordinary calculation, notification and setter records. Consequently the original
evidence cannot distinguish an underprediction, a reset between unacknowledged hits, a skipped
intervention prerequisite, or a different damage route. The game logs do not identify the attack.

Local snapshots are in ignored `build/death-investigation-2026-10-20/`; they are not committed.
The guard snapshot SHA-256 is `b546a3c7339581d800c61ef76f41ef559e847d9c37305985373b20783b3c78ef`.
The GameAssembly SHA-256 is `ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`.

## Newly checked native report boundary

The projectile collision calls the guarded calculator at `0x65389d`, then the player-hit report
at `0x65394b`, then the shared notification at `0x653bca`. Its normal path is already guarded
before reporting. This static ordering alone does not establish which path killed the player.

A fresh direct-call scan, with each candidate decoded from its containing method entry, found
only the known calculator caller. Direct notification calls resolved to the inheritance chain
`0x1970b01 → 0x2207810` and `0x2207837 → 0x1af6140`; no additional direct caller of the controlled
override was found. This bounds direct calls only, not virtual dispatch, inlining or indirect writes.

The report at `0x1853fb0` obtains `HLDKJECFCAC`, calls its initializer at `0x7e2830` with the bullet
and owner IDs, then tail-calls `SocketManager.SendMessage` at `0x1854085`. The initializer stores
only these fields at `+0x1c` and `+0x20`. The serializer at `0x7e2480` encodes them as UInt16 and
Int32; it does not serialize player HP or damage. These instructions are now checked by
`probe/map_damage.py`. No assertion that the server receives a client-computed alive HP value
is supported by this report path. Server implementation was not inspected.

The existing shared notification can directly store terminal zero HP at `0x1af6232`, bypassing
the HP setter. Received notifications can reach it. The original log does not establish that
this was the terminal route in this incident.

## Bounded incident history

Production keeps 64 `ProbeEvent` records (8192 bytes) in memory, replacing old entries in place.
It records controlled-player reports, notifications and returns, HP assignments and returns,
calculator entries/returns including unaudited callers, prediction decisions, and Nexus/death entries.
The source context and pending/projected HP are captured before incoming HP clears the budget.
Eligibility is recorded on entry snapshots; an unaudited calculation remains observation-only.

The existing background queue receives the history on the first observed terminal setter,
notification return, sampled HP, or death-screen entry per player/map scope. A manual Nexus or a
confirmed automatic Nexus also saves one escape history per scope. Collection continues after
that escape request in case a death follows. At most two dumps, each at most 65 records, are queued
per scope. Ordinary hits produce no new per-hit file records, allocations, stack walks or payload dumps.
The fallback reuses HP already read by the normal guard callback; it adds no ordinary-frame HP reads.

Historical phases are `100 + original phase`, so they are not replayed as actual new damage events.
Their `work_ns` and `projectile` fields are signed pending damage and projected HP aliases.
Entry `valid` is an eligibility mask: bits 1/2/4/8 mean guard-ready/map-ready/map-known/validated-player;
16/32/64/128 mean death-enabled/intervention-enabled/outside-Nexus/policy-bound-to-player.
These observations describe the entry, before any subsequent policy synchronization.
Phase 199 marks the end: `value` is trigger phase, `owner` expected history count, and flags 0/1/2/3
are armed/blocking/enabled/history-dropped. `probe/analyze.py` exposes a separate `incidents` section,
checks completeness, and excludes these budget aliases from snapshot timing statistics.

This is main-thread history, not an exhaustive instruction trace. It can miss old overwritten events,
unhooked transient writes, off-main activity, queue overflow or an abrupt exit before the background
drain. A terminal sample proves observation only, not the original producer or a reversible death.

## Next capture

Use the tracing build, take a few ordinary boss hits, and manually Nexus while HP is comfortably
positive. Do not deliberately reproduce a death. The history will show calculator values, report
ordering, notification flags/callers and incoming rebases for comparison against the native map.
If it exposes an incorrect estimate or local boundary, reproduce that exact sequence in a fixture
before changing the protection decision. Do not replace this investigation with a meter-limit escape
or masking an already received death message.

## Verification

Passed: 28 production integration tests, 24 diagnostic integration tests, four incident-decoder
tests, five native-map tests, the fatal-policy regression executable, and static verification against
the installed GameAssembly plus metadata. The signed candidate was installed at the existing app
path after both real processes closed; signature and byte comparisons passed. No live boss capture
with this recorder has been reviewed yet. The protection decision policy is unchanged.

Five alternating baseline/candidate synthetic x86-64/Rosetta trials measured the installed source:

| Boundary | Baseline median | Tracing median |
|---|---:|---:|
| Guard scope tick (not full callback) | 0.100 µs | 0.114 µs |
| Projectile calculation/report/notification | 0.210 µs | 0.627 µs |
| Incoming update | 0.146 µs | 0.292 µs |
| Terrain notification | 0.073 µs | 0.223 µs |
| Mixed hit/update | 0.491 µs | 0.759 µs |

All recorded benchmark workloads had zero queue drops. These use fake IL2CPP APIs and batch timings,
not live-game latency or server measurements. Results and source hashes are retained locally in
`build/death-investigation-2026-10-20/performance-installed/results.json`. The history adds a fixed
8192 bytes; resident-process differences are too noisy to use as a memory-allocation measurement.

## Second death: beach projectile capture, 18:41:44 Pacific

The user reported a different test character dying on the beach. The recorded map was Realm of the
Mad God. `guard-19822.tsv` confirms the new recorder was loaded, protection was armed/enabled, the
terminal 64-record history is complete, and no hook queue drops or observed off-main calls occurred.
The preserved snapshot SHA-256 is `9727a5330aad1526c068a6a9cf5430869a576f184f75e47cffde1f29874d531a`.
Raw evidence and a compact decoded sequence are in ignored `build/death-investigation-second/`.

| Time before terminal HP write | Observation |
|---|---|
| 369–202 ms | At HP 41, audited projectile calculations 6, 8, 8, 8, 8 accumulate pending 38; projected HP is 3. All five hit reports and notifications pass. |
| 201.858 ms | Incoming stat setter `0x184c115` changes HP 41 → 42. Pending is 38 at setter return, then the current policy resets it to zero. |
| 169.498 ms | Next audited 8-damage projectile raises pending to only 8 and predicts HP 34. It is reported without Nexus. |
| 19.183 ms | A 6-damage projectile raises pending to 14 and predicts HP 28. It is also reported. |
| 2.250 ms | Incoming stat setter changes HP 42 → 21; pending 14 is cleared again. |
| 0 ms | Incoming death caller `0x1840e64` sets HP 21 → 0 through the deliberately excluded death-handler route. |

Entry eligibility masks are 255: guard/map readiness, known map, validated controlled player,
enabled intervention, outside Nexus and a policy bound to the player all pass. Calculator input,
return value and local notification agree for the nonzero hits in this history. No request was made.
This is not an unclassified local projectile route or a failed Nexus invocation in the retained interval.

A compiled replay against the actual `fatal_policy.h` reproduces pending 38/projected 3, then
pending 0/projected 42 after the update, then pending 8/projected 34 after the next hit. Retaining
the 38 recent predicted damage would instead produce projected -4 on that next hit and request
escape approximately 169 ms before the terminal handler. This is a counterfactual request, not
proof of server acceptance or survival. The original boss death still lacks this detailed history.

The snapshot proves loss of the pending prediction at the update. It does not identify which
individual reports the server had processed when emitting HP 42, nor whether every HP difference
was damage versus healing. Retaining predictions fixes this replay's missed request but can count
already-applied damage when healing overlaps it. A correction must address both this replay and the
previous stale-damage/healing regression; do not substitute unlimited damage accumulation or claim
that an HP assignment acknowledges all prior hit reports. The installed tracing build is unchanged.

## Version 7 candidate

The candidate replaces whole-budget resets with a 128-entry timestamped ledger (2048 bytes;
2168 bytes including policy state). HP decreases debit the oldest estimates; increased HP raises
the prediction baseline once. Fresh observations retire estimates older than the adaptive window
described in [Nexus integration](nexus-on-death.md). Ticks omitting unchanged HP still count, so idle
HP does not masquerade as a network stall. Map-entry validation bootstraps the stall clock once,
without treating ordinary guard polling as a server heartbeat. Stalled updates and full capacity request escape before
the next positive covered hit. Failed requests preserve damage and overflow debt rather than pretending
cancellation. The existing player/connection/socket latch and incoming-state exclusions remain.

The automated beach fixture requests Nexus at HP 42, pending damage 46 and projected HP -4, before
the sixth hit report. Separate fixtures cover HP recovery and expiry, unchanged-HP tick heartbeats,
stalls, buffer capacity, rejection/exception behavior and mixed damage. Unit tests replay delayed and
jittered inputs plus the earlier 1206-HP false-escape sequence. Automatic confirmed Nexus now saves
the bounded history as well as manual Nexus and terminal events.

Neither net HP loss nor expiry is proof of report acceptance. Constant high processing delay can
outlast the window even with regularly spaced packets, and healing can mask applied damage. These
are explicit limitations, not newly established protocol guarantees. See [beach stress tests](beach-stress-tests.md).

Candidate verification: 34 production integration cases, 24 diagnostic cases, four decoder cases,
five native-map cases, reviewed-profile/generated-code checks, and the native policy suite including
20,000 variable-gap transitions. The policy suite passes AddressSanitizer/UndefinedBehaviorSanitizer
and Intel/Rosetta builds. The live validation below completes the requested beach check.

Five alternating synthetic Rosetta trials against the capture-only baseline measured median
projectile-path time 0.563 → 0.678 µs, incoming-update time 0.290 → 0.406 µs, and mixed-hit/update
time 0.717 → 0.823 µs, with zero queue drops. The fixed policy grows from 48 to 2168 bytes;
2048 bytes are the hit ledger. Independent 100-hit batches avoid benchmarking an accidental
capacity-triggered escape. These fake-IL2CPP batch timings are not real-game/server latency.

## Live validation: two automatic escapes, 20:15 Pacific

The installed version 7 recorder captured two automatic escapes in `guard-26399.tsv` on
2026-10-20. Both returned alive to Nexus. Both escape histories are complete within the bounded
recorder (64 and 14 records); the session reports zero queue drops, zero observed off-main calls,
two suppressed projectile reports and two suppressed notifications. No death event was recorded.
Raw evidence, decoded incidents and a hash manifest are preserved locally under ignored
`build/beach-validation-20261020-201611/`. Snapshot SHA-256:
`4d225c8edb6b45069294a7c45c5c469ef7e7483257063b68f2a6b0d2c7acc71d`.

| Automatic request (Pacific) | Stored HP | Total predicted damage including triggering hit | Projected HP | First observed HP in Nexus |
|---|---:|---:|---:|---:|
| 20:15:21.826694 | 18 | 19 | -1 | 14 |
| 20:15:44.277529 | 225 | 228 | -3 | 111 |

The first run exercises retention across an actual incoming HP assignment: the HP update from
26 to 18 arrives with 22 pending damage. Reconciliation leaves 13 pending after net-loss debit
and age retirement. A 2-damage hit raises this to 15; the following 4-damage hit triggers escape
at 19. Under version 6, that final HP assignment would clear the budget, and these last two hits
would total only 6, predicting 12 HP and making no request at this point. This is a counterfactual
decision comparison, not proof that the character would have died with version 6.

The second run begins at stored HP 225. One 114-damage hit is forwarded. Two unchanged-HP ticks
retain that 114; another 114-damage hit 266.954 ms after the first projects -3 and is suppressed.
The next received HP is 111, consistent with the first hit being applied; Nexus arrival is also
111. Escaping while stored HP still reads 225 is supported by this outstanding burst, rather than
a full-health threshold or a stale-update/capacity failsafe. Tick omission of the HP setter means
this second sequence alone does not prove that version 6 would have cleared pending damage.

Both requests use the projected-lethal reason. Recorded calculator return to successful local
Nexusing result is 18 and 19 microseconds, respectively; this includes hook/recording work and is
not an isolated policy benchmark or server latency. Nexus map arrival follows about 2.90 and
2.96 seconds later, including transition/loading. Positive HP at arrival establishes the observed
outcome beyond the local request flag. This validates the two captured sequences, not universal
survival, all healing combinations, or the unresolved Advanced Kogbold killing route.
