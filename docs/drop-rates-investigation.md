# Drop rates: investigation (issue #38)

Goal: count every mob you kill and every drop it gives, from zero, across play sessions, and show
drops ÷ kills per mob and per item with the sample size.

Data checked on 2026-11-16 from RealmHound's files, opened read-only on a copy
(`~/Library/Application Support/RealmHound/accounts/<uuid>/databases/`). About 4 days of play:
226 boss fights, 249 logged bags.

## Summary

- **Bosses: yes.** RealmHound already records every boss fight, whether it died, your damage and
  whether you were still there. Its drops link to those fights reliably.
- **Regular mobs: no source today.** Nothing RealmHound stores, and nothing the guard reads, sees a
  normal mob die. Getting it means new reverse engineering in the guard.
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

The guard route for ordinary mobs is open research: a timer-polled object list sees an enemy vanish,
but vanishing also happens when it leaves view range, so a death needs HP reaching 0 first. That
would need its own investigation.

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

## Proposed split

1. **Boss drop rates from RealmHound** (this issue): the query, the start time and Reset, the
   view, and a note on which bags are counted. Small, read-only, testable with a fixture DB.
2. **Ordinary mob kills from the guard** (separate issue, research first): find whether the game's
   enemy objects can show deaths reliably. Large, needs live testing and a profile change, and only
   useful once part 1 exists.

## Open questions

- Should rates count only kills where you were present, or also apply a minimum damage share?
- Show only items whose bag RealmHound always logs, or show all with a warning?
- Does RealmHound ever prune or rewrite old fights? If yes, switch to our own stored counts.
- Treat quest chests, Event Chests and Treasure Pots (no kill, opened instead) as out of scope?
- Is part 2 (ordinary mobs) wanted, and at what priority?
- RealmHound's `track_soulbound` setting is off; what it filters is unclear and may matter for
  part 1.
