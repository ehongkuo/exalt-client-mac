# Nexus on death hardening plan

Status: proposed, 2 November 2026. No gameplay policy has changed. This plan addresses the
remaining gaps in policy version 8 ([current policy](nexus-on-death.md)). Each phase is a separate PR,
runs in Dry Run before it is armed, and is judged against recorded captures.

## Issues addressed

The scenarios below were run against the real `probe/fatal_policy.h`.

| ID | Issue | Effect |
|---|---|---|
| A | The server applies a hit later than the 800 ms quiet allowance while ticks stay healthy. The quiet rebase forgets the hit. | Missed escape |
| B | Untracked HP loss (DoT, scripted or server-only damage) is treated as a tracked hit and retires it. | Missed escape |
| C | Server damage exceeds the local calculation, mainly when a protective buff ends or a debuff arrives from an untracked source before the client learns of it. Bullet-carried effects are likely applied locally first; unverified. | Missed escape |
| D | Healing (potion, pet, ally, regeneration) arriving in the same update as a hit hides part of the hit. | Early escape only |
| E | A positive hit after a stall of at least 1.5 s escapes regardless of HP. | Early escape only, intended |
| F | Leftover pending damage persists while HP is unchanged, because updates that leave out HP cannot trigger a quiet rebase. | Early escape only |

Regeneration and heals are never predicted. They raise the baseline once observed and can only
leave damage pending (D), never retire too much.

## Phase 0: measurement

1. Turn the A–F scenarios into fixtures in `tests/probe/fatal_policy_tests.c`. Assert the current
   outcomes, including the A and B deaths, so each fix visibly changes an expected result.
2. Add a replay tool that runs recorded captures in `build/` through `fatal_policy.h` and reports,
   per policy version: false escapes, deaths without Nexus, and the minimum projected margin.
3. Extend `probe/analyze_latency.py` to report local damage minus HP drop for each isolated hit,
   to quantify C outside condition changes.
4. Take a probe capture to decode the condition bits for Poison, Bleeding, Sick, Armored,
   Armor Broken, Exposed, Curse and Invulnerable. Check whether a bullet-carried effect changes the
   recorded condition mask before the next server update. Phase 3 depends on this.

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

## Phase 1: unexplained-drop detection (B)

- Retire hits on an HP decrease only when the decrease matches a sum of the oldest pending hits,
  within a small regeneration tolerance taken from recent per-update HP increases.
- An unmatched decrease is treated as untracked damage: retire nothing, log it, and restart the
  quiet timer.
- Needs no condition decoding, so it also covers future DoTs, scripted damage and hazards.
- Check by replay that false escapes during heavy combat with healing do not rise materially.

## Phase 2: late-arrival protection (A)

1. Risk-scaled rebase: rebase after 800 ms only if clearing pending damage would leave projected HP
   well clear of zero. Otherwise require a longer quiet interval, for example 1.6 s.
2. Probation after a rebase: hold the cleared amount for about 2 s. An unexplained decrease in that
   period is attributed to the cleared amount, not to new hits. Log it and lengthen the session's
   quiet interval, capped at 2 s. This also produces evidence on whether 800 ms is sufficient.
3. Research in parallel: look for an incoming message that identifies an applied hit. A keyed
   acknowledgement would replace the timing assumption, with items 1 and 2 kept as fallbacks.

## Phase 3: condition awareness (B, C)

Requires the Phase 0 capture.

- Read the condition mask in the production build (two array reads per calculation and update).
  Today only the diagnostic build reads it.
- While a DoT condition is active, retire no hits on an HP decrease.
- While a protective buff (Armored, Invulnerable, defense buffs) is active, project each hit at its
  worst case, its damage before defense, if Phase 0 confirms the calculator input is that value. The
  game's applied damage is unchanged.
- If bullet-carried effects prove not to be applied locally first, apply the same worst-case
  projection briefly after a hit from an effect-carrying bullet.

## Phase 4: fewer false escapes (D)

- Credit the guard's own potions: it knows when it drank and the amount. Add the potion amount back
  to the matching decrease, except near max HP where the heal may have been capped.
- Do not estimate regeneration to retire hits; an overestimate errs toward a missed escape.
  Leftovers are cleared by the quiet rebase.

## Validation for every phase

1. Unit fixtures, including the A–F scenarios and new edge cases.
2. Replay against all recorded captures, compared with the previous policy.
3. Live Dry Run, reviewing logged predictions.
4. The live [beach stress tests](beach-stress-tests.md).
5. Update [Nexus on death](nexus-on-death.md) and the README.

Order: 0, 1, 2; then 3 after the condition capture, and 4 when convenient. Phases 1–2 change only
the prediction policy and are easy to revert. Phase 3 is the only one that adds production
game-memory reads.

## Deferred fallback: safety reserve (A, B, C)

The goal is to make the three prediction assumptions hold, not to buffer against them: every HP
loss is tracked (B), server damage equals the local calculation (C), and settlement fits the quiet
allowance (A). A reserve, escaping when projected HP falls to a margin rather than to zero, is
deferred until that work is done.

Revisit it if, after Phases 1–3, captures and replay still show HP losses the model cannot explain,
damage mismatches that cannot be predicted, or settlement later than the allowance, at a rate that
makes a missed escape an unacceptable risk.

A complete implementation exists on branch `feat/nexus-safety-reserve` (closed PR #13): a saved
`reserve=N` setting (0–25% of max HP), live protocol version 7, reason 4, and
`replay_policy.py --reserve`. Its replay of the 5 passive captures (all at 225 max HP) found no
requests without a death at 5% (11 HP) and one at 10% (22 HP), on the closest 22 HP margin.
