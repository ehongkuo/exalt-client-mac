# Drop rates: investigation and capture design (issue #38)

Goal: estimate the true base drop rate of every item from every mob type, converging as data grows.
This issue builds the **capture layer and the persistent store**. How rates are calculated and shown
is designed here (section 4) but built later.

Data checked on 2026-11-16: RealmHound's files, opened read-only on a copy
(`~/Library/Application Support/RealmHound/accounts/<uuid>/databases/`), about 4 days of play
(226 boss fights, 249 logged bags), and the il2cpp dump of game build `2ce88d8b…` (the one the
current compatibility profile covers).

## Decisions so far

| Topic | Decision |
|---|---|
| Kill source | Our own guard hook, for bosses and ordinary mobs alike |
| Drop source | Our own capture in the guard, independent of RealmHound and its filters |
| What counts as a kill | A mob you hit that then died |
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

1. If the hit is yours (`hit_handler` return address): mark the target's object id in a small
   "hit by you" set (open-addressed, 1,024 ids, cleared on map change).
2. If the kill flag is set and the id isn't in the recent-kill set (256 ids, so a death reported
   twice counts once): push a `kill` event and remember the id.
3. Call the original.

Cost: a flag test and a hash probe per hit, no allocation, no il2cpp calls. Only the game's main
thread calls this method (the guard already asserts that for its other hooks).

**Bags.** A bag appears as a new object at the spot where its mob died. The guard pushes a `bag`
event with the bag's object type, id, position and item slots. If slots fill a tick or two after
the object appears, the guard re-reads each new bag's slots for up to 2 s and pushes `bag_items`
when they change. How to see a new bag cheaply (a hook on object creation or a diff on the guard's
1 ms timer tick) is the one open spike (see open questions).

**Events** (fixed 64-byte records, single producer, single consumer, in a new shared file next to
the live state):

| Event | Fields |
|---|---|
| `kill` | time, map instance, object id, object type, x, y, by-you, damage handler (yours / server) |
| `bag` | time, map instance, object id, bag type, x, y, up to 8 item ids |
| `bag_items` | time, bag object id, up to 8 item ids |
| `map` | time, map instance, map name (on every map change) |
| `boost` | reserved for the boost issue: time, packed boost state, only when it changes |

Ring: 4,096 records (256 KB). At 2,000 kills an hour, bursts of a few hundred in a second still fit
before a 250 ms poll. On overflow the guard counts the lost records; the app stores the count as a
capture gap, so a rate is never silently wrong.

### App side

The poller drains the ring every 250 ms and writes one SQLite transaction. It:

- drops kills that aren't new for `(session, map instance, object id)`;
- links each bag to the kill on the same map within 0.5 tiles and 0–2 s before it (nearest one);
  bags with no kill are kept unlinked (chests, mobs you didn't hit);
- resolves names from the game's XML at display time only. Ids are the truth, names can change.

### Store

`~/Library/Application Support/Exalt Client Mac/drop_rates.db` (staging uses its own folder), WAL
mode, opened only by the app.

| Table | Columns | Notes |
|---|---|---|
| `sessions` | id, started, ended, game build, guard version | Provenance; lets a bad build's data be excluded |
| `maps` | id, session, instance, name, entered | One row per map visit; gives the dungeon |
| `kills` | id, map, time, object id, mob type, by_you, by_server, boost | One row per death you saw; `boost` null until the boost issue lands |
| `bags` | id, map, time, object id, bag type, kill (nullable), x, y | Every bag, every colour |
| `bag_items` | bag, slot, item type | Final contents |
| `capture_gaps` | session, from, to, lost events, reason | Ring overflow, app not running, map unknown |

Indexes: `kills(mob_type)`, `bags(kill)`, `bag_items(item_type)`. No pre-aggregated counters: a
`GROUP BY` over a year of rows is milliseconds, and raw rows keep every later question open.

Size: about 50 bytes per kill and 100 per bag with items. 500 hours a year at 2,000 kills an hour
is about 1 M kills, roughly 60 MB a year.

### Checking the capture

In staging, with RealmHound running as before:

- every RealmHound boss fight with `killed = 1` has a matching guard kill;
- every bag RealmHound saved has a matching guard bag with the same items;
- the guard also has bags RealmHound filtered out (cyan, plain purple, brown).

## 4. Rate math (built later)

Every query is a ratio of true counts from the store, filtered by mob (type or class), item (or bag
colour), and kills you hit.

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

## Proposed split

1. **#38: capture layer and store** (this design): hook A, bag capture, event ring, app poller,
   `drop_rates.db`, the RealmHound cross-check. Needs the profile change and staging live tests.
2. **Boost state capture** (new issue, drafted): the guard reads the active boosts and emits `boost`
   events; kills get their boost state. Kills before it ships stay "boost unknown".
3. **Rates calculator and view** (new issue): section 4 plus the display.

## Open questions

- **Bag detection spike:** hook object creation, or diff the object list on the guard tick? Do a
  bag's slots arrive with it or a tick later? (A few hours with the dump and one staging run.)
- **Enchants on dropped items:** RealmHound records an enchant count per item; is it worth capturing
  in v1?
- **Kill flag trust:** your own kills are the client's prediction. Live test against RealmHound's
  boss kills.
- **Mob type id:** confirm the object type the guard reads equals RealmHound's `mob_type`.
- **Abilities and pets:** hits without a projectile may not mark "hit by you". Check whether they
  reach hook A through another caller.
- **Profile:** approve adding hook A (and any bag hook) to the reviewed profile. Auditing it is your
  decision.
