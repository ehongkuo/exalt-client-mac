# Drop catalog: investigation and plan (issue #51)

Goal: the Drop rates tab knows every dungeon, its mobs and their possible drops before the first kill, so new kill data
lands in a ready slot and nothing in play is a surprise.

Status: investigation done, plan waiting on the choices in [Decisions](#decisions). No script or data file yet.

## 1. Sources

### Game data (RealmHound's `assets/xml` and sprites), checked Nov 2026

| What | Coverage | Gap |
| --- | --- | --- |
| Mobs (`Character` objects) | 5,706, each with a unique XML id | 745 display names are shared by 2,417 objects (Heroic, legacy and event copies), so a name alone can't key a mob |
| Items | 12,843; 638 tiered, 814 with an `ORG_*` drop tag | Drop tags say which dungeon an item belongs to, not which mob drops it |
| Dungeons | 167 portals with a `<DungeonName>`; 69 have a `<DungeonModTemplate>` | "Realm of the Mad God" has no portal, so it is the one map name with kills that isn't in `dungeons` |
| Dungeon → mobs | None. Mobs are spread over 135 files; dungeon-named files (`lostHallsObjects.xml`) hint at it but also hold helpers, chests and minions, and shared files (`heroes2.xml`, `encounters.xml`) hold Realm mobs | Needs RealmEye or observed kills |
| Mob → drops | None, apart from 20 legacy `<Loot tier= prob=>` lines in `heroes2.xml` | Needs RealmEye or observed drops |
| Sprites | RealmHound's sheets resolve 100% of items, bosses and portals, and 5,701 of 5,706 mobs | The 5: Jeebs, Eyeball, Def Test and Retro Fairy have no texture; one more has a sheet index the sprite file lacks. None is a real dungeon mob |

So the game data already covers names, IDs and sprites. What it lacks is the two links that RealmEye supplies:
dungeon → mobs, and mob → drops (named items plus tiered loot, today's hand-typed `realmEyeTiers`).

### RealmEye

Not verified from this session; see section 2. Known from the hand-typed `realmEyeTiers`: each mob's page lists its
tiered loot (weapon, ability, armor and ring tiers) and named drops. Page layout, page count and the exact markup were
not checked and have to be read from real pages before the parser is written.

## 2. RealmEye's terms and robots.txt

- **robots.txt** (read Nov 2026) blocks the whole site (`Disallow: /`) for about 195 named AI and automation agents,
  **Claude-Code, Claude-User and ClaudeBot among them**. Every other agent may crawl everything except forum user pages
  and wiki search, with `Crawl-delay: 1`.
- **This session made two requests to realmeye.com** before reading that list: `robots.txt` and the terms page, both
  with a browser User-Agent. The terms page returned an empty 204. It will make no more.
- **Terms of use: not verified.** The terms page came back empty and a web search found nothing from realmeye.com. Read
  them yourself before deciding (link in the site footer).
- **Committing RealmEye-derived data:** the repo already does, as `realmEyeTiers` in `app/GuardDropRates.swift`. Facts
  about a game (mob X drops item Y) are usually not protected, but a site's terms can still forbid copying its
  compilation. Your call after reading the terms.

## 3. Proposed format

One JSON file (`data/drop_catalog.json`), read with Foundation's `JSONDecoder`, no new dependency. Keyed by the game's
type id with the XML id beside it, since display names repeat. New dungeons, mobs or items are new entries, not code.

```json
{
  "source": { "site": "RealmEye", "url": "https://www.realmeye.com", "fetched": "2026-11-20" },
  "dungeons": [
    { "name": "Abyss of Demons", "portal": "0x0704", "mobs": ["0x0d50", "0x0d51"] }
  ],
  "mobs": [
    { "type": "0x0d50", "id": "Archdemon Malphas",
      "tiers": { "weapon": [7, 8, 9, 10], "ability": [3, 4], "armor": [6, 8, 9], "ring": [3, 4] },
      "drops": ["0x0c1d", "0x0c2e"] }
  ],
  "unmatched": [
    { "realmeye": "Some Mob", "why": "no game object with this name in a matching file" }
  ]
}
```

- **Dungeon `name`** is the in-game map name (`maps.name`, the portal's `<DungeonName>`), because kills are stored
  under it. The Realm is an entry with no portal.
- **Mobs** are listed once and referenced from dungeons, as Realm and event mobs appear in several. Hex ids are
  shown for readability; the hex values above are made up.
- **`unmatched`** keeps every RealmEye name the script couldn't tie to one game id, with why, so a refresh shows what
  needs a hand fix instead of dropping it silently.
- **Name matching:** RealmEye name against `coalesce(display_name, name)`. When several objects share it, prefer the one
  from the dungeon's own XML file, then the one with `ENEMY` and no `Heroic`/legacy marker; anything still ambiguous goes
  to `unmatched`.

**Joining the catalog:** `GameNames.refreshCatalog` loads the file into three tables beside `objects` and `items`,
rebuilt with them (the file's hash joins the catalog signature):

```sql
catalog_dungeons(dungeon TEXT, mob INTEGER)        -- dungeon name → mob type
catalog_tiers(mob INTEGER, family TEXT, tier INTEGER)
catalog_drops(mob INTEGER, item INTEGER)
```

`DropReport` then reads tiers from `catalog_tiers` (replacing `realmEyeTiers` and `tierItems(_ codes:)`), lists every
catalog dungeon, and adds catalog mobs and drops to `mobs(in:)` and `possibleDrops`. `dropTags` stays for item origin
tags that RealmEye doesn't cover, and goes where the catalog makes it redundant.

## 4. Unknown dungeons, mobs and items

Capture doesn't depend on the catalog: the guard stores raw type ids and map names, so nothing is lost.

- **Shown:** an unknown mob or item shows by its game name from `objects`/`items` (or `#0x....` if even the game data
  lacks it), and an unknown map by its name, as today.
- **Listed:** the Drop rates tab gets a short "Not in the catalog yet" list: map names, mob types and dropped item types
  seen in `drop_rates.db` but missing from the catalog.
- **Picked up:** the refresh script reads `drop_rates.db` read-only and prints the same list, so the next refresh
  targets them; anything it still can't match lands in `unmatched`.

## 5. Plan once the choices are made

1. `tools/drop_catalog.py` (Python standard library, like the other tools). Throttled (2 s between requests, double the
   crawl delay), every page cached under `~/Library/Caches/Exalt Client Mac/realmeye/` so a rerun only fetches what's
   new, an honest User-Agent naming the tool, and a printed diff against the current file. It credits RealmEye in the
   file's `source` and in the README.
2. The data file, generated by the script.
3. Loading it in `refreshCatalog`, the three tables, `DropReport` changes, removing `realmEyeTiers`.
4. Sprites loaded up front: cut every catalog dungeon, mob and item sprite once, off the main thread, when the tab first
   opens, instead of as each type shows up.
5. Tests: every entry joins to a game id whose XML id matches; every entry has a sprite or is in a listed reason set
   (the 5 mobs above); the loader handles a missing file.
6. `./build.sh --stage` and a live check that a dungeon never run shows its mobs and drops.

## Decisions

1. **Who fetches RealmEye.** This session must not, per robots.txt.
   - **A (recommended):** you run the script yourself. It's a plain crawler with its own User-Agent, which robots.txt
     allows at 1 request a second; you read the terms first.
   - **B:** no RealmEye pull. The catalog is the game data plus observed drops, and tiers stay hand-kept, moved into the
     JSON file.
2. **Reading your cached pages.** With A, the parser needs real pages to be written against. May this session read the
   pages your run caches locally? If not, you'd save one dungeon and one mob page by hand for the samples; the parser
   is still written by a session reading them, so the question is the same.
3. **Commit or local only.**
   - **Commit `data/drop_catalog.json`** (as `realmEyeTiers` is today), if the terms allow it.
   - **Local only:** the file is built into `~/Library/Application Support/...`, gitignored, and copied into the app by
     `./build.sh`. Tests and the app must then pass with the file absent.
4. **Drop the RealmEye sprite fallback** from #51's scope: RealmHound covers every real mob and item.
5. **Database version bump.** The three tables need a `user_version` step. #49 is sharing `drop_rates.db` between the
   installed and staging apps, so the order of the two bumps needs agreeing.
6. **Overlap with #50.** Catalog mobs with no kills will crash `GuardDropRatesView.swift` where it force-unwraps
   `report.kills[...]` (dungeon kill counts), so that file needs a small edit here, plus the "Not in the catalog yet"
   list.
