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
  anticipates it either. **Accepted (7 November):** it couldn't be reproduced, so it's treated as a
  one-off miss rather than investigated further.

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
   [`fatal_policy.h`](https://github.com/ehongkuo/exalt-client-mac/blob/51e2f40/probe/fatal_policy.h):
   - Record the reply each hit is paired with, and clear pending hits only when an update's new
     round trip proves that reply (build time ≥ bound + c).
   - Stop debiting HP drops from pending hits, and remove the quiet rebase (`fatal_server_tick`'s
     800 ms rule).
   - Add fixtures to [`fatal_policy_tests.c`](https://github.com/ehongkuo/exalt-client-mac/blob/51e2f40/tests/probe/fatal_policy_tests.c): the four cases
     in [`test_proof.py`](../tests/probe/test_proof.py) (proof on the applying update, early clear
     without c, repeated round trip, reply sent before the hit), the 834 ms late hit, the
     server-reduced 93 hit, a stall with no new round trip, and the final burst from the heal
     session.
   - [`fatal_policy_v9.h`](https://github.com/ehongkuo/exalt-client-mac/blob/51e2f40/probe/fatal_policy_v9.h) (accounting) is superseded and not needed.

   **Status (6 November):** done as [`fatal_policy_v10.h`](../probe/fatal_policy_v10.h). It isn't
   active: the probe still includes v8.
   - **API:** v8's `fatal_reset`, `fatal_server_hp`, `fatal_damage` and `fatal_requested`, plus
     `fatal_reply(p, build)` for each reply sent. `fatal_server_tick(p, ns, tick, build, rtt)`
     takes the round-trip field and returns the number of hits cleared.
   - **Tests:** [`fatal_policy_v10_tests.c`](../tests/probe/fatal_policy_v10_tests.c) cover the
     fixtures above, plus wrapped build times, the capacity overflow and the stale escape.
2. **Replay v10.** Feed phase 40–41 round trips and reply sends from captures into
   [`policy_replay.c`](../probe/policy_replay.c) and
   [`replay_policy.py`](../probe/replay_policy.py), then compare v8 and v10 on every capture:
   - **v10 must not fail where v8 succeeds:** no missed escapes that v8 would have made.
   - **Report requests without a death.** A few more than v8 are acceptable: v10 never clears on
     time alone, so it holds hits slightly longer.
   - **Early clears** must stay 0 (`analyze_proof.py`).

   **Status (6 November):** done. The driver takes the round-trip field on each tick return and a
   `Y` line per reply; `FATAL_PROOF_MARGIN_MS` can be set at compile time. Seven passive scopes
   have round trips traced:

   | Capture | Hits | v8 | v10 (c = 200 ms) |
   |---|---:|---|---|
   | `guard-89778` (heal, death) | 43 | Escape 328 ms before death, projected −35 | Same hit and time, projected −235 |
   | `guard-83663` (two scopes) | 52 | Quiet | Quiet, all 52 cleared |
   | `guard-87759` | 27 | Quiet | Quiet, all 27 cleared |
   | `guard-40486` | 4 | Quiet | Quiet |
   | `guard-31242` (225 max HP) | 11 | Quiet, lowest projection 22 | Requests without a death at −2 and −20 |

   - **No missed escapes.** v10 matches v8 on the only death.
   - **One new early escape** (`guard-31242`, 16 October build, round trips about 200 ms). Hits of
     44–54 against 225 max HP. Each request came within about 300 ms of an update that had already
     applied the previous hit, before the proof could clear it. True HP at those moments was 52 and
     76. The character later fell to 25 HP. c = 0 removes the −2 request but not the −20 one: a
     hit sent just before a reply is proven only once that reply's round trip is reported, which is
     inherently up to two updates after the hit lands.
   - **Captures without the sync trace** (`guard-88966`, frostbite) can't be replayed: with no round
     trips, v10 never clears, and it requests early. Production needs the round-trip read (step 3).
     Losing that read in production would have the same effect: hits pile up until the lethal
     escape fires early. Step 3 must detect a failed read and log it.
3. **Production reads.** Production already reads the update's tick ID and build time and hooks
   `SendMessage`. Add the round-trip field and tell replies apart from other sends; add the field
   offset to the compatibility profile.

   **Status (6 November):** done. [`hit_probe.h`](../probe/hit_probe.h) now includes v10 in both
   the production guard and the probe builds:
   - **Round trip:** the tick hook reads `BJEENKGELLO.PHBFAKPBEAB` before forwarding (the message
     is pooled afterwards). Other messages pass 0, which keeps the last value.
   - **Replies:** the `SendMessage` hook records `FKGDHGJDNAO.DLIOLEFCGDD` (the tick's build
     time) for replies on the tracked connection's socket, on the main thread.
   - **Failed read:** if either field is missing at install, Nexus on death refuses to start
     (`fatal_proof_fields`).
   - **Logs:** `guard_proof_clear` replaces `guard_quiet_rebase`.
   - **Profile:** both fields are in the native-audited `2026-11-06` profile (added on review,
     6 November), checked against that build's dump: `BJEENKGELLO.PHBFAKPBEAB` UInt32 at `0x1c`,
     `FKGDHGJDNAO.DLIOLEFCGDD` UInt32 at `0x20`. Game-update reports now flag them if they move.
4. **Confirm the round-trip field.** A probe build that holds replies back for a set time: the field
   should grow by the hold time. Check the proof on a laggy capture too.
5. **Dry Run v10** ([session steps](v10-dry-run.md)). Run normal play and the [beach stress tests](beach-stress-tests.md), and review
   every logged clear with its bound and latency.

   **Status (7 November):** first session `guard-10176` passed. It ran with Armed off on a
   disposable character with 1,205 max HP and ended in one death.
   - **Startup:** `fatal_policy version=10` was logged, with no `fatal_proof_fields` refusal.
   - **Clearing:** 63 proof clears. Pending stayed at 0–106 HP during the first fight and returned
     to 0 between fights. Proven replies trailed sent replies by about 4 (round trips 277–457 ms
     plus c).
   - **Requests:** all 3 came in the fatal burst, with none at safe HP.
     - The first fired at server HP 235 with 8 hits pending (248), projected −13, 0.2–0.65 s
       before death.
     - The 7 hits before the lethal one total 217, so withholding that hit would likely have left
       18 HP.
     - Then a spray of 31-damage hits: 899 pending at death.
   - **Missed escapes:** none.
   - **Not covered:** heals while hit, long sessions and high latency. The worst valid frame gap
     was 0.52 s.

   **Armed session (7 November):** `guard-11113` escaped.
   - **Setup:** Armed on, potions off, the same character.
   - **The request:** one, at server HP 72. One 48 hit was still in flight and a new 48 hit took
     the projection to −24.
   - **The escape:** the request was called (`result=1`). The new hit and one more were withheld
     (`reports_suppressed=2`). Nexus followed, with no HP at or below 0 and no death screen.
   - **Heals:** a +69 heal landed mid-burst while hits were pending, and no early request fired.
     There were 33 proof clears.
6. **The 112 HP loss: accepted, not investigated** (7 November). It couldn't be reproduced. If
   unreported losses recur in later logs, the options are checking the six cloned hit handlers for
   one that isn't hooked, or a reserve.
7. **Phase 3 conditions.** Add drain allowances and debuff charges as each condition bit is decoded.

## Open questions

- **The 112 HP loss** (section 5): source unknown, accepted as a one-off.
- **The round-trip field:** confirmed as the latest single measurement only by its behavior so far.
- **Server processing order:** assumed to follow arrival order on the connection.
- **High latency:** all 53 checked hits had round trips of at most 866 ms.
- **Dungeon modifiers:** does the local calculation already include them? No capture so far was
  checked against a modified dungeon. The installed build's `mods.xml` (game files of 6 November,
  inside `resources.assets`) has four kinds that change damage taken:
  - **Enemy damage multipliers** (Tame, Ferocious, Glass, Elite, Stone, Remnant; boss or minion):
    ×0.7 to ×1.36. Safe if the multiplier is already in the shot damage the client reads.
  - **Player DEF and max HP** (Exposed −5 to −20 DEF, Armored +3 to +12, the Armor Broken modifier
    −30 DEF, Spongy DEF ×0.5 and max HP ×1.25). Safe if they land in the DEF and max HP the client
    uses.
  - **Lethal I–IV** (`CurrentHealthDamage` 0.01–0.04; the descriptions say 1.25–5%): every hit adds
    a share of current HP. If only the server adds it, every hit is undercharged, the same
    missed-escape direction as C. Until confirmed, charge the larger percentage of the HP baseline
    per pending hit.
  - **Anemia and Vigorous** scale healing (×0.7 to ×1.3). This changes auto-potion pacing only;
    heals never clear hits.

  Test with dry-run captures in a Lethal dungeon and against a Ferocious or Glass boss, and compare
  `damage_mismatch` in `probe/analyze_latency.py`. Logging the map's modifier tokens (sent in
  `MapInfo`) would let captures be grouped by modifier.
