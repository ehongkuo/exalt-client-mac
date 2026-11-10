# Nexus on death hardening plan

Status: revised 6 November 2026 (proof-only clearing, validated offline). No gameplay policy has changed. This plan addresses the remaining
gaps in policy version 8 ([current policy](nexus-on-death.md)). Each phase is a separate PR, runs in
Dry Run before it is armed, and is judged against recorded captures.

## Model

What the guard can and cannot observe:

1. The client detects hits (projectiles, ground and area damage) and reports each one to the server.
   A report identifies the hit, not its amount: the server computes the damage itself, from the same
   base damage and defense and conditions. The guard reads the client's own calculation and treats it
   as exact: isolated hits in captures matched to within 1 HP, which regeneration accounts for. The
   exception is a hit that itself applies a debuff: in one sample the server applied a shot that
   inflicted a condition at 95 HP where the client calculated 48 (see Phase 0 status).
2. Not every HP loss passes through a hook the guard sees. Damage over time is driven by the server
   with no client report: captures show bleeding (about 3 HP per update) and the Ice Citadel frostbite
   drain, and suffocation drains about 100 HP/s (wiki; not captured). Poison is not a player status.
3. The server owns HP. It applies the damage it computes, plus all healing (regeneration, potions,
   pets, allies), and sends HP in periodic updates, about every 200 ms. An update carries only the
   net result.
4. Because HP is net, HP alone cannot tell which reported hits an update contains. Healing in the
   same interval hides damage, and HP also moves for reasons no report explains: regeneration,
   heals without "+N" text, damage over time, hits the server reduced, and one unexplained loss.
   The plan never uses HP changes to decide whether a hit has landed.
5. The round trip from reporting a hit to receiving an update that contains it varies. Earlier
   samples ranged 167–667 ms ([calibration](damage-latency-calibration.md)); the 6 November capture
   shows 330–620 ms typically (median 434 ms) and one 834 ms case when updates bunched after a pause.
   The tail under lag is unmeasured, and round trips are quantized to the update interval.
6. Updates carry their server build time and the round trip of the latest client reply, and the
   client replies to every update on the same ordered connection as its hit reports. The
   round-trip meaning is inferred from the field's behavior (Phase 2 item 2).

The plan therefore clears hits only by message order (the ordering proof, Phase 1). Neither HP
changes nor elapsed time ever clear a hit. Server HP is the baseline and already accounts for every
heal and every untracked loss; the guard adds only the hits the server cannot have applied yet.

## Issues addressed

The scenarios below were run against the real `probe/fatal_policy.h`.

| ID | Issue | Effect | After this plan |
|---|---|---|---|
| A | The server applies a hit later than the 800 ms quiet allowance while ticks stay healthy. The quiet rebase forgets the hit. Observed once: 834 ms. | Missed escape | Removed by Phase 1: hits clear only by the ordering proof, never by time |
| B | Untracked HP loss (DoT, scripted or server-only damage) is treated as a tracked hit and retires it. | Missed escape | Removed by Phase 1: HP changes never clear hits. The loss itself is still unanticipated until an update shows it (G) |
| C | Server damage exceeds the local calculation, mainly when a protective buff ends or a debuff arrives before the client learns of it. Observed once: +47 HP on a hit that applied a debuff. | Missed escape | Phase 3: charge debuff-carrying hits their worst case |
| G | HP lost with no report (bleeding, frostbite, one unexplained 112 HP loss) cannot be anticipated before the next update. The baseline absorbs it once an update lands. | Missed escape, bounded by one interval's loss | Phase 3: drain allowance while a damage-over-time condition is set; the unexplained loss is accepted as a one-off (7 November) |
| D | Healing in the same update as a hit hides part of the hit. | Early escape only | Removed by Phase 1: heals do not affect clearing |
| E | A positive hit after a stall of at least 1.5 s escapes regardless of HP. | Early escape only, intended | Unchanged |
| F | Leftover pending damage persists while HP is unchanged, because updates that leave out HP cannot trigger a quiet rebase. | Early escape only | Removed by Phase 1: the ordering proof clears on any update |

## Phase 0: measurement

1. Turn the A–F scenarios into fixtures in `tests/probe/fatal_policy_tests.c`. Assert the current
   outcomes, including the A and B deaths, so each fix visibly changes an expected result.
2. Add a replay tool that runs recorded captures in `build/` through `fatal_policy.h` and reports,
   per policy version: false escapes, deaths without Nexus, and the minimum projected margin.
3. Extend `probe/analyze_latency.py` to report local damage minus HP drop for each isolated hit,
   to quantify C outside condition changes.
4. Take a probe capture to decode the condition bits for Sick, Armored, Armor Broken, Exposed,
   Curse, Petrify and Invulnerable. Check whether a bullet-carried effect changes the
   recorded condition mask before the next server update. Phase 3 needs it: the 6 November capture
   found a mismatch on a debuff-carrying hit, and Bleeding (`0x8000`) is the only decoded bit.

### Phase 0 status

Items 1–3 are implemented:

- `tests/probe/fatal_policy_tests.c` pins the v8 outcomes for A–F.
- `probe/replay_policy.py` replays captures through `probe/policy_replay.c`, compiled against one or
  more policy headers, and reports each scope as `escape_before_death`, `missed_death`,
  `request_without_death` or `quiet`, with minimum projected HP and rebase counts. Compare a
  candidate with `--policy probe/fatal_policy.h --policy CANDIDATE.h`. Outcomes are ground truth only
  for passive captures; only probe and sync-capture builds record the needed events.

> **Update, 9 November 2026:** v8 and v9 (`probe/fatal_policy.h`, `probe/fatal_policy_v9.h`) and their
> tests were removed once v10 shipped; the replay driver now supports v10 only. They remain in git
> history at `51e2f40`, for example `git show 51e2f40:probe/fatal_policy.h`.
- `probe/analyze_latency.py` reports `damage_mismatch`: server HP loss minus local damage for
  isolated reports, and non-terminal excess losses.

First results, 2 November 2026: 8 local captures contain replayable events (5 passive). Policy v8
produced no requests or deaths in them; the closest projected margin was 22 HP. Isolated residuals
were 0 three times and -1 once. An apparent 30 HP excess in `guard-31242.tsv` was a pairing
artifact: three 44–54 damage hits landed in consecutive updates, and the cumulative test below
explains every decrease in that capture.

`probe/analyze_untracked.py` tests whether every HP loss comes from a client damage report. Healing
only shrinks decreases, so summed decreases can never exceed summed reported damage unless the server
applied damage the client did not report. Unspent damage from hits that healing masked can hide a
later untracked loss from that cumulative test, so the tool also attributes each decrease to the
reports received 100–1500 ms before it and reports the excess, tagged by the conditions at the time.

Results across 5 captures with damage (100 reports, 186 decreases):

- **Direct damage matches.** In the 6 November sync capture (`SYNC-20261105T154122Z`, build
  `2ce88d8b`; 37 projectile, 11 terrain and 4 area reports, 67 decreases) almost every decrease equals
  the attributed reports minus 1 HP of regeneration, 330–620 ms after the report (median 434 ms). All
  projectile reports came through the duplicated notification tail added for build `b09e1a2d`.
- **Bleeding is untracked.** Condition word 0 bit `0x8000` (Bleeding, by the game's condition order)
  was set three times for 2.4–3.8 s. Each update in those windows lost about 3 HP more than the
  reports explain: 101 HP over 34 decreases, with no report.
- **A debuff-carrying hit exceeded the local calculation.** At 162.9 s the client calculated 48 and
  the server applied 95. A word 1 condition bit (`0x20000`) appeared 20 ms after the hit. One sample.
  > **Update, 10 November 2026:** RealmHound's condition map (below) names word 1 `0x20000`
  > **Exposed**, not Armor Broken. Exposed's −20 DEF accounts for at most 20 of the 47 HP, so this
  > sample is still unexplained.
- **One hit landed after 834 ms**, beyond the 800 ms allowance: updates paused for about 470 ms and
  then arrived together, so the hit was in the first of two bunched updates.
- **Frostbite drains** in the Ice Citadel captures (`guard-42155`, `guard-88966`) account for 1,055 HP
  of excess. `guard-88966` (15 October build) also has 72 HP of excess under undecoded condition bits
  and 1,192 HP flagged `report_larger_than_loss` (possibly healing-masked); not yet investigated.
- Suffocation, ground hazards other than the tested lava, and server-scripted damage remain
  untested.

```sh
python3 probe/replay_policy.py --input build --input "$HOME/Library/Application Support/Exalt Client Mac/logs" \
  --json build/policy-replay/v8.json
```

### Condition capture (item 4)

The diagnostic records the condition-mask words (phase 29, `flag2=1`) at each damage notification,
each HP assignment, and on any change during polling. Since 10 November it also records, per
projectile hit, the effect IDs the hit applies (phase 31) and the projectile's damage inputs (phase 32).
Its startup line `damage_context_ready … shot=111` confirms the three projectile fields were found.

1. `sh probe/build-probe.sh`, then open `build/damage-diagnostic/Start Hit Diagnostic.command`
   (observation only). Use a disposable character; enter Nexus and wait for readiness.
   `python3 build/damage-diagnostic/enemy_debuffs.py | grep -i <dungeon or enemy>` lists the
   enemies that inflict each debuff.
2. For each effect, start at full HP, take one hit from an enemy known to inflict it, step away until
   the condition ends, then take one plain hit for comparison. Note the effect and approximate time.
3. Cover bullet-carried debuffs (Armor Broken, Exposed, Curse, Sick) and
   self/ally buffs (Armored, Invulnerable, a defense buff), including a buff expiring during combat.
   Sources listed by RealmEye include Urgles, Zombie Hulks and Crawling Grey Spiders (Armor Broken),
   Killer Bee Queen and Crystallised Crawlers (Exposed), Corrupted Casters and Void Shades (Curse),
   and Parasitic Blobs or Toxic Sewer water (Sick).
4. Manually Nexus, wait five seconds and quit normally to bundle the session.
5. Optional, for the dungeon modifier question in the
   [per-hit settlement report](per-hit-settlement-report.md#open-questions): repeat a few plain hits in
   a dungeon with Lethal, and against a Ferocious or Glass boss. Note the modifiers.

Run `python3 build/damage-diagnostic/analyze_conditions.py <session folder>`. `effect_ids` maps each
effect ID to the condition bits that appeared after hits carrying it. `implied_def_on_plain_hits`
shows, for each projectile field, base minus damage on hits with no conditions: the field that gives
one constant value per character is the base damage, and that value is the DEF the client used. Add
`--hits` for the per-hit rows, and run `probe/analyze_untracked.py` on the same folder for the server
side (excess HP loss after each hit).

Expected bits, from RealmHound's `combat/damage.rs` (MIT; word 0 bit = `1 << (id − 1)`, word 1 bit =
`1 << (id − 32)`, which also predicts our captured Bleeding `0x8000`):

| Word | Armored | Armor Broken | Invulnerable | Petrified | Curse | Exposed |
|---|---|---|---|---|---|---|
| 0 | `0x2000000` | `0x4000000` | `0x1000000` | | | |
| 1 | | | | `0x8` | `0x40` | `0x20000` |

`probe/analyze_untracked.py` names these bits in its excess report. The diagnostic also records the
effect IDs each hit applies (phase 31, the notification's `List<byte>`; `hit_effects` in
`probe/analyze.py`). The game's own code boxes Armored 16, Invulnerable 17, Armor Broken 55, Curse 58
and Exposed 59 next to the condition names (registration near `0x6b7060`, build `2ce88d8b`), which is
not the numbering behind the bits above, so the capture has to settle which IDs the hits carry.
`python3 probe/enemy_debuffs.py` lists every enemy projectile that applies Armor Broken, Exposed or
Curse, with damage and duration, from the installed game's XML (Zombie Hulk, Crawling Grey Spotted
Spider, Corrupted Caster and Void Shade among about 400 projectiles on build `2ce88d8b`).

Analysis: map each effect to the mask bit that changes, and compare when the bit changes relative to
the hit's notification and the next incoming HP assignment. A change at or before the next server
tick that carries the effect indicates local application; a change only with a server update
indicates server control.

## Phase 1: per-hit settlement by the ordering proof (A, B, D, F)

Replace amount-based retirement and the global quiet rebase with one projection:

> projected HP = latest server HP − pending hits − Phase 3 drain allowance

Escape when a new hit takes the projection to 0 or below, before its report is sent. The terms below
are illustrated in the [frontier timing terms](https://claude.ai/artifact/NZRuFXRY5L2rZSTPks6Svh)
page, including a simulation of normal, download-stall and upload-stall cases.

### Pending hits

Each detected hit is recorded with its damage: the local calculation, or the Phase 3 charge for a shot
that applies a damage modifier. Hits are kept in report order. A hit stays pending until the ordering
proof clears it. Clearing too late counts a hit twice and can only cause an early escape; clearing too
early can cost a death, so the rule errs late.

### The ordering proof

Hit reports and the client's replies to updates share one ordered connection, so the server cannot
receive a reply before the hits sent ahead of it. The proof never reads HP, so heals, regeneration,
damage over time and server-side adjustments to a hit cannot make it clear early. A hit the server
reduced or ignored also clears correctly: after the proof, server HP is the truth for it.

1. **Pair the hit with the next reply.** The client replies to every update; the first reply sent
   after the hit travels behind it.
2. **Track the round-trip field.** Each update carries the round trip of the latest reply the server
   received. A repeated value means no new reply: ignore it. A new value belongs to the reply whose
   build time + value falls between the previous and current update build times, which proves the
   server had that reply, and everything sent before it, by build time + value.
3. **Bound the hit.** The first such proof for a reply at or after the hit's paired reply gives the
   hit's proof bound: the server received the hit by then at the latest.
4. **Clear the hit** on the first update built at least c after the bound, where c is an upper bound
   on how long before its build an update stops taking messages. That update contains it. Phase 2
   measured c = 0 with at least 91 ms of margin; use c = 200 ms (one update interval of margin).

The proof uses only build times and round trips read from updates, plus the order of two client
sends; clock offset and one-way delays drop out. A stall delays the proof instead of retiring hits
against stale HP: the 834 ms case in the Phase 0 capture simply stays pending.

If the proof cannot run (no round-trip field, a reply that cannot be paired), the remaining hits stay
pending. That can only cause an early escape; it is logged, and the capacity and stale escapes bound
it. There is no timing fallback.

### Unchanged

- HP increases never restore hits.
- Updates without HP clear hits like any other update (closes F).
- Keep the stale escape (E), the capacity escape and the escape latch.
- Log every clear with its proof bound and latency, and every unexplained decrease, for monitoring.

### Not used: accounting

Earlier revisions cleared hits by accounting: an update's decrease plus its "+N" heal text was the
damage it applied, cleared from the oldest pending hits (candidate `probe/fatal_policy_v9.h`; the
earlier PR #15 prototype matched sums instead). It is dropped because every distortion of HP needs
its own exception: heals without text, regeneration, damage over time, hits the server reduced, and
unexplained losses, after which it has to suspend and fall back to the proof anyway. The proof
alone clears within 0–2 updates of the applying update (Phase 2), so accounting would only clear
slightly sooner. The floating-text hook stays a diagnostic: it supplies ground truth for validation.

## Phase 2: validation and calibration (A)

Phase 1 runs in Dry Run once item 1 shows no early clears (done), and is armed after item 2.

1. **Validate offline (done).** Replay every sync capture. For each hit whose applying update can be
   located, the proof may not clear before that update. Report early clears (must be 0) and lateness
   in updates.
2. **Confirm the assumptions.**
   - **Round-trip field:** it is the latest single measurement, not an average. About 20% of
     captured updates repeat the previous value exactly, which supports this. Holding replies back
     in a probe build would confirm it: the value should grow by the hold time.
   - **Same socket:** hit reports and replies are sent on the same socket. Confirmed: the probe's
     send hook records both only for the connection's socket.
   - **Processing order:** the server handles a connection's messages in arrival order. Assumed.
   - **Lag:** a laggy capture checks the proof when round trips go well beyond 866 ms.
3. **Set c** from the same replays: the smallest value with no early clear, plus one update interval
   (200 ms from item 1's results).
4. **Monitoring.** Run `probe/analyze_proof.py` on every new sync capture. Any early clear keeps
   Phase 1 in Dry Run until it is explained.

**Results (6 November 2026).** [`probe/analyze_proof.py`](../probe/analyze_proof.py) checks
the proof against the update that applied each hit. The applying update is found offline by
oldest-first accounting with heal text (ground truth only, not a clearing rule). In captures without
heal text, only isolated hits count. Results:

| Capture | Hits checked | Early clears | Lateness at c = 0 (updates) |
|---|---:|---:|---|
| `SYNC-20261105T154122Z` | 9 | 0 | 0: 7, 1: 2 |
| `SYNC-20261106T010147Z` | 2 | 0 | 0: 2 |
| `SYNC-20261106T011149Z` (heal) | 42 | 0 | 0: 31, 1: 7, 2: 4 |

- **No early clears:** none of the 53 hits cleared early, including the 834 ms hit, which cleared on
  its own update.
- **Margin:** the update before each applying update was built at least 91 ms before the proof
  bound, so c = 0 never clears early. Following item 3, c = 200 ms adds one update of margin. That
  makes clears 1–3 updates late instead of 0–2. The median clear comes 550 ms after the hit at
  c = 0, against 484 ms for when the hit was actually applied.
- **Server-reduced hits:** one 93 hit at full HP (5 November, 150 s) changed HP by only 2. The proof
  cleared it on the update the server built after receiving it, which is correct. Accounting would
  have kept it pending.
- **Limits:**
  - 53 hits from three captures, all in normal latency (worst round trip 866 ms).
  - The meaning of the round-trip field is inferred from its behavior; holding replies back (item 2)
    has not been tried.
  - Processing order on the server is assumed, not observed.

## Phase 3: conditions and damage over time (C, G)

Local damage equals the server's for ordinary hits; captures show two exceptions (Phase 0 status).
Effect rules below are from the [RealmEye status effects page](https://www.realmeye.com/wiki/status-effects)
and the [Ocean Trench page](https://www.realmeye.com/wiki/ocean-trench) (checked 6 November 2026);
rates marked approximate need a capture before they are relied on.

### Damage over time (G)

The server applies these with no client report. With proof-only clearing they no longer disturb
pending hits, but nothing anticipates them: they, debuff overcharges (C) and the unexplained 112 HP
loss in the heal capture are now the main remaining causes of a missed escape. While one is active,
subtract its expected drain until the next update from the projection.

| Effect | Rate | Can kill | Detection |
|---|---|---|---|
| Bleeding | 20 HP/s, and stops regeneration from VIT; captures show about 3 HP per update | No | Condition word 0 bit `0x8000` (captured) |
| Frostbite (Blizzard, Ice Citadel) | "Rapid" once the meter is full; captures show 13–15 HP per update, sometimes 33 | Assume yes | Frostbite meter at player `+0x530` reaches its maximum |
| Suffocation (Ocean Trench) | About 100 HP/s once oxygen reaches 0 (approximate) | Yes | Breath meter at player `+0x52c` reaches 0 |

Use the published rate where it is stated (bleeding: 4 HP per 200 ms update) and the measured worst
case otherwise. Bleeding cannot kill on its own but still lowers HP before the next hit. Poison is not
a status effect on players and needs no handling.

### Damage modifiers (C)

The server computes a hit's damage from the player's conditions when it processes the report. The
local calculation can differ when a condition changes in between, most importantly when the hit itself
applies one: the 95/48 sample fits a shot whose Armor Broken applied before its damage.

| Effect | Damage rule | Projection |
|---|---|---|
| Armor Broken | DEF counts as 0 (overrides Armored) | A shot that applies it: damage with DEF 0 |
| Exposed | DEF − 20, may go below 0 | A shot that applies it: damage with DEF − 20 |
| Curse | Damage × 1.25 after defense | A shot that applies it: damage × 1.25 |
| Armored | DEF × 1.5, rounded down | While active: charge hits as if it had ended |
| Petrify | Damage × 0.9 | No change (safe direction) |
| Invulnerable | No damage from attacks; hazards such as lava still damage | No change: hazard reports still count |
| Invincible | Cannot be hit | No change: no hits are detected |
| Sick | Stops all HP recovery | No change. Decreases are exact while Sick, which makes captures useful for validation |

Charge a shot with the effects its projectile definition applies, combined in the game's order
(defense modifiers, then Curse), until the update that contains it. RealmHound's port of the client
formula fixes that order: DEF 0 for armor piercing or Armor Broken, else DEF × 1.5 while Armored; then
Exposed −20; then the larger of damage − DEF and a 10% floor; then Invulnerable 0, Petrified × 0.9,
Curse × 1.25. Where to hook: the damage calculator gets no usable projectile argument, but the
projectile notification that follows receives the hit's effect list, so the extra charge belongs
there. It needs either the shot's base damage or the player's DEF, and neither is read yet. If an effect's order relative to
the server's calculation cannot be confirmed, the charge is still only an overestimate until that
update. Confirm with the Phase 0 condition capture (item 4): the bit for each listed effect, and
whether the 95/48 pattern repeats for Armor Broken and appears for Exposed and Curse.

### Monitoring

Keep `damage_mismatch` in `probe/analyze_latency.py` and the excess report in
`probe/analyze_untracked.py`, and run both on every new capture. Add each newly decoded condition bit
to `DOT_CONDITIONS` or the damage-modifier table.

## Validation for every phase

1. Unit fixtures, including the A–F scenarios and new edge cases.
2. Replay against all recorded captures, compared with the previous policy.
3. Live Dry Run, reviewing logged predictions.
4. The live [beach stress tests](beach-stress-tests.md).
5. Update [Nexus on death](nexus-on-death.md) and the README.

Order: Phase 0 and Phase 2 item 1 are done. Next, Phase 1 in Dry Run, then the rest of Phase 2, then
Phase 3; Phase 3 measurement runs alongside as captures arrive. Phases 1–3 change only the prediction
policy and are easy to revert. They add production game-memory reads already mapped by the probe:
Phase 1 the update's round-trip field and the reply sends (production already reads the update's
tick ID and build time and hooks `SendMessage`); Phase 3 the condition words, the breath and
frostbite meters, and each projectile's effect list.

Useful captures: a laggy session, combat with healers or pets nearby, suffocation in the Ocean
Trench, shots that apply Exposed or Curse, and gear changes that alter max HP.

Heal capture (sync probe v3, observation only): the probe records the green "+N" text the game
shows over your own character (phase 47, `own_object_text` in `analyze_sync.py`), with the HP at
that moment and the next server HP update. It tests whether burst heals (pet Heal, Priest tome,
potions) can be subtracted from a drop so that drop + heals = damage. Questions: does "+N" arrive
before or with the update that applies it, and is it capped at max HP?

Result (SYNC-20261106T011149Z-PxKEgm, 2ce88d8b; pet Heal and a healing beacon, 46 heals):
- Every "+N" arrived in the same frame as the HP update that applied it, never earlier or later.
  Two heals in one update show as two texts (+80 and +90 for a +171 update).
- "+N" is the HP actually gained: capped at max HP (+27, +11 near full), and absent at full HP.
  Change − heal text = +1 (VIT regen) in 28 of 29 uncapped updates (one +2), and 0 in all 11
  updates that reached max.
- In the 5 updates where a heal and a hit landed together (for example 881 → 859 with "+80"),
  drop + heal text was exactly the pending hit − 1 (103 or 113 hits). Heal text makes burst
  heals fully explainable: damage applied = drop + heal text + regen (0–3). That made this capture
  the ground truth for validating the proof (Phase 2). It is not a clearing rule (Phase 1).
- Pet Heal +90 every 3.0 s; beacon +80 every ~0.4 s (each update while inside).
- Damage numbers over the player (text kind Damage) appear with the local hit report, not the
  server update, so they add nothing beyond the existing hit hook.

## Deferred fallback: safety reserve (A, C)

The goal is to make the prediction assumptions hold, not to buffer against them: the ordering proof
never clears a hit early (A, B) and server damage equals the charged damage (C). A reserve, escaping when projected
HP falls to a margin rather than to zero, is deferred until that work is done.

Revisit it if, after Phases 1–3, replay shows early clears, or monitoring shows unexplained
decreases or damage mismatches, at a rate that makes a missed escape an unacceptable risk. The
112 HP loss in the heal capture is the first unexplained decrease. It couldn't be reproduced and is
accepted as a one-off (7 November). If such losses recur, a reserve is the simplest cover.

A complete implementation exists on branch `feat/nexus-safety-reserve` (closed PR #13): a saved
`reserve=N` setting (0–25% of max HP), live protocol version 7, reason 4, and
`replay_policy.py --reserve`. Its replay of the 5 passive captures (all at 225 max HP) found no
requests without a death at 5% (11 HP) and one at 10% (22 HP), on the closest 22 HP margin.
