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
   recorded condition mask before the next server update. Phase 4 depends on this.

## Phase 1: safety reserve (A, B, C)

- Request Nexus when projected HP falls to the reserve or below, not 0 or below.
- Add the reserve as a saved setting sent to the guard, with Off available.
- Start with a fixed percentage of max HP (max HP is already read). Later versions may derive it
  from the Phase 0 mismatch data.
- Cost: earlier escapes, measured by replay. Open decision: the default reserve size.

## Phase 2: unexplained-drop detection (B)

- Retire hits on an HP decrease only when the decrease matches a sum of the oldest pending hits,
  within a small regeneration tolerance taken from recent per-update HP increases.
- An unmatched decrease is treated as untracked damage: retire nothing, log it, and restart the
  quiet timer.
- Needs no condition decoding, so it also covers future DoTs, scripted damage and hazards.
- Check by replay that false escapes during heavy combat with healing do not rise materially.

## Phase 3: late-arrival protection (A)

1. Risk-scaled rebase: rebase after 800 ms only if clearing pending damage would not bring
   projected HP near the reserve. Otherwise require a longer quiet interval, for example 1.6 s.
2. Probation after a rebase: hold the cleared amount for about 2 s. An unexplained decrease in that
   period is attributed to the cleared amount, not to new hits. Log it and lengthen the session's
   quiet interval, capped at 2 s. This also produces evidence on whether 800 ms is sufficient.
3. Research in parallel: look for an incoming message that identifies an applied hit. A keyed
   acknowledgement would replace the timing assumption, with items 1 and 2 kept as fallbacks.

## Phase 4: condition awareness (B, C)

Requires the Phase 0 capture.

- Read the condition mask in the production build (two array reads per calculation and update).
  Today only the diagnostic build reads it.
- While a DoT condition is active, retire no hits on an HP decrease.
- While a protective buff (Armored, Invulnerable, defense buffs) is active, project each hit at its
  worst case, its damage before defense, if Phase 0 confirms the calculator input is that value. The
  game's applied damage is unchanged.
- If bullet-carried effects prove not to be applied locally first, apply the same worst-case
  projection briefly after a hit from an effect-carrying bullet.

## Phase 5: fewer false escapes (D)

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

Order: 0, 1, 2, 3; then 4 after the condition capture, and 5 when convenient. Phases 1–3 change only
the prediction policy and are easy to revert. Phase 4 is the only one that adds production
game-memory reads.
