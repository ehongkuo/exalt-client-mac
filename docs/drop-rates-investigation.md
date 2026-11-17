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
| What counts as a kill | A mob you damaged directly (projectiles and abilities) that then died. Pet damage doesn't count. |
| Loot factors | Captured with every kill: character boosts (loot potions, seasonal, crucible, blood ritual, exaltations, loot enchants), dungeon factors (modifiers, hard or exalted versions) and server-wide loot events |
| Also captured | Map, time and character per kill; your damage and the mob's max HP; every bag, linked or not; game build, guard version and capture gaps |
| Kill and drop counts | True counts, incrementing forever from rollout; never weighted or altered |
| Grouping | Mob type is a bucket; mob class = bosses or minions of a dungeon (boss list from RealmHound's fights first, the game's own data later). Bag colour is the drop class; boosted bag variants count as their colour. |
| Default view | Orange and white bags (all colours captured) |
| Start | Counting starts when capture first runs; older RealmHound data is not imported |
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

So one hook on the base damage method sees every enemy death in view: yours (client-predicted) and
other players' (from the server). The **return address** says which: the Damage handler's call site
means another player's hit, the `hit_handler` call sites mean yours. The guard already tells
callers apart this way.

## 3. Capture layer and store

### Principle

The guard (inside the game) stays dumb and fast: it copies a few fields into a shared ring and
returns. The app does dedupe, linking, naming and storage. Nothing about rates is computed at
capture time, so any later question can be answered from the raw rows.

```
game hit ─▶ guard hook ─▶ shared event ring ─▶ app poller (4 Hz) ─▶ SQLite (one transaction per poll)
```

### Guard side

**Hook A: base damage method (`0x11291F0`).** On every enemy hit:

1. If the hit is yours, add its damage to the target's entry in a small "your damage" table
   (open-addressed, 1,024 object ids, cleared on map change). Yours means: a `hit_handler` return
   address (your projectiles), or a server Damage message whose shooter (`+0x2C`) is your object id
   (abilities the server resolves). A pet is its own object, so its hits don't match. The shooter
   is in the message, not in hook A's arguments, so **hook C** on the Damage handler (`0x926410`)
   stores it in a variable that hook A reads during the same call.
2. If the kill flag is set, the target is in the "your damage" table, and the id isn't in the
   recent-kill set (256 ids, so a death reported twice counts once): push a `kill` event and
   remember the id.
3. Call the original.

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

On each call: if the object type is in the bag-type set (20 ids), push a `bag` event with its id,
position and the item ids from its inventory stats; otherwise return. Cost is one set lookup per
new object; an `Update` arrives about 5 times a second. Later contents changes (players looting a
public bag) come through `DBCEHNAEDCH` and aren't needed: a drop is what the bag held at first.

**Events** (fixed 64-byte records, single producer, single consumer, in a new shared file next to
the live state):

| Event | Fields |
|---|---|
| `kill` | time, map instance, object id, object type, x, y, your damage, mob max HP, who landed the kill (you / server) |
| `bag` | time, map instance, object id, bag type, x, y, up to 8 item ids |
| `bag_stat` | bag object id, stat type, int value, first 40 bytes of the string value (one per non-item stat, so enchant data is kept raw for later) |
| `map` | time, map instance, map name, character id and class (on every map change) |
| `factors` | time, packed loot factors (character boosts and dungeon factors), only when they change |
| `announce` | time, first 48 bytes of a server announcement that mentions loot (from the chat the guard already reads) |

Ring: 4,096 records (256 KB). At 2,000 kills an hour, bursts of a few hundred in a second still fit
before a 250 ms poll. On overflow the guard counts the lost records; the app stores the count as a
capture gap, so a rate is never silently wrong.

### App side

The poller drains the ring every 250 ms and writes one SQLite transaction. It:

- drops kills that aren't new for `(session, map instance, object id)`;
- links each bag to the kill on the same map within 0.5 tiles and 0–2 s before it (nearest one).
  Position is used only for this: in a burst of kills (one AOE can kill ten mobs in the same tick),
  it is the only way to tell which mob type each bag came from. It isn't used in any rate;
  bags with no kill are kept unlinked (chests, mobs you didn't hit);
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

Indexes: `kills(mob_type)`, `bags(kill)`, `bag_items(item_type)`. No pre-aggregated counters: a
`GROUP BY` over a year of rows is milliseconds, and raw rows keep every later question open.

Size: about 70 bytes per kill and 100 per bag with items; factor, map and announcement rows are
rare. 500 hours a year at 2,000 kills an hour is about 1 M kills, roughly 80 MB a year.

Kills of mobs you didn't damage aren't stored (they never count), but their bags are, unlinked.

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

**What counts as a drop** depends on the question, and is decided at query time from the raw bags
and items (the store keeps every item, so no question is closed off):

| Question | A kill counts once when… | Example: one bag with 2 STs, 2 purple, 1 cyan, 1 brown |
|---|---|---|
| Rate of an x bag from mob y | its **top bag** is x: the highest-priority bag over all bags from that kill (`DropBag` order, white highest) | Counts as orange only |
| Rate of item x from mob y | at least one x dropped | Each distinct item counts once |
| Items per kill | (a count, not a rate) every item | 2 STs, 2 purples, … |

The game already colours a bag by its best item, so a bag's type is its priority. A kill can still
leave more than one bag (for example a soulbound bag and a public one, or more than 8 items), which
is why the top bag is taken over all of a kill's bags.

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

## Phases

1. **#38: capture and store** (this design): hooks A, B and C, loot factors, the event ring, the app
   poller, `drop_rates.db` and the RealmHound cross-check. Needs the profile change and staging live
   tests.
2. **Next phase: rates calculator and view** (section 4 plus the display). Filed once capture runs.

## Open questions

- **Bag detection (spike done on 2026-11-16, from the dump and the binary):** hook B, contents
  included. Still to confirm in staging, by logging every stat of the first few bags:
  - which stat types hold the 8 item slots (classic protocol: 8–15);
  - where enchants live (likely a string stat; kept raw in `bag_stats` either way);
  - whether the kill's object position (`+0x68`, a float3) matches the bag's x/y directly or needs
    an axis swap.
- **Mob type field:** the object's type is either `KJMONHENJEN +0x30` or inside its properties
  (`+0x18`); confirm in the same run.
- **Kill flag trust:** your own kills are the client's prediction. Live test against RealmHound's
  boss kills.
- **Mob type id:** confirm the object type the guard reads equals RealmHound's `mob_type`.
- **Abilities and pets:** confirm in staging that ability hits arrive either as your projectiles or as
  Damage messages with your id as shooter, and that pet hits carry the pet's id.
- **Dungeon and server factors:** which dungeon modifiers and server events affect loot, and where
  the game holds them. Needs your game knowledge as well as the dump.
- **Profile:** approve adding hooks A, B and C to the reviewed profile. Auditing it is your decision.
