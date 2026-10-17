# Nexus protection performance audit

## UI efficiency and bounded stall diagnostics

The follow-up caps both visual refresh schedules at 30 Hz, coalesces UI reads within 16 ms, and keeps the separate 10 Hz party-alert read forced fresh. Protection polling and inline damage hooks retain their cadence and decisions. Timestamp formatting reuses one formatter; unchanged mapped snapshots reuse their decoded value. File identity checks remain immediate so reconnection is not delayed.

Five alternating optimized Swift trials of 10,000 timestamp calls each measured **14.53 us before → 0.619 us after** (23.5x faster). This is isolated formatting cost, not a measured whole-app CPU reduction. Raw samples are in `build/local-latency/format-comparison.json`.

New `guard_latency` lines summarize cumulative counts and maxima every 10 seconds and at orderly shutdown. All callbacks contribute gap counts (20 ms and 100 ms thresholds), total work through live publication, and maxima. `valid` means the current callback has a valid player/HUD reading; it includes Nexus and the first reading after a transition. Stage maxima split lookup, guard actions, hooks/chat/join services, and publication, sampled once per 64 callbacks. They are independent maxima, not a breakdown of the slowest callback. Work excludes timing-summary formatting and telemetry log enqueue. No timing history or shared-file ABI was added: fixed main-thread counters use 104 bytes plus an 8-byte deadline; summaries use the existing bounded note queue and background writer. Abrupt exits may lose the final partial interval, and a full note queue can drop a summary; subsequent cumulative summaries recover the counts.

Five alternating full-callback fixture trials against merged main `e689e3b` measured median **0.773 → 0.968 us**, p95 **2.208 → 2.305 us**, and process CPU **932 → 1,179 ns/callback**. At 1,000 callbacks/sec that CPU difference is approximately 0.025% of one core in this fixture. A preceding five-run batch measured a smaller 24 ns median difference, so these background-loaded measurements are noisy, not a production CPU bound. All workloads recorded zero queue drops. Short benchmark bursts do not exercise the 10-second summary cadence.

Reproduce the full-callback comparison without preparing old PR snapshots:

```sh
python3 tests/probe/benchmark.py --runs 5 --baseline e689e3b --full-tick --output build/local-latency/repro-full-tick
```

The `tick` workload with `--full-tick` measures the complete callback; the older poll-component numbers below measure only the protection component. The running installed app/guard have not been replaced during this follow-up. Fresh gameplay after installation is needed to attribute the previously observed scheduling stalls. Window redraw CPU savings have not yet been measured in a controlled app A/B run.

## Protection-hook optimization baseline

Measured on Apple M5 Pro, with Intel production-hook code under Rosetta in the synthetic game fixture. Seven alternating-order runs per version; each run measures 30,000 operations per ordinary workload and 100 local lethal requests. The real game was running concurrently, so these are component costs with scheduling noise, not a controlled full-game CPU/RAM or network-latency A/B test.

The final run includes the version-3 authoritative-HP-window correction for the confirmed full-health false escape, as well as the production snapshot/logging optimizations.

Versions: main `9db6e7d`, pre-sweep PR `2eccaad`, and the optimized production header in this change. Raw per-run samples, source hashes and host metadata are retained locally in `build/performance/results.json`.

## Runtime changes

- Production no longer reads HP/max/tick/time or takes timestamps for diagnostic-only snapshots that are immediately discarded. The post-setter HP read, update-source routing, damage decisions, and escape validation remain.
- Normal per-hit prediction rows and empty-budget HP-update rows are omitted from production logs. Shared live state still publishes the budget. Escape, failure, suppression and retained-damage update evidence remains; standalone diagnostic tracing remains unchanged.
- The production event queue is 512 fixed slots (64 KiB), down from 2,048 (256 KiB). Overflow is counted and only drops telemetry; it cannot drop a protection decision. Diagnostic capacity remains 2,048 and its separate flight recorder remains 8,192 slots. No heap allocation per poll or ordinary hit is added.
- No new timer, worker or UI polling was added. Environmental fields use the existing 1 ms main-thread guard callback and cached field descriptors. Socket sends add an exact-caller/latch check. Escape calls still execute inline; logging uses the existing background writer.

## Component latency

Values below are medians of the seven per-run p50s, in microseconds. The final column is the median per-run p95 for the optimized build. These measure local wrappers with fake IL2CPP APIs and mock Nexus, excluding server processing/acknowledgement.

| Workload | Main p50 | PR before p50 | Updated p50 | Updated p95 |
|---|---:|---:|---:|---:|
| Protection poll | 0.117 | 0.101 | 0.134 | 0.145 |
| Projectile + report + notification | 1.799 | 1.828 | 0.292 | 0.593 |
| Incoming update, no pending damage | 1.737 | 1.670 | 0.260 | 0.523 |
| Hit followed by HP update | 3.632 | 3.589 | 0.875 | 1.570 |
| Terrain notification | 0.495 | 0.735 | 0.160 | 0.285 |
| Unrelated socket send | 0.004 | 0.007 | 0.012 | 0.013 |
| Local lethal request (mock Nexus) | 2.375 | 4.125 | 1.209 | 2.833 |

The old terrain notification only forwarded damage; its baseline timing does not represent equivalent protection. The mixed workload includes the HP-update telemetry generated when pending damage is rebased. The unused-snapshot reduction is deterministic: a projectile sequence drops from 38 to 3 field reads, an empty-budget incoming update from 37 to 3, and a protected terrain notification from 17 to 2.

Rare request tails vary substantially while the game runs: per-run p95 ranges are 2.33–12.04 us for main, 1.88–8.83 us before the sweep, and 1.67–5.29 us afterward. The ranges overlap; do not claim improved server or worst-case escape latency from this run. The optimized local request median is about 1.2 us.

## CPU and memory

The protection-poll component used 113.70 ns of process CPU per operation on main and 118.03 ns afterward, including benchmark bookkeeping/draining. At 1,000 polls/sec the point-estimate difference is 0.0004% of one CPU core in this fixture (below 0.01%). This small difference is sensitive to background noise; it is not a precise production CPU bound. The complete existing guard, scheduler, UI and real IL2CPP costs are not included. It is not a measured whole-game CPU percentage.

The main shipping library has 761,152 bytes of zero-fill data; the updated build has 564,704 bytes. Its Mach-O mapped segments total 630,784 bytes versus 823,296 on main (188 KiB smaller). The ninth hook reserves one additional 4 KiB trampoline, for an approximate net mapped reduction of 184 KiB against main. On-disk library size is 68,408 bytes versus 63,720 on main; file size and runtime resident memory are different quantities.

The event buffer is bounded and allocated statically. Synthetic host resident/footprint readings were collected per workload but are not treated as the RAM delta in the real game. No production flight-recorder file/string is present in the shipping library. That protection-hook optimization did not change UI polling; the follow-up UI changes are described above.

All seven workload families across all seven runs and three versions recorded zero event-queue drops. The benchmark uses a single explicit consumer and deletes its synthetic logs after collecting numerical samples. Actual gameplay logs and diagnostic session evidence are untouched.

At the start of the sweep the PR had 2,203 added lines. At most 311 of those were in runtime-source files; the remaining 1,892 were documentation, tests, build/diagnostic tooling and static audit data. Conditional compilation excludes additional diagnostic sections from the production runtime. The benchmark added here is test-only.

## Validation and reproduction

The 17 production intervention tests and 24 diagnostic tests pass after optimization. The 16 session-report tests, five native-map tests, production compilation with warnings as errors, and undefined-behavior-sanitized fatal-policy tests pass. The tests retain coverage for mixed-source damage, authoritative HP assignments, disabled/dry-run behavior, failed Nexus requests, meter-only nonintervention, and pending-escape latches.

From the worktree root, prepare the immutable source snapshots once and run:

```sh
mkdir -p build/performance/base build/performance/pr-before
git archive 9db6e7d guard probe | tar -x -C build/performance/base
git archive 2eccaad guard probe | tar -x -C build/performance/pr-before
python3 tests/probe/benchmark.py --runs 7
```

No game restart, injection into the real game, or installed-app replacement is performed by this benchmark. Installed-app state is separate from this synthetic benchmark.
