# Per-hit settlement: findings and implementation start

6 November 2026, build `2ce88d8b`. Summarizes what the sync captures show, the clearing rule that
follows from them, and the first implementation steps. The full design is in the
[hardening plan](nexus-hardening-plan.md) (Phases 1–3); policy v8 is described in
[Nexus on death](nexus-on-death.md).

## What the sessions show

| Session | What it covered | Main result |
|---|---|---|
| `SYNC-20261105T154122Z` | Projectile, terrain and area hits; bleeding; a debuff shot | Decreases equal the reported hits − 1 HP regen, 330–620 ms after the report (median 434). One hit landed after 834 ms. Bleeding drained 101 HP with no report. One debuff shot: client 48, server 95. |
| `SYNC-20261106T010147Z` | Pet and beacon heals (heal hook on the wrong functions) | HP alone: pet +91 every 3.0 s, beacon +81 on every update while inside. |
| `SYNC-20261106T011149Z` | Pet and beacon heals, hits during heals, death at the end | 46 heal texts, each in the same frame as the update that applied it. Every update explained by hits + heals + regen except one. v8 replay escapes 328 ms before death. |

### 1. Client damage is exact

For ordinary hits, the client's own damage calculation matches the server's. Every isolated decrease
equals the hit − 1 HP of regeneration. The exception is a shot that applies a debuff (Armor Broken
likely): the server computed 95 where the client computed 48, because the debuff applied first.

### 2. The server applies hits in report order

In the heal session, clearing the oldest pending hit first explained every update. That includes
bunched sequences where a 113 hit arrived before two 103 hits and the updates applied them in that
order. Report order is application order.

### 3. Burst heals are visible and exact

The pet, the beacon and (by the same mechanism) allies show green "+N" text over the player. That
text:

- arrives in the same frame as the HP update that applies it, never before or after;
- equals the HP actually gained: capped at max HP (+27, +11 near full), and absent at full HP;
- appears once per heal, so two heals in one update show as two texts (+80 and +90 for +171).

This made the heal session the ground truth for validating the proof. After subtracting heal
text, what's left of an HP rise is regeneration: +1 in 28 of 29 uncapped
updates (one +2), and 0 in all 11 updates that reached max. In the 5 updates where a heal and a hit
landed together, HP change − heal text was exactly the hit − 1.

### 4. Round trip and timing

Reports reach the update that contains them in 334–866 ms (median 468) in the heal session. The
834 ms case in the first session came from updates bunching after a pause. Timing alone can't tell
when a hit has landed.

### 5. Untracked losses exist

- **Bleeding** (condition bit `0x8000`): about 3 HP per update, no report.
- **Frostbite** (Ice Citadel, older captures): 13–15 HP per update, sometimes 33.
- **One unexplained 112 HP loss** at 41.18 s in the heal session, at full HP, with no hit report, no
  server damage message, no damage text and no condition change. It matches one of the 113-damage
  shots. Its source is unknown: an unhooked hit path, or server-side damage. No hits were pending.
  The ordering proof never reads HP, so a loss like this can't clear pending hits, but nothing
  anticipates it either. This is the main remaining risk.

### 6. Burst damage needs pending hits

The character died at 71.9 s after six hits in 0.6 s. At the lethal hit, server HP still read 481,
but 417 HP of earlier hits hadn't been applied. Policy v8 (and the new rules) projected −35 HP and
would have escaped 328 ms before the death. Without pending-hit tracking, the projection would have
been 417 HP too optimistic.

## The rule

> projected HP = latest server HP − pending hits − drain allowance

Escape when a new hit takes the projection to 0 or below, before its report is sent. Hits are kept
pending in report order. Clearing late can only cause an early escape; clearing early can cost a
death, so the rule errs late.

### Ordering proof (the only way a hit clears)

Hit reports and the client's replies to updates share one ordered connection, so the server can't
receive a reply before the hits sent ahead of it.

1. **Pair** each hit with the first reply sent after it.
2. **Date replies.** Each update carries the round trip of the latest reply the server received. A
   new value belongs to the reply whose build time + value falls between the previous and current
   update build times. That reply, and every hit sent before it, reached the server by build time +
   value. A repeated value proves nothing and is ignored.
3. **Clear** the hit on the first update built at least c after that bound (c = 200 ms).

The proof never reads HP, so heals (with or without text), regeneration, damage over time, the
112 HP loss and hits the server reduced can't make it clear early. If the proof can't run, hits stay
pending. There is no timing rule.

**Replayed offline** ([`analyze_proof.py`](../probe/analyze_proof.py)) on 53 hits from three
captures: 0 early clears, including the 834 ms hit. At c = 0 the update before each applying update
was built at least 91 ms before the bound, so c = 200 ms leaves one update of margin. Clears come
1–3 updates after the applying update at c = 200 ms (0–2 at c = 0).

Accounting (decrease + heal text, oldest first) was the earlier primary rule. It is dropped: it
needs an exception for every HP distortion and still falls back to the proof. It is only used
offline as ground truth.

### Unchanged from v8

- **Escapes:** keep the lethal, stale and capacity escapes and the escape latch.
- **Baseline:** HP increases move the baseline and never restore hits.

### Damage modifiers and DoT (Phase 3)

With proof-only clearing these no longer disturb pending hits. They are what the projection still
can't anticipate.

| Effect | Handling |
|---|---|
| Bleeding | Drain allowance 4 HP per update (20 HP/s) |
| Frostbite (meter full) | Drain allowance from the measured worst case (about 35 HP per update) |
| Suffocation (breath 0) | Drain allowance about 20 HP per update (100 HP/s), not yet captured |
| Armor Broken, Exposed, Curse on the hitting shot | Charge the shot its worst case (DEF 0, DEF − 20, ×1.25) |
| Armored active | Charge as if it had ended |

## How to start implementing

Each step is a separate PR. Steps 1–2 are offline only and change no gameplay behavior.

1. **Candidate policy (v10) with the ordering proof.** Starting from
   [`fatal_policy.h`](../probe/fatal_policy.h):
   - Record the reply each hit is paired with, and clear pending hits only when an update's new
     round trip proves that reply (build time ≥ bound + c).
   - Stop debiting HP drops from pending hits, and remove the quiet rebase (`fatal_server_tick`'s
     800 ms rule).
   - Add fixtures to [`fatal_policy_tests.c`](../tests/probe/fatal_policy_tests.c): the four cases
     in [`test_proof.py`](../tests/probe/test_proof.py) (proof on the applying update, early clear
     without c, repeated round trip, reply sent before the hit), the 834 ms late hit, the
     server-reduced 93 hit, a stall with no new round trip, and the final burst from the heal
     session.
   - [`fatal_policy_v9.h`](../probe/fatal_policy_v9.h) (accounting) is superseded and not needed.
2. **Replay v10.** Feed phase 40–41 round trips and reply sends from captures into
   [`policy_replay.c`](../probe/policy_replay.c) and
   [`replay_policy.py`](../probe/replay_policy.py), then compare v8 and v10 on every capture:
   - **v10 must not fail where v8 succeeds:** no missed escapes that v8 would have made.
   - **Report requests without a death.** A few more than v8 are acceptable: v10 never clears on
     time alone, so it holds hits slightly longer.
   - **Early clears** must stay 0 (`analyze_proof.py`).
3. **Production reads.** Production already reads the update's tick ID and build time and hooks
   `SendMessage`. Add the round-trip field and tell replies apart from other sends; add the field
   offset to the compatibility profile.
4. **Confirm the round-trip field.** A probe build that holds replies back for a set time: the field
   should grow by the hold time. Check the proof on a laggy capture too.
5. **Dry Run v10.** Run normal play and the [beach stress tests](beach-stress-tests.md), and review
   every logged clear with its bound and latency.
6. **Investigate the 112 HP loss.**
   - **Capture:** another capture at full HP near the same enemies, to see whether unreported hits
     recur.
   - **Hit paths:** check the six cloned hit handlers for one that isn't hooked.
   - **Why it matters:** if its source can't be found and charged, it needs a reserve.
7. **Phase 3 conditions.** Add drain allowances and debuff charges as each condition bit is decoded.

## Open questions

- **The 112 HP loss** (section 5): what applied damage with no report?
- **The round-trip field:** confirmed as the latest single measurement only by its behavior so far.
- **Server processing order:** assumed to follow arrival order on the connection.
- **High latency:** all 53 checked hits had round trips of at most 866 ms.
