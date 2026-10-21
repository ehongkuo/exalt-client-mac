# Advanced Kogbold death investigation — 2026-10-20

Status: missed intervention confirmed; killing path and corrective protection change unresolved.
This change adds evidence collection, not a claimed death-prevention fix.

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
notification return, sampled HP, or death-screen entry per player/map scope. A manual Nexus also
saves one history per scope, allowing collection before lethal exposure. Collection continues
after that manual request in case it fails. At most two dumps, each at most 65 records, are queued
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
