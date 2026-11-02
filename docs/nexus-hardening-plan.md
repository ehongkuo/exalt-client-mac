# Nexus on death hardening plan

Status: revised 2 November 2026. No gameplay policy has changed. This plan addresses the remaining
gaps in policy version 8 ([current policy](nexus-on-death.md)). Each phase is a separate PR, runs in
Dry Run before it is armed, and is judged against recorded captures.

## Model

What the guard can and cannot observe:

1. The client detects hits (projectiles, ground and area damage) and reports each one to the server.
   A report identifies the hit, not its amount: the server computes the damage itself, from the same
   base damage and defense and conditions. The guard reads the client's own calculation and treats it
   as exact: isolated hits in captures matched to within 1 HP, which regeneration accounts for.
2. Not every HP loss passes through a hook the guard sees. Captures show suffocation losses with no
   matching report, and some damage over time is driven by the server.
3. The server owns HP. It applies the damage it computes, plus all healing (regeneration, potions,
   pets, allies), and sends HP in periodic updates, about every 200 ms. An update carries only the
   net result.
4. Because HP is net, the guard cannot tell from an update which reported hits it already contains.
   Splitting a decrease into specific hits requires guessing the healing in the same interval, and
   healing varies too much in combat to guess safely.
5. The round trip from reporting a hit to receiving an update that contains it varies. Measured
   samples are few: 11 inferred visibilities from one session ranged 167–667 ms (median 301 ms), and
   4 more had a 392 ms median ([calibration](damage-latency-calibration.md)). Mostly under 800 ms
   is consistent with that, but the tail is unmeasured, especially under lag, and round trips are
   quantized to the update interval.

The plan therefore uses timing, not HP amounts, to decide when a hit has been applied. Server HP is
the baseline and already accounts for every heal and every untracked loss; the guard adds only the
hits the server cannot have applied yet.

## Issues addressed

The scenarios below were run against the real `probe/fatal_policy.h`.

| ID | Issue | Effect | After this plan |
|---|---|---|---|
| A | The server applies a hit later than the 800 ms quiet allowance while ticks stay healthy. The quiet rebase forgets the hit. | Missed escape | The remaining assumption; Phase 2 |
| B | Untracked HP loss (DoT, scripted or server-only damage) is treated as a tracked hit and retires it. | Missed escape | Removed by Phase 1: amounts never retire hits |
| C | Server damage exceeds the local calculation, mainly when a protective buff ends or a debuff arrives from an untracked source before the client learns of it. | Missed escape | Assumed exact; monitored (Phase 3) |
| D | Healing in the same update as a hit hides part of the hit. | Early escape only | Removed by Phase 1 |
| E | A positive hit after a stall of at least 1.5 s escapes regardless of HP. | Early escape only, intended | Unchanged |
| F | Leftover pending damage persists while HP is unchanged, because updates that leave out HP cannot trigger a quiet rebase. | Early escape only | Removed by Phase 1 |

## Phase 0: measurement

1. Turn the A–F scenarios into fixtures in `tests/probe/fatal_policy_tests.c`. Assert the current
   outcomes, including the A and B deaths, so each fix visibly changes an expected result.
2. Add a replay tool that runs recorded captures in `build/` through `fatal_policy.h` and reports,
   per policy version: false escapes, deaths without Nexus, and the minimum projected margin.
3. Extend `probe/analyze_latency.py` to report local damage minus HP drop for each isolated hit,
   to quantify C outside condition changes.
4. Take a probe capture to decode the condition bits for Poison, Bleeding, Sick, Armored,
   Armor Broken, Exposed, Curse and Invulnerable. Check whether a bullet-carried effect changes the
   recorded condition mask before the next server update. Optional now: Phase 3 needs it only if
   monitoring finds a mismatch.

### Phase 0 status

Items 1–3 are implemented:

- `tests/probe/fatal_policy_tests.c` pins the v8 outcomes for A–F.
- `probe/replay_policy.py` replays captures through `probe/policy_replay.c`, compiled against one or
  more policy headers, and reports each scope as `escape_before_death`, `missed_death`,
  `request_without_death` or `quiet`, with minimum projected HP and rebase counts. Compare a
  candidate with `--policy probe/fatal_policy.h --policy CANDIDATE.h`. Outcomes are ground truth only
  for passive captures; only probe and sync-capture builds record the needed events.
- `probe/analyze_latency.py` reports `damage_mismatch`: server HP loss minus local damage for
  isolated reports, and non-terminal excess losses.

First results, 2 November 2026: 8 local captures contain replayable events (5 passive). Policy v8
produced no requests or deaths in them; the closest projected margin was 22 HP. Isolated residuals
were 0 three times and -1 once. One isolated 23-damage report in `guard-31242.tsv` was followed by
a 53 HP loss in one update: 30 HP not explained by the local calculation, from server-side damage
or an untracked loss. A single case; it is an example of C or B, not a rate.

```sh
python3 probe/replay_policy.py --input build --input "$HOME/Library/Application Support/Exalt Client Mac/logs" \
  --json build/policy-replay/v8.json
```

### Condition capture (item 4)

No code change is needed: the diagnostic records the condition-mask words (phase 29, `flag2=1`) at
each damage notification, each HP assignment, and on any change during polling.

1. `sh probe/build-probe.sh`, then open `build/damage-diagnostic/Start Hit Diagnostic.command`
   (observation only). Use a disposable character; enter Nexus and wait for readiness.
2. For each effect, start at full HP, take one hit from an enemy known to inflict it, step away until
   the condition ends, then take one plain hit for comparison. Note the effect and approximate time.
3. Cover bullet-carried debuffs (Armor Broken, Exposed, Curse, Sick, Bleeding, Poison) and
   self/ally buffs (Armored, Invulnerable, a defense buff), including a buff expiring during combat.
4. Manually Nexus, wait five seconds and quit normally to bundle the session.

Analysis: map each effect to the mask bit that changes, and compare when the bit changes relative to
the hit's notification and the next incoming HP assignment. A change at or before the next server
tick that carries the effect indicates local application; a change only with a server update
indicates server control.

## Phase 1: per-hit settlement by age (A, B, D, F)

Replace amount-based retirement and the global quiet rebase with one rule:

> projected HP = latest server HP − damage of hits that update cannot yet contain

- A hit is pending until the latest healthy, progressing server update arrived at least the
  settlement window W after the hit was reported. Then it is assumed contained in server HP and
  retired. The comparison uses the update's arrival time, not the current time, so a stall never
  retires hits against stale HP.
- HP decreases and increases change only the baseline. They never retire or restore hits, so
  healing, regeneration and untracked losses need no estimate.
- In sustained combat old hits expire one at a time instead of waiting for 800 ms without damage.
  A hit the server applied early is counted twice until its window ends: a bounded error toward
  escaping.
- Updates that omit HP mean HP is unchanged; check in captures before relying on that to age hits
  (closes F).
- Keep the stale escape (E), the capacity escape and the escape latch. W stays at 800 ms in this
  phase, so the change can be judged alone.
- Keep the v9 unexplained-decrease counter as a diagnostic only: an HP decrease larger than the
  pending hits, or one shortly after hits were retired, is logged for Phase 2.

The v9 prototype (PR #15) retired hits whose sum matched a decrease within a learned regeneration
tolerance. It is superseded: the tolerance depends on healing, which cannot be predicted in combat.

## Phase 2: learned settlement window (A)

1. Measure settlement in server updates from clean samples only: a single pending hit, no HP
   increase in the interval, and a decrease equal to the local damage. Skip anything ambiguous.
2. Set W from recent samples: a high percentile plus one update interval, with a floor of two
   update intervals and a ceiling of about 2 s. Use 800 ms until enough samples exist.
3. Lengthen W immediately when update spacing grows or becomes irregular, without waiting for new
   samples.
4. Probation: an unexplained decrease shortly after hits were retired means W was too short. Count
   it as a late sample and widen W.
5. Research in parallel: find an incoming message that proves the server processed a report, either
   a keyed acknowledgement or an echo of a later client message (the connection is ordered). Either
   would replace the timing assumption, with W kept as a fallback.

A shorter W on a stable connection reduces double counting; a longer W during lag protects against
A. The second matters most.

## Phase 3: damage mismatch monitoring (C)

Local damage is assumed to equal the server's. Phase 1 also limits any mismatch to hits that are
still pending. No condition-aware projection is planned.

- Keep `damage_mismatch` in `probe/analyze_latency.py` and run it on every new capture.
- Revisit only if captures show isolated hits whose server decrease exceeds the local damage by more
  than regeneration explains. The Phase 0 condition capture would then show whether a buff or debuff
  desynchronized; worst-case projection while protective buffs are active is the fallback.

## Validation for every phase

1. Unit fixtures, including the A–F scenarios and new edge cases.
2. Replay against all recorded captures, compared with the previous policy.
3. Live Dry Run, reviewing logged predictions.
4. The live [beach stress tests](beach-stress-tests.md).
5. Update [Nexus on death](nexus-on-death.md) and the README.

Order: 0, 1, 2; 3 runs alongside as captures arrive. Phases 1–2 change only the prediction policy and
are easy to revert, and no phase adds production game-memory reads.

Useful captures: a laggy session, combat with healers or pets nearby,
damage over time and suffocation, and gear changes that alter max HP.

## Deferred fallback: safety reserve (A, C)

The goal is to make the prediction assumptions hold, not to buffer against them: settlement fits
the window (A) and server damage equals the local calculation (C). A reserve, escaping when projected
HP falls to a margin rather than to zero, is deferred until that work is done.

Revisit it if, after Phases 1–2, captures and replay still show settlement later than the window, or
monitoring shows damage mismatches, at a rate that makes a missed escape an unacceptable
risk.

A complete implementation exists on branch `feat/nexus-safety-reserve` (closed PR #13): a saved
`reserve=N` setting (0–25% of max HP), live protocol version 7, reason 4, and
`replay_policy.py --reserve`. Its replay of the 5 passive captures (all at 225 max HP) found no
requests without a death at 5% (11 HP) and one at 10% (22 HP), on the closest 22 HP margin.
