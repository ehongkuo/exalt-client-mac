# Drop rates: investigation (issue #38)

Goal: count every mob you kill and every drop it gives, from zero, across play sessions, and show
drops ÷ kills per mob and per item with the sample size.

Data checked on 2026-11-16 from RealmHound's files, opened read-only on a copy
(`~/Library/Application Support/RealmHound/accounts/<uuid>/databases/`). About 4 days of play:
226 boss fights, 249 logged bags.

## Summary

- **Bosses: yes.** RealmHound already records every boss fight, whether it died, your damage and
  whether you were still there. Its drops link to those fights reliably.
- **Regular mobs: no source today, but the guard can add one.** Nothing RealmHound stores, and
  nothing the guard reads yet, sees a normal mob die. The game has one method that every hit on an
  object goes through, with a kill flag; hooking it counts every death you see (section 4).
  Regular mobs matter: most set-item (ST) bags come from them.
- **RealmHound logs only the bags its own filters pass.** A kill with no logged bag can mean "dropped
  nothing" or "dropped only bags RealmHound skips". Rates are only valid for items it always logs.

## 1. Where kills can come from

RealmHound has two databases per account, both in WAL mode:

| Database | Tables | Useful for kills? |
|---|---|---|
| `loot_history.db` | `loot_drops`, `loot_items`, `legacy_loot_*` (4 tables used to repair old links) | No. Drops only. |
| `combat_history.db` | `fights`, `fight_participants`, `encounter_runs`, `dungeon_time_totals`, `death_broadcasts`, `stat_awards`, `applied/pending_loot_proofs`, repair and stat-card tables | **Yes, for bosses.** |

Other files (`settings.json`, `profile.json`, `quests.json`, text logs) hold no kills. The text logs
print one `Fight recorded` line per boss fight and nothing for ordinary mobs.

`fights` has one row per boss (or boss phase) fight: `boss_object_type`, `map_seed`, `ended_at`,
`killed`, `encounter_run_id`. `fight_participants` has each player's `damage` and, for you
(`is_local = 1`), `end_status` (`present` or `nexused`). If you Nexus out, the fight is `killed = 0`.

Which bosses it tracks is set by RealmHound's `combat_history.track_*` settings (all on here). In this
sample: 16 boss types, against 37 mob names in the loot log.

| Source | Sees | Misses | Effort |
|---|---|---|---|
| RealmHound `combat_history.db` | Boss kills, your damage share, Nexus-outs | Every non-boss mob, chests, bosses RealmHound doesn't list | Read only, like drop alerts |
| Guard dylib | Today: HP, map, chat, quests, equipment. No enemies. | All mob deaths | New il2cpp reads of the game's enemy objects, a new profile entry per game build, more code in the injected dylib |
| Own packet capture | Everything RealmHound sees | — | Rebuilds RealmHound. Not worth it. |

`probe/` reads only your own damage, HP and death paths; nothing there touches enemies.

Polling the object list would not work: an enemy also vanishes when it leaves view range. Section 4
has the hook that does work.

## 2. Linking drops to kills

**Rule:** a bag belongs to the killed fight with the same `map_seed` and `mob_type = boss_object_type`
whose `ended_at` is closest before the bag's `timestamp` (window: 5 s before to 60 s after).

Checked on the sample:

| Check | Result |
|---|---|
| Boss bags with no matching fight | 0 |
| Delay from fight end to bag | 0.1–0.3 s |
| Bags per kill | 1 or more (Void Entity: 38 bags from 31 kills). Count kills, not rows. |
| Marble Colossus | Pre- and post-survival share object type 45073 and one `encounter_run_id`. Only the last phase drops; take the last killed fight of that type in a run. |
| Name drift | The same boss appears as "Marble Colossus" and "Marble Colossus (Post-survival)". Key on `mob_type`, not the name. |

**Kills that drop nothing** are simply killed fights with no linked bag. Red Demon (solo, 100 %
damage) and Prismimic each had one in the sample.

**But "no logged bag" is not "no drop".** RealmHound's `loot_tracking` settings log a bag only when
its colour is on or an item passes its item filters. Here cyan, brown, pink, egg and purple are off:
0 cyan bags were logged, and the 9 purple ones were logged only because they held enchanted items.
So:

- A **per-item rate** is valid when that item's bag is always logged (here: white, red, orange, gold,
  blue).
- An **any-drop rate** or a rate for a filtered bag is not valid unless all RealmHound tracking is on.
  That is a setting in RealmHound; we never write its files.

**Qualifying kills (soulbound damage threshold).** You can't see the threshold, but you can record
your damage share (`your damage ÷ all damage`) per kill. In the sample every killed Lost Halls and
Void boss produced a logged bag, down to a 1.1 % share, so the threshold was never visible. Bosses that
always give a logged bag (for example a guaranteed potion) prove you qualified; for others a kill
with nothing logged can't be told apart from a non-qualifying one. Suggested rule: count kills where
you were `present` and dealt damage; store the share so a cut-off can be added later.

**Loot boosts.** Each bag row has `loot_drop_active` and `loot_tier_active`. Boosts change rates,
but a kill with no bag has no boost flag, so a boosted/unboosted split isn't possible for zero-drop
kills. Show one combined rate first.

## 3. Storage and display

**Recommended: compute from RealmHound's tables, store only a start time.** Kills and bags are
already persisted by RealmHound. The app keeps a `dropRatesSince` timestamp (set when you first turn
it on or press Reset) in its own data folder
(`~/Library/Application Support/Exalt Client Mac`), and runs one read-only query across both
databases (`ATTACH`, like `LootLog` opens `loot_history.db`). It picks up RealmHound's own link
repairs and needs no sync code.

Alternative: copy counts into our own file with a cursor on `fights.id`. It survives RealmHound
deleting history, but adds a sync path and freezes any wrong link. Only worth it if RealmHound
prunes history, which is unknown.

**View:** a "Drop rates" tab or sheet next to drop alerts: one row per boss (name, dungeon, kills),
expanding to one row per item: `drops / kills = rate`, e.g. `3 / 31 · 9.7 %`. Sort by kills. Reuse:

| Existing code | Use |
|---|---|
| `RealmHoundPaths.accounts` | Find each account's databases; sum across accounts |
| `LootLog`'s read-only open | Same pattern for the joined query |
| `DropBag`, `DropBag.name` | Group items by bag; mark which bags RealmHound logs |
| `DropRarity` | Optional rarity column (enchant slots) |
| `GuardPaths.dataFolder` / settings file | Store `dropRatesSince` |

## 4. Ordinary mob kills from the guard

STs come mostly from ordinary mobs. Orange bags in the sample:

| Source of the orange bag | Mobs | Bags | Items |
|---|---|---|---|
| Bosses | Void Entity, Marble Colossus | 10 | Epic quest chests only |
| Ordinary mobs (Abyss of Demons, Lost Halls) | 9 | 15 | Ring of the Inferno, Molten Mantle, Golem Garments, … |

RealmHound logs orange bags, so only the kill count is missing.

Found in the game build the current profile covers (`2ce88d8b…`, checked against the 2026-11-06 dump
and the installed binary):

| What | Where | Evidence |
|---|---|---|
| Server "Damage" message, sent for other players' hits | class `MMDLNDNCGMA`: target id `+0x10`, damage `+0x20`, kill flag `+0x24` | The dump names its flag enum `DAMAGE_FLAG_KILL = 1` |
| Its handler | `HJMBOMEHGDJ.DJCPAGLIIBO` at `0x926410` | Calls `target->vtable[0x628]` with the kill flag in the 5th argument (`r8`) |
| Per-object damage method | `LKHPPBEGNOM.FNEBPDEDIJP` (base) at `0x11291F0`, slot 79 | Same method the guard's `notify` hook overrides for the local player; your own projectile hits reach it through the existing `hit_handler` callsites. Only players override it, so every enemy uses the base. |
| Mob identity | `LKHPPBEGNOM` `+0x1C8` → `ObjectProperties` (`id` string at `+0x38`; numeric type in `BaseProperties`) | Field types in the dump |

So one hook on the base method, acting only when the kill flag is set, sees every enemy death in view:
yours (client-predicted) and other players' (from the server). Dedupe by object, since a death can be
reported more than once.

What this needs and doesn't cover:

- **A profile change.** A new hooked method (`0x11291F0`, entry bytes) in the reviewed profile, which
  then needs your audit. The hook adds work on every hit in the game, so it must stay tiny: check
  the flag, push the object type into a ring buffer, return.
- **Kill flag trust.** Your own kills are the client's prediction; a rare mismatch with the server is
  possible. Not live-tested yet.
- **"You hit it."** To count only kills you could get loot from, the guard also notes objects your
  projectiles hit (same hook, local hits). Abilities and pets that damage without a projectile would
  be missed by that check.
- **Link to drops.** RealmHound's `mob_type` should equal the object type; to be confirmed live.

## Proposed split

Decision (2026-11-16): bosses and ordinary mobs together in #38.

1. **Boss drop rates from RealmHound:** the query, the start time and Reset, the view, and a note on
   which bags are counted. Read-only, testable with a fixture DB.
2. **Ordinary mob kills from the guard:** the hook above, a kill log in the app's data folder, and
   the same view. Needs the profile change and live testing.

With guard kills, the app keeps its own kill log, so the "start time only" storage above holds for
boss kills; mob kills are stored by the app.

## Open questions

- Should rates count only kills where you were present, or also apply a minimum damage share?
- Show only items whose bag RealmHound always logs, or show all with a warning?
- Does RealmHound ever prune or rewrite old fights? If yes, switch to our own stored counts.
- Treat quest chests, Event Chests and Treasure Pots (no kill, opened instead) as out of scope?
- Approve adding the damage-method hook to the profile (your audit decision)?
- Count guard-seen boss kills too, or keep RealmHound's boss fights (they have damage share)?
- RealmHound's `track_soulbound` setting is off; what it filters is unclear and may matter for
  part 1.
