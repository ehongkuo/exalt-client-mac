# Loot factors: what changes drop chance, and what we capture (issue #58)

Checked on 2026-11-18 against `drop_rates.db` (captures from Nov 16 to 18), RealmHound's `loot_history.db`
(read-only), the game XML RealmHound extracts, and the il2cpp dump of the current build. Stat names come from
the open-source realmlib client (`src/models/stat-type.ts`).

## The factors

| Factor | Effect, from the game data | In the game stream | Captured today |
|---|---|---|---|
| Loot Drop Potion | "more loot", 30 min; the multiplier isn't in the XML (community: ×1.5) | stat 67 `LD_TIMER`: seconds left, sent on map entry and when you drink one | Yes |
| Loot Tier Potion | up to +3 tiers, 30 min | stat 68 `LT_TIMER` | Yes; never active since capture began |
| Lucky Clover | both potions' effects, 20 min | expected as stats 67 and 68 | Yes (as above) |
| Loot enchantments on gear | +0.5% to +3% loot drop each (`LootBonus` in `enchantments.xml`: Loot Bonus I–IV, XP/Dust Loot Bonus, Lucky Streak and others; 14 in all) | stat 80 `ENCHANTMENTS` (a text stat) on your player | **No**: the guard drops your text stats. Item types in slots 8–11 are kept |
| Drop accelerators | +33% stat potions (1.5 h), +50% artifacts (24 h or 1 week): `acceleratorId="DROPLOOTBOOST"` with a label; `TIEREDLOOTBOOST` biases class drops | `AcceleratorsManager` (its own message, not a stat) | **No** |
| Seasonal character | Shown in the XML only as a higher enchantment-slot chance; any effect on drop rate is unknown | stat 24 `SEASONAL_CHARACTER` | Yes: **1 on every captured kill** |
| Crucible | "better rewards" with trade-offs; no multiplier in the XML | stat 128 `CRUCIBLE`; `CrucibleActive` in the character list | Yes: always 0 |
| Blood Ritual | "the more you give, the more you receive"; no multiplier in the XML | `BloodRitualActive` in the character list; the in-game stat isn't found yet | **No** |
| Dungeon modifiers | unknown per modifier | stat 121 `MODIFIERS` (text) | **No** (`map_info` is raw) |
| Server-wide loot events | unknown | server announcements | **No** |

## How sure each boost reading is

- **Stat 67 = drop potion**, high. A boosted (17xx) bag needs a running boost, and all 1,955 of them came while the
  rule below said one was running. RealmHound's `loot_drop_active` agrees on all 312 of its drops, but it
  counts a boost as running past its end: 27 normal bags drop in that window, so it isn't an independent check.
- **The per-kill rule:** take the last stat 67 value on the same map and subtract the seconds since it was read.
  The game sends the timer only on map entry and when a potion is drunk. The timer pauses outside the game, so
  the rule never subtracts across maps.
- **Unexplained:** 25 normal brown, pink or white bags while a boost was clearly on. Perhaps those bags have no
  boosted look. That's 1% of boosted bags.
- **The multiplier, measured:** boosted ÷ normal over 3,051 item drops (565 normal and 4,010 boosted kills,
  pooled per mob and item) is ×1.37, ±12% roughly. The seasonal state and enchants are unknown, so this mixes
  every factor except the potion.

## What this means for the data so far

The potion state is known for every kill. Every kill is from a seasonal character with no crucible. Gear
enchantments, accelerators, Blood Ritual, dungeon modifiers and loot events are unknown for all of them.
