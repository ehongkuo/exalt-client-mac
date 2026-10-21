# Proposed Nexus reconciliation design

Review proposal, not an implemented or protocol-validated protection guarantee.

Objective: authorize each damaging input only if every still-plausible history leaves the character alive after it. Otherwise invoke Nexus before forwarding that input. This is the latest safe decision given the available observations and model, not necessarily the true last survivable hit.

## Scope and required assumptions

The capture establishes local projectile reports, incoming HP assignments and numbered tick responses. It does not establish report inclusion boundaries, ordered server application of reports, equality of local and server damage, or complete coverage of all harmful inputs. An absolute survival guarantee cannot be made from this evidence. Local acceptance of Nexus also is not server acceptance.

A conditional proof requires: a known baseline with no prior outstanding damage; interception before every relevant effect/report; a correct damage value or conservative upper bound for each input; authoritative ordered HP snapshots within a player/connection generation; and either validated server report application ordering or a model that allows every possible ordering. Other HP losses, maximum-HP reductions, damage-over-time effects, and server-only hazards must be modeled explicitly. They cannot silently be treated as healing or attributed to a recorded shot.

The low-cost prefix algorithm below requires exact, atomic per-event damage and ordered server application. Those are verification requirements, not findings of the present capture. Without them, retain a broader set of feasible processed-event sets and damage amounts, or use a conservative lower bound that includes that uncertainty. Never impose ordering merely because a socket or local call sequence is ordered.

## Decision rule

Maintain a set of histories consistent with all received observations. A history specifies which recorded inputs a snapshot includes, their applied damage, and permitted healing/other HP changes. Do not assign a single guessed acknowledgement frontier.

For each history, derive a lower bound on current HP after accounting for inputs authorized since that snapshot. Positive unobserved healing need not be credited. Let L be the smallest bound across all histories. For a new input whose damage is at most D:

- If L - D > 0 in every history, authorize it and record the event exactly once.
- Otherwise request Nexus and withhold the dangerous input through the audited hook boundaries.

A speculative hit is not added to the forwarded ledger unless its relevant effect/report is actually authorized. A shot passing through calculator, reporter and notifier is one damage event, not three. Include generation and a monotonic local sequence in its identity; shooter/projectile IDs alone are reusable.

If a still-feasible history makes the next input lethal, permitting it violates the conditional safety objective. Therefore this minimax rule cannot be delayed further without additional evidence or accepting risk. It can exit before actual death when histories remain ambiguous; no decision rule can distinguish observationally identical histories without more information.

## Efficient specialization if ordered, exact damage is verified

Let d[1..n] be the exact damage of authorized events and P[k] their cumulative sum. A snapshot contains HP S and has an unknown processed prefix k. Maintain feasible k values, including causal constraints from all earlier snapshots. Initially establish k=0 at a verified baseline before harmful inputs are allowed under the protection claim.

For a transition from snapshot A to B, a previous candidate k can reach candidate j only if j >= k, j refers to reports that could causally precede the new snapshot, and:

    S_B >= S_A - (P[j] - P[k])

This inequality assumes all negative HP changes come from the tracked events and additional healing is nonnegative. Add independently proven healing limits, maximum-HP behavior, invulnerability semantics, and survival constraints when available. Do not invent healing rates or burst provenance from HP deltas alone.

Discard only candidates contradicted by the observations. Keep all remaining candidates, including candidates in which healing hid additional processed damage. Recompute the bound on each observation as well as before damage. A nonpositive bound is an immediate escape/fault condition, not a reason to wait for another hit. If there are no candidates, mark the model invalid and request escape; do not reset to the latest HP and continue reporting damage.

The current HP lower bound for candidate j is:

    S_B - (P[n] - P[j])

Take the minimum over candidates. In the simple model with arbitrary nonnegative healing and nonnegative exact damage, only the smallest feasible prefix is needed to compute the bound. A negative snapshot delta advances that prefix by the minimum number of whole events capable of producing the decrease. Partial damage credit against an atomic hit is unnecessary in this specialization. Additional constraints or uncertain amounts may require a real candidate frontier.

Use fixed-capacity arrays and cumulative damage sums. A general prefix frontier can use an allocation-free reachability scan; a straightforward bounded O(N²) reconciliation at HP observations is acceptable as a correctness reference, with O(N) or better damage decisions. Optimize only after measuring. The simpler monotone frontier can advance amortized O(1) per retired event. Do not silently switch from a broader model to this specialization to meet a performance target.

## Replay of the measured two-hit sequence

Baseline 225. Authorize A=44, then B=44. Before any HP response, L=137.

At snapshot 181, an unchanged prefix cannot explain the 44 HP decrease through nonnegative healing. The smallest feasible prefix includes A. A prefix including both hits is also possible if healing occurred. L=181-44=137.

At snapshot 138, HP falls another 43. Under this model, remaining at the same processed prefix cannot explain that loss. The smallest feasible prefix advances through B. The 44 damage with 1 recovery is consistent; both hits are now accounted for and L=138.

This inference depends on all negative changes being tracked, exact atomic damage and ordered application. The capture alone does not verify those prerequisites. With an unobserved 43-damage producer, for example, the second decrease cannot establish that B was processed.

If a later snapshot rises instead, healing alone may explain it. Do not retire a hit just because HP rose or its report is old. Use the received HP with all still-possible outstanding damage. Later observations may resolve the ambiguity.

## Escape transaction

States: INITIALIZING, TRACKING, ESCAPING, SAFE, MODEL_INVALID.

INITIALIZING obtains an unambiguous player/connection baseline, preferably in Nexus. UI must not claim protection before initialization succeeds. TRACKING evaluates the bound immediately before the earliest relevant outgoing report or local HP effect. Existing projectile/ground/area hook placements are reused after verifying final damage is available before those boundaries.

When escape is required, make one idempotent transition to ESCAPING. Gate the current and subsequent audited local damage inputs for the same player/connection, invoke the normal Nexus action, and record both request and local acceptance separately. Always permit the escape and connection-control messages. Do not alter incoming HP/death or fabricate an alive state. Preserve the latch while the transition is unresolved; do not clear it merely because another positive HP update arrived.

Local Nexus acceptance is evidence only of the client transition. Mark SAFE only after the verified destination/connection transition; keep the old generation's pending state isolated until that transition is established. The recorded late HP update after manual Nexus demonstrates why a button call alone must not reset accounting.

If the Nexus call is refused or fails, remain explicitly failed/escaping rather than returning to normal damage forwarding. A disconnect fallback requires its own verified behavior and cannot undo already-committed server damage. This design does not assume one currently exists.

## Timing, failures and coverage

- Never retire damage solely after 400 ms, 2 seconds, or a measured average network delay. Arrival intervals do not establish acknowledgement.
- A tick without an HP assignment does not provide a new HP baseline or retire a hit.
- A network stall alone does not prove HP loss. It increases uncertainty; leave the ledger intact and evaluate any next harmful input against the retained lower bound. Escape when the model can no longer represent the uncertainty safely.
- Capacity exhaustion, arithmetic overflow, inconsistent observations or unknown damage bounds must request escape before authorizing an input that cannot be accounted for. Never drop old ledger entries to keep playing.
- A meter reaching its limit is not itself a damage event. Process its actual damaging producer if one is intercepted; a server-only HP decrease is outside a pre-report prevention guarantee.
- Additional damage and healing mechanisms require explicit model coverage. Do not infer coverage from a shared HP setter or zero recorder drops.

## Validation before enabling this policy

1. Verify the ordered/exact-damage prerequisites or retain the broader uncertainty model. Audit every supported input for one accounting event and intervention before effect/report.
2. Replay the recorded captures, including delayed snapshots, overlapping hits, healing and manual Nexus. Report decisions and their lower bounds, not only whether an escape happened.
3. Model-test adversarial reorderings, omissions of unchanged HP, arbitrary nonnegative healing, hidden damage, duplicate identities, reconnects, cap overflow and Nexus refusal. Hidden/uncertain causes must broaden the model or invalidate its assumptions rather than incorrectly acknowledging hits.
4. Assert the invariant against each simulated ground-truth history: the bound never exceeds the possible current HP; no authorized input can be lethal under the modeled conditions. Compare exit timing with an oracle to quantify the cost of uncertainty.
5. Measure bounded CPU/memory cost and preserve the ordinary production build until the candidate is reviewed.

An initial exhaustive toy check passed 190,989 transitions with four ordered exact hits, three snapshots and arbitrary nonnegative healing. It checks the monotone-prefix lower-bound invariant under those assumptions; it does not validate the actual protocol or installed guard. Evidence: build/hp-sync-audit-20261020/design-check/result.json.

No gameplay policy was changed by this design document. The installed app remains the observation-only capture build.
