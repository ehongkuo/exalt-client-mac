# Loot factors: what changes drop chance, and what we capture (issue #58)

Checked on 2026-11-18. Sources:
- `drop_rates.db`: captures from Nov 16 to 18.
- RealmHound's `loot_history.db`, read-only.
- The game XML RealmHound extracts (`mods.xml`, `enchantments.xml`, `equip.xml`).
- The il2cpp dump of the current build.
- Stat names from the realmlib client (`src/models/stat-type.ts`).
- Values the XML lacks come from the official patch notes, linked below.

## Everything that can change your drop chance

"Stated" means the game data or patch notes give the number. "Live" means where the client holds it while you play.

| # | Factor | Size | Stated? | Live in the client | Captured today |
|---|---|---|---|---|---|
| 1 | Loot Drop Potion | ×1.5 (community) | No | stat 67 `LD_TIMER`, seconds left | Yes |
| 2 | Loot Tier Potion | up to +3 tiers, not more drops | No | stat 68 `LT_TIMER` | Yes, never on |
| 3 | Lucky Clover (20 min), Golden Lucky Clover (60 min) | both potions' effects (`LDBoosted`, `LTBoosted`) | No | stats 67 and 68 | Yes |
| 4 | Gear enchantments | +0.5% to +3% loot drop each (`LootBonus`: Loot Bonus I–IV 1/1.5/2/2.5%, XP or Dust Loot Bonus 0.5–1.25%, Lucky Streak 3%, an awakened ring 2%) | Yes, XML | stat 80 `ENCHANTMENTS` (text) with the item types in stats 8–11 | From capture format 4: your four equipment slots' part of stat 80 (`player_texts`). Before it, item types only |
| 5 | Dungeon modifiers | per mob and per item: `EntityDropMultiplier` ×1.01 to ×1.15+ on 205 of 249 modifiers (some only for bosses, minions or one potion). Reward modifiers: LOOTING +50%, REWARDING +25% | Yes, XML | the map info's modifier list, for example `ELITEMINIONS_2;FEEBLEMINIONS_2;` and a grade letter | **Yes, every map** (`map_info.info_58`) |
| 6 | Crucible | the season's loot bonus: +10% in Season 31 (it was +10% to +20% before) | Patch notes; the client shows it (`Crucible.LootBonusHeader`) | Stat 128, a text stat: non-empty while the Crucible is on (RealmHound's own check, found in its code). The guard keeps your text stats from #58 on. `CruciblesManager` holds the season, not your character | Yes, from the second map after launch; unknown on the first |
| 7 | Blood Ritual | ×1.1 at −10% HP, ×1.15 at −15%, ×1.25 at −20%; ×1 at −5% or less | Patch notes, and the client's definitions feed | stat 155 (its tier) | Yes, always 0 |
| 8 | Drop accelerators | +33% stat potions (1.5 h); +50% artifacts (24 h, 1 week); `TIEREDLOOTBOOST` class bias | Yes, XML (`StartAccelerator`) | `AcceleratorsManager` (its own message) | **No** |
| 9 | Server-wide loot events | e.g. "1.5× loot" events | In the announcement only | chat announcements | **No** |
| 10 | Seasonal character | No drop bonus found. Seasonal raises enchantment-slot odds (rarity), and only seasonal characters can use the Crucible | XML (`seasonalChanceIncrease`) | stat 24 | Yes, 1 on every kill |
| 11 | Eligibility | soulbound loot needs enough of your damage on the mob; below it, no roll at all | No | your damage vs the mob's max HP (already per kill) | Yes |

Checked and ruled out:
- Stat 102 is projectile speed, stat 113 exaltation damage, stat 152 account level. None is a loot factor.
- No item carries a loot bonus outside its enchantments: `LootBonus` appears only in `enchantments.xml`.

Open:
- How factors combine (adding the percentages or multiplying them) isn't stated anywhere. It's measurable once
  enough kills mix factors.
- Whether a loot event shows anywhere but chat.

## How sure the potion reading is

- **Stat 67 = drop potion**, high. A boosted (17xx) bag needs a running boost, and all 1,955 of them came while the
  rule below said one was running. RealmHound's `loot_drop_active` agrees on all 312 of its drops, but it
  counts a boost as running past its end: 27 normal bags drop in that window, so it isn't an independent check.
- **The per-kill rule:** take the last stat 67 value on the same map and subtract the seconds since it was read.
  The game sends the timer only on map entry and when you drink. The timer pauses in safe zones and while
  offline, so the rule never subtracts across maps.
- **Unexplained:** 25 normal brown, pink or white bags while a boost was clearly on. That's 1% of boosted bags.
- **Measured:** boosted ÷ normal over 3,051 item drops is ×1.37, ±12% roughly. This mixes in the unknown
  enchantments.

## What this means for the data so far

Known for every kill: potion state, dungeon modifiers, Blood Ritual (off), crucible (off) and seasonal (on).
Unknown: gear enchantments (only the item types), accelerators and loot events.

## How the app uses them

`app/GuardLootProfile.swift` has the numbers and the one rule that combines them (`LootMath.combine`).

- **Multiplier:** potion ×1.5 × (1 + gear %) × the dungeon's modifiers × Crucible ×1.10 × Blood Ritual. Multiplying is
  assumed until kills that mix factors say otherwise.
- **Dungeon modifiers:** each `EntityDropMultiplier` applies to a mob with all of its `reqLabels` and none of its
  `excludeLabels`. Item-only ones (`itemId`, such as ×100 stat potions) are left out of the rate.
- **Base rate per kill:** drops ÷ the sum of the kills' multipliers, each from the factors on its map at the kill.
  Kills before format 4 count their gear as no bonus (at most +12% off). Per-run and bag-colour rates stay as seen.
- **Copies (#62):** item and tier rates count every copy, so a double drop counts 2 and a rate can top 100% (130%: one
  sure, a 30% chance of a second). Boosts past 100% add copies, so the multiplier math holds for sure drops too.
- **Yours:** base × your multiplier now; the dungeon's modifiers count only for mobs of the dungeon you're in.
- **Live:** the loot bar on top of the Drop rates tab (Details opens the rest in the right pane) reads the newest running session from `drop_rates_v2.db`, imported every second.
- **Your state now** comes from the guard's capture, filled from RealmHound's `account_data.json` (read only) where the
  guard has nothing yet. That is only the first map after launch: the guard's hooks go in after you load, so it misses
  the map's first full stats. RealmHound, if it runs, fills class, level, gear, enchantments, potion and Crucible there;
  its newest `last_live_update` is the live character. Without it they show as unknown until the first portal.
- **Not yet:** accelerators and loot events; the window says so.
- **To check on a staging run:** that your stat 80 has one part per inventory slot like a bag's, and stat 155's scale.

## Sources

- [Season 31 patch notes](https://hub.realmofthemadgod.com/news0/updates0/s31notes1) (Crucible, Blood Ritual)
- [Season 31 public testing notes](https://hub.realmofthemadgod.com/news0/updates0/s31pt1) (Blood Ritual tiers)
- [Season 30 part 2 notes](https://hub.realmofthemadgod.com/news0/updates0/motmg) (earlier Crucible values)
- [RealmHound issue 64](https://github.com/pillarzz/RealmHound/issues/64) (Blood Ritual tier in stat 155)
- [Realm Shop: loot boosters](https://realmshop.info/product-category/informational/restoratives-and-boosters/loot-boosters/) (timers stack in time, not strength)
- [RealmEye loot guide](https://www.realmeye.com/forum/t/guide-to-loot-and-drop-rates/60740) (×1.5 potion)
