# Drop rates: investigation and capture design (issue #38)

Goal: estimate the true base drop rate of every item from every mob type, converging as data grows.
This issue builds the **capture layer and the persistent store**: every kill, every drop and every
loot factor that was active. How rates are calculated and shown is the next phase (section 4 has the
design).

Data checked on 2026-11-16: RealmHound's files, opened read-only on a copy
(`~/Library/Application Support/RealmHound/accounts/<uuid>/databases/`), about 4 days of play
(226 boss fights, 249 logged bags), and the il2cpp dump of game build `2ce88d8b…` (the one the
current compatibility profile covers).

## Decisions so far

| Topic | Decision |
|---|---|
| Kill source | Our own guard hook, for bosses and ordinary mobs alike |
| Drop source | Our own capture in the guard, independent of RealmHound and its filters |
| How a drop is registered | RealmHound's mechanism, copied, with no bag filter: every bag once per map, linked to the nearest hit mob the server removed in the next update (section 3) |
| What counts as a kill | A mob you damaged directly (projectiles and abilities) that then died. Pet damage doesn't count. Mobs only others hit are stored too, so their bags link. |
| Loot factors | Captured with every kill: character boosts (loot potions, seasonal, crucible, blood ritual, exaltations, loot enchants), dungeon factors (modifiers, hard or exalted versions) and server-wide loot events |
| Also captured | Map, time and character per kill; your damage and the mob's max HP; every bag, linked or not; game build, guard version and capture gaps |
| Kill and drop counts | True counts, incrementing forever from rollout; never weighted or altered |
| Grouping | Mob type is a bucket; mob class = bosses or minions of a dungeon (boss list from RealmHound's fights first, the game's own data later). Bag colour is the drop class; boosted bag variants count as their colour. |
| Default view | Orange and white bags (all colours captured) |
| Start | Counting starts when capture first runs; older RealmHound data is not imported. One exception: staging run 1 captured bags but no kills, so its boss kills come from RealmHound (`tools/drop_backfill.py`, kills with `landed_by = 'realmhound'`, bags linked as RealmHound credits them). Its minion kills stay missing. |
| RealmHound | Optional cross-check only |

## 1. Why not RealmHound

RealmHound has two databases per account (WAL mode):

| Database | Tables |
|---|---|
| `loot_history.db` | `loot_drops`, `loot_items`, `legacy_loot_*` (repair tables) |
| `combat_history.db` | `fights`, `fight_participants`, `encounter_runs`, `dungeon_time_totals`, `death_broadcasts`, `stat_awards`, loot-proof, repair and stat-card tables |

- **Kills:** `fights` covers bosses only (16 types in the sample against 37 mob names in the loot log).
  Nothing records ordinary mob deaths, which drop most set items (STs): 15 of the 28 orange bags in
  the sample came from 9 ordinary mob types (10 from bosses, 3 from chests).
- **Drops:** RealmHound saves a bag only when its own `loot_tracking` settings pass it. With cyan,
  brown, pink, egg and purple off, 0 cyan bags were saved and all 23 purple/pink bags held an
  enchanted item (kept by the enchant filter). Filtered bags are not stored anywhere.

It's still useful to check our capture: boss fights link to its bags by `map_seed`,
`mob_type = boss_object_type` and time (0.1–0.3 s after the fight ends; 0 unlinked boss bags).

## 2. What the game exposes

From the dump, confirmed against the installed binary where noted:

| What | Where | Evidence |
|---|---|---|
| Per-object damage method | `LKHPPBEGNOM.FNEBPDEDIJP` (base) `0x11291F0`, vtable `+0x628` | Args: `(self, bool, int damage, List<byte> effects, bool kill, projectile, bool, bool)`. Only players override it (`0x980AC0`, local player `0x1E12E40`), so every enemy uses the base. |
| Server "Damage" message (other players' hits) | class `MMDLNDNCGMA`: target `+0x10`, damage `+0x20`, kill `+0x24`, shooter `+0x2C` | Flag enum `DAMAGE_FLAG_KILL = 1` |
| Its handler | `HJMBOMEHGDJ.DJCPAGLIIBO` `0x926410` | Disassembly: calls `vtable[0x628]` at `0x926589` with the kill flag in `r8` |
| Your own projectile hits | `HBEAKBIHANL.BJDEACACFBD` (`hit_handler`) | Already in the profile; calls `vtable[0x628]` at `0x17d14d4` / `0x17d1430` |
| Object id, type props, position | `KJMONHENJEN`: props `+0x18`, id `+0x34`, position `+0x68` | Field types; position is already in the profile. The id field shares its obfuscated name with the Damage message's shooter field. |
| Item slots | `LKHPPBEGNOM` `int[]` at `+0x250` | Used for player equipment; expected to hold bag contents too |

One hook on the base damage method sees every hit in view: yours and other players' (from the
server). The **return address** says which: the Damage handler's call site means another player's
hit, the `hit_handler` call sites mean yours. The guard already tells callers apart this way.

**The kill flag misses most of your kills (staging run 1).** For your shots, `BJDEACACFBD` sets the
flag only when one shot's damage is at least the mob's HP (`+0x20C`), and the client never lowers
that HP itself: all 11 writes are in the server's stat handlers. So the flag is set only when the
server's last HP is already below one shot. Run 1 logged 0 kill flags while RealmHound saw 7 boss
kills and 25 of your bags. The death the client can be sure of is the server removing the mob:
the `Update` message's removed ids (`+0x30`), each passed to `HJMBOMEHGDJ.CGOAIMCNNON` (`0x923440`)
from `0x93606D`. Leaving your view removes a mob the same way, so the time since your last hit
tells the two apart.

## 3. Capture layer and store

### Principle

The guard (inside the game) stays dumb and fast: it copies a few fields into a ring in memory and
returns. Its writer thread, which already writes the guard log, turns them into lines. The app does dedupe, linking, naming and storage. Nothing about rates is computed at
capture time, so any later question can be answered from the raw rows.

```
game hit ─▶ guard hook ─▶ ring ─▶ writer (10 Hz) ─▶ logs/loot-<started>-<pid>.tsv ─▶ app importer (every 5 s) ─▶ SQLite
```

### Guard side

**Drops are registered the way RealmHound registers them** (its `LootDetector`, read from its
source), for every bag type, with none of its filters:

1. **Hit list.** A mob is "hit" once you hit it (RealmHound: your outgoing `EnemyHit`) or the server
   sends a `Damage` message for it with damage above 0 (anyone's hit).
2. **Kill.** When the server's `Update` removes a hit mob, it is a kill at its last server position.
   The mob then leaves the hit list, so one that left view and comes back needs new hits.
3. **Bag.** Each bag object counts once per map: the server sends it again each time it comes back
   into view, and those copies are skipped.
4. **Link.** Bags wait one tick. At each `NewTick`, the bags from the tick before last go to the
   nearest (no distance limit) of the kills since the last tick, because the server sends a bag one
   update before it removes the mob that dropped it. A bag with no kill then stays unlinked.

RealmHound also skips walls and gates as drop sources (from its object catalogue) and adds a few
special cases (Ice Tomb souls, boss overrides); none of that is copied yet. Positions are the
server's (tile x, y), as RealmHound uses.

**Hook A: base damage method (`0x11291F0`).** On every enemy hit, before the original:

1. A hit counts if it is yours or comes from the Damage handler with damage. Yours means a
   `hit_handler` return address (your projectiles) or a server Damage message whose shooter
   (`+0x2C`) is your object id (abilities the server resolves). A pet is its own object, so its hits
   are another player's. The shooter is in the message, not in hook A's arguments, so **hook C** on
   the Damage handler (`0x926410`) stores it in a variable that hook A reads during the same call.
   Mobs' damage method is an override (`0x980AC0`) that calls the base method from `0x980AEC`, so
   for those calls the caller is read one frame up (staging run 5: all 22 calls came from there and
   no kill was captured; run 7 linked 67 of 70 bags and matched RealmHound on all 5 of its drops).
2. The mob's entry (4,096 slots by object id, cleared on map change) adds your damage per source,
   others' damage, the time of the last hit and its max HP. The kill flag is ignored (below).

**Hook D: remove object (`HJMBOMEHGDJ.CGOAIMCNNON`, `0x923440`).** Only for the `Update` handler's
call (return address `0x936072`; other callers remove projectiles by a different key): a removed id
with an entry becomes a `kill` (source `removed`) at the mob's last server position, with the
damage and the milliseconds since the last hit, and the entry is cleared. Leaving view removes a
mob the same way; the app counts a removal as a death when it comes within 1 s of the last hit (to
be set from run 2).

**Hook F: NewTick (`HJMBOMEHGDJ.LDKKFMBNOCN`, `0x936DA0`).** After the tick's statuses, writes a
`drop` line for each bag of the tick before last with the kill it links to (step 4 above).

**Hook E: status apply (`HJMBOMEHGDJ.DBCEHNAEDCH`, `0x919FF0`).** Every object's stats go through it:
on arrival (hook B's method calls it) and on each server tick (`LDKKFMBNOCN`). Only your own
object's stats are kept; every object's server position is noted, for kills (its id is the connection's `CMAEBFGEKFC`, `+0x120`, set before the map's objects
arrive): every int stat except HP, MP and experience, written when it changes and all again on each
map. Text stats (your name) are never written. The loot factors (loot potions, seasonal, exaltation
bonus) are expected among them; RealmHound's per-drop flags tell which.

**Map info.** Once per map, beside its name, the guard writes your class (your object's type) and the
map info message (`NCAFKHMPKJC`) raw: ints at `+0x30` (seed?), `+0x34`, `+0x38`, `+0x50`, `+0x54`,
strings at `+0x28` and `+0x48` and the string list at `+0x58` (dungeon modifiers are expected in
one), and two connection ints (`+0x10C`, `+0x110`; character id?).

**Map boundary.** A map starts when the connection's own id changes. Run 1 moved the boundary only
once your new player object existed, after the map's first objects, so bags already on the ground
when you arrived were filed under the previous map.

**Checking a run.** `tools/drop_check.py` compares a capture session with RealmHound (read-only):
bag matches, bags counted once, kill links and their mob, time since the last hit for removal
kills, bag-to-kill distance, boss kills, and which fields equal RealmHound's seed, character id and
loot factors.

Cost: a flag test and a hash probe per hit, no allocation, no il2cpp calls. Only the game's main
thread calls this method (the guard already asserts that for its other hooks).

**Hook B: new object (`HJMBOMEHGDJ.AODEIADKBCC`, `0x936110`).** The server's `Update` message
(`PBMGGHIHACM`: new objects at `+0x28`, removed ids at `+0x30`) is handled by `CMKDLFEBNKD`
(`0x935C10`), which calls this method once per new object with its `ObjectData` (`KBGIJJLLFFD`).
The method then applies the object's first status straight away (it calls the status method
`DBCEHNAEDCH`, `0x919FF0`), so **a bag's contents arrive in the same message as the bag**.

The hook reads the message, not the game object:

| Field | Where |
|---|---|
| Object type | `ObjectData +0x10` (ushort) |
| Status | `ObjectData +0x18` → `ObjectStatus` (`BOEANEODCOA`): id `+0x10`, position `+0x18` (x `+0x1C`, y `+0x20`), stats `+0x20` |
| Each stat | `List<StatData>` (`CGOECEPGBBG`): stat type `+0x10` (byte), int value `+0x14`, string `+0x18` |

On each call it notes the object's type and position. If the type is in the bag-type set (20 ids)
and the bag is new on this map, it pushes a `bag` event with its id, position and the item ids from
its inventory stats, and queues it for linking (hook F). Cost is one set lookup per
new object; an `Update` arrives about 5 times a second. Later contents changes (players looting a
public bag) come through `DBCEHNAEDCH` and aren't needed: a drop is what the bag held at first.

**Events** (fixed records in the guard, single producer, single consumer; the writer thread writes
one tab-separated line each, columns in `guard/loot_core.h`):

| Event | Fields |
|---|---|
| `kill` | time, map instance, object id, object type, x, y, your damage by source, mob max HP, `removed`, ms since the last hit, others' damage |
| `drop` | time, map instance, bag object id, the kill's object id (0: none) |
| `bag` | time, map instance, object id, bag type, x, y, up to 8 item ids |
| `bag_stat` | bag object id, stat type, int value, first 40 bytes of the string value (one per non-item stat, so enchant data is kept raw for later) |
| `map` | time, map instance, map name, character id and class (on every map change) |
| `factors` | *Not built yet.* time, packed loot factors (character boosts and dungeon factors), only when they change |
| `announce` | *Not built yet.* time, first 48 bytes of a server announcement that mentions loot (from the chat the guard already reads) |
| `gap` | time, records lost because the ring was full |

Ring: 4,096 records (about 560 KB). At 2,000 kills an hour, bursts of a few hundred in a second still
fit before the next 100 ms write. On overflow the guard counts the lost records; the app stores the count as a
capture gap, so a rate is never silently wrong.

### App side

Every 5 s, off the main thread, the importer reads the new whole lines of each loot file (from the
offset it stored) in one SQLite transaction per file, and deletes a file once its game has ended. It:

- links each bag to the kill its `drop` line names (the guard decides, as RealmHound does). Position
  is used only for this: in a burst of kills (one AOE can kill ten mobs in the same tick), it is the
  only way to tell which mob type each bag came from. Bags with no kill stay unlinked (chests,
  mobs nobody hit);
- resolves names from the game's XML at display time only. Ids are the truth, names can change.

### Store

`~/Library/Application Support/Exalt Client Mac/drop_rates.db` (staging uses its own folder), WAL
mode, opened only by the app.

| Table | Columns | Notes |
|---|---|---|
| `sessions` | id, started, ended, game build, guard version | Provenance; lets a bad build's data be excluded |
| `maps` | id, session, instance, name, entered, character id, class | One row per map visit; gives the dungeon and character |
| `factor_states` | id, potions, seasonal, crucible, blood ritual, exaltation, loot enchant %, dungeon modifiers | One row per distinct combination |
| `kills` | id, map, time, object id, mob type, your damage, max HP, landed by you, factors | One row per death of a mob you damaged |
| `announcements` | session, time, text | Server-wide loot events |
| `bags` | id, map, time, object id, bag type, kill (nullable), x, y | Every bag, every colour |
| `bag_items` | bag, slot, item type | Contents when the bag appeared |
| `bag_stats` | bag, stat type, value, text | Every other stat the bag arrived with, raw (enchants are decoded later) |
| `capture_gaps` | session, from, to, lost events, reason | Ring overflow, app not running, map unknown |

Built so far: `sessions`, `maps` (no character yet), `kills` (your damage split into projectile,
second projectile path and ability), `bags`, `bag_items`, `bag_stats`, `capture_gaps`.
`factor_states` and `announcements` come with the loot-factor work.

Indexes: `kills(mob_type)`, `kills(map, time)`, `bags(kill)`, `bag_items(item_type)`. No pre-aggregated counters: a
`GROUP BY` over a year of rows is milliseconds, and raw rows keep every later question open.

Size: about 70 bytes per kill and 100 per bag with items; factor, map and announcement rows are
rare. 500 hours a year at 2,000 kills an hour is about 1 M kills, roughly 80 MB a year.

Kills of mobs only others damaged are stored (with your damage 0), so their bags link; they don't
count as your kills.

### Loot factors

The guard reads them on its existing timer, not per kill, and sends `factors` only when something
changes; each kill points at the current factor row. Candidate names in the game's code:
`BoostLoot`, `AddLootBonus`, `lootMult`, `BloodRitual`, `CruciblesManager`, `Seasonal`. Finding the
exact fields is part of this issue's reverse engineering. Boosted bag types (the 17xx variants) and
RealmHound's per-drop boost flags check the reading.

### Checking the capture

In staging, with RealmHound running as before:

- every RealmHound boss fight with `killed = 1` has a matching guard kill;
- every bag RealmHound saved has a matching guard bag with the same items;
- the guard also has bags RealmHound filtered out (cyan, plain purple, brown).

## 4. Rate math (built later)

Every query is a ratio of true counts from the store, filtered by mob (type or class), item (or bag
colour), and kills you hit.

**What counts as a drop** is decided at query time from the raw items (the store keeps every
item, so no question is closed off). Counts come from **items, not bag objects**:

- **Items:** every copy counts. Two of the same ST add 2 to that item.
- **Bag class:** each item has a class, its `<BagType>` in the game XML (white, orange, red, … in
  `DropBag` order, white highest). A kill's **top class** is the highest class among all its items,
  across every bag it left. The kill adds *one per item of its top class* to that bag class, and
  nothing to lower classes.

| Kill leaves | Item counts | Bag-class count |
|---|---|---|
| 1 bag: 1 ST, 2 purple, 1 cyan, 1 brown | each item +1 | orange +1 |
| 1 bag: 2 STs, 4 lower items | each ST +1 (+2 if the same ST), others +1 | orange +2 |
| 2 bags, 9 items (more than 8 overflow): 1 white, 4 cyan, 2 blue, 2 purple | each item +1 | white +1, however many bags show white |

So a bag-class rate is "x-class items per kill, counting only kills whose best item was class x",
and an item rate is "copies of item x per kill". Both are counts per kill, which is what the
Poisson range below assumes.

- **Observed rate** = drops ÷ kills.
- **Base rate** = adjusted drops ÷ kills, where a drop on a kill with boost multiplier *m* counts as
  1/*m*. Kills are never weighted, so the kill count stays exact.
- **Why it's unbiased:** a kill at multiplier *m* drops with chance *p·m*; each such drop counts
  1/*m*, so every kill contributes *p* on average.
- **Multipliers:** per boost state, (that state's rate across a whole mob class) ÷ (the no-boost
  rate), using orange and white bags so they settle fast. Revising a multiplier only recomputes
  adjusted drops.
- **Range:** 95 % from the drop count (Poisson). About ±60 % at 10 drops, ±20 % at 100, ±10 % at
  400; it depends on drops seen, not kills.
- **Check:** each boost combination's observed rate against what the multipliers predict;
  combinations that keep disagreeing keep their own rate.

Worked example (Ring of the Inferno, Abyss minions, base 0.3333 %):

| | Kills | Rings | Adjusted | Base |
|---|---|---|---|---|
| Before | 80,000 | 400 | 266.67 | 0.333333 % |
| + unboosted kill, no ring | 80,001 | 400 | 266.67 | 0.333329 % |
| + unboosted kill, ring | 80,001 | 401 | 267.67 | 0.334579 % |
| + kill at ×2.25, ring | 80,001 | 401 | 267.11 | 0.333885 % |

## 5. Viewing the data

### Questions and how each is answered

Each question is a count divided by a count: which items (item filter), from which kills or runs
(source filter), per what (unit: per kill, per run, or per bag of a colour). The view shows the
rate, "1 in N" and a 95 % range, so a rate from 3 drops reads as rough.

| Question | Counted | Divided by |
|---|---|---|
| How many mobs did I kill today, of what kinds? | kills since midnight, by mob | - |
| Drop rate of an item from a mob | copies of the item in bags linked to its kills | its kills |
| Chance of a bag colour from a mob class (Abyss minions, Lost Halls bosses) | kills of the class whose top bag is that colour | kills of the class |
| Chance of a Bow of the Void per Void run | runs with at least one Bow | runs (map visits where the boss died) |
| Chance a white bag is legendary | white-top kills whose white item is legendary | white-top kills |
| Chance of a legendary ST robe from an Abyss mob | legendary ST robes in bags from Abyss kills | Abyss kills |

- **Mob class:** the dungeon is the captured map name; the role comes from the game XML (`<Quest/>`
  or the `BOSSFIGHT` label is a boss; `MINION_WEAK`, `MINION_MID`, `MINION_STRONG` grade minions).
- **Item filter:** name, `BagType`, `SlotType`, `Tier` and labels (`UT`, `TAB_ST`, `ROBE`, ...)
  from the same XML. RealmHound already extracts it to `assets/xml`.
- **Rarity:** enchantment slots on the dropped item, from its raw bag stat. Decoded once a staging
  run shows which stat holds it.

### Storage for fast questions

- Raw rows stay the truth; nothing is overwritten or pre-counted.
- A **game catalog** in `drop_rates.db`, rebuilt when RealmHound's XML changes (#40, built):
  `objects(type, name, display_name, class, group_name, boss, minion_class, drop_source, labels)` and
  `items(type, name, display_name, bag_type, slot_type, tier, labels, origin)`. Labels and origin
  are comma-wrapped (`,UT,TAB_UT,`), so one label is `labels LIKE '%,UT,%'`. Filters like "bosses"
  or "ST robes" become joins instead of code. `drop_source = 0` marks objects RealmHound never
  credits a bag to (any class but `Character`: walls, gates, pillars); a type missing from the
  catalog counts as a source, as RealmHound fails open on unknown types.
- **Views:** `drops` (one row per item copy: kill, time, map, mob, bag, item) and `runs` (map visits
  with a boss kill). Every question above is one `GROUP BY` over them.
- **Indexes:** add `kills(time)` and `maps(name)` to the ones there. A year is about 1 M kills and
  a grouped count over it takes well under a second; add daily rollup tables only if a real query
  passes one second.

### What gets built, in order

1. **#38 (this PR): Drop data panel** in the main window: kills today by mob and map, how many of
   those kills left each bag colour, the latest white, orange and red bags, and capture health
   (bags linked, records lost, capture refused). It is how the staging run is checked.
2. **Game catalog:** the tables above, so views can name and group mobs and items.
3. **Drop rates window:** a larger window with Today, Mobs, Items and Dungeons tabs. Today shows
   today's kills; every other tab uses all the data kept. Each shows rates with "1 in N" and the 95 %
   range. Layout: [drop-rates-mockup.html](drop-rates-mockup.html) (sample numbers).
   Built (#41): `DropReport` in `app/GuardDropRates.swift` holds every query, `app/GuardDropRatesView.swift`
   the views. Rules as built:
   - **Best bag per kill** counts kills whose highest bag colour was that colour (the bag objects' colour,
     not each item's `<BagType>`), so it is a chance per kill. Item rates count copies. (The mob page of #50
     dropped it; the dungeon summary keeps the bosses' best bag per run.)
   - **A run** is a map visit in which a catalog boss (`<Quest/>` or `BOSSFIGHT`) died; per-run rates count
     runs with at least one. Realm quests count as bosses, so a realm visit with a quest kill is a run.
   - **Range:** exact Poisson below 50 drops, Byar's approximation above (within 0.01 %).
   - **Sprites:** the catalog keeps each object's `<Texture>` (or first `<AnimatedTexture>` frame) as
     `texture_file` and `texture_index`; `GameSprites` crops it from the atlas its flatbuffer entry names
     (1 `groundTiles.png`, 2 `characters.png`, 4 `mapObjects.png`).
4. **One window: the Drop rates tab (#45).** The main window has two tabs, Guard and Drop rates. Drop rates
   widens the window to about 1100 pt and stops it floating; Guard gets its own frame and Keep on top back.
   The top bar shows whether capture is running, the last kill, and capture health over all the data (kills,
   bags linked, records lost, capture refused); the Drop data panel, the Today view and the separate window are
   gone. Three panes:
   - **Dungeons and search:** every dungeon the catalog lists (a `<DungeonModTemplate>`, or one in
     `DropReport.dropTags`) and every map with kills, with its portal sprite; played ones first. Search shows
     two groups, Items (opens the item page) and Dungeons.
   - **Bags and drops:** a breadcrumb (dungeon › mob › group › item, each a step back; Esc steps back too),
     BOSSES and MINIONS rows of mob chips (a mob opens its page on the right; the grid stays dungeon-wide), then one row of tiles per bag,
     by the catalog's `<BagType>` (`DropBag(bagType:)`). Shinies ("X Shiny" by id) fold into their base item.
     Items of one `<Tier>` and slot family (weapons, armors, abilities, rings by `<SlotType>`) share a tile,
     which cycles its sprites only on hover. Possible drops are the items whose `ORG_*` tag is one of the
     dungeon's drop tags, plus every item that dropped there; not yet dropped ones are faded. Drop tags are the
     template labels that some item carries as its origin, except where `DropReport.dropTags` names them.
   - **Right pane:** the dungeon's best bag per run, a **mob page** (#50: kills, runs it died in, and every item it
     dropped, by bag, per kill, surest first; an item opens its page, Esc steps back to the mob), a tier group (the chance of any
     of it per run, then each item), or the **item page**. The item page is global: every dungeon it dropped
     in, surest first (by the low end of the per-run 95% range; places with no runs follow by their best mob
     per kill), each opening to its mobs' per-kill rates; the shiny's own rate; rarity of every copy as five
     cells. A list pick closes the item page; a dungeon row on it keeps it open.
   - **Rates** read "1 in N · ±X%": ±X% is 1.96 ÷ √drops, "too few drops" under 4. Zero reads "rarer than
     1 in N" (the top of the range). Runs are counted as sets of map ids, so any-of rates (base and shiny, a
     tier group) count a run once.
   - **Live data:** rows keep the order they were first shown in while you look; one whose count grew gets a dot.
   - **Rarity** is a copy's enchantment count from its bag's stat 80 (`Enchantments`). A copy with no part
     in the stat (potions, stones) or a cut-short part has no rarity and counts in none.
   - Out: base rates without boosts, until loot factors are captured.

## Phases

1. **#38: capture and store** (this design): hooks A, B and C, loot factors, the event ring, the app
   importer, `drop_rates.db` and the RealmHound cross-check. Needs the profile change and staging live
   tests.
   - Built (`guard/loot_core.h`, `guard/loot_capture.h`, `app/GuardDropRates.swift`): hooks A, B and
     C, the ring and loot file, the importer and store, bag-to-kill linking. Mob type comes from the
     object's type in hook B (kept per id), so the `+0x30` question below is moot.
   - Still to do: loot factors, character id and class, dungeon modifiers, announcements.
2. **Next phase: rates calculator and view** (sections 4 and 5).

## Open questions

- **Bag detection (spike done on 2026-11-16, from the dump and the binary):** hook B, contents
  included. Still to confirm in staging, by logging every stat of the first few bags:
  - which stat types hold the 8 item slots (classic protocol: 8–15);
  - where enchants live (likely a string stat; kept raw in `bag_stats` either way);
  - whether the kill's object position (`+0x68`, a float3) matches the bag's x/y directly or needs
    an axis swap.
- **Map boundary:** the guard starts a new map generation (and forgets damage) when hook B's
  connection object or your player object changes. Confirm a new connection per map in staging.
- **Second projectile path (`0x17d1430`):** it never carries a kill flag; its damage is stored
  apart so a staging run can show whose hits it is.
- **Kill flag trust:** answered by run 1: the flag almost never fires for your kills (see above).
  Run 2 checks hook D against RealmHound: every bag of yours should link to a `removed` kill, and
  those kills' time since your last hit sets the 1 s cut-off.
- **Mob type id:** confirm the object type the guard reads equals RealmHound's `mob_type`.
- **Abilities and pets:** confirm in staging that ability hits arrive either as your projectiles or as
  Damage messages with your id as shooter, and that pet hits carry the pet's id.
- **Dungeon and server factors:** which dungeon modifiers and server events affect loot, and where
  the game holds them. Needs your game knowledge as well as the dump.
- **Profile:** approve adding hooks A, B and C to the reviewed profile. Auditing it is your decision.
