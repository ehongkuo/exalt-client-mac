# Guard hooks vs client reads (issue #61)

Checked on 2026-11-19 against game build `2ce88d8b…` (profile `2026-11-06`), from the il2cpp dump,
`llvm-objdump` and one guard log. Nothing here was live-tested unless a row says so.

**Outcome (#61):** drop rates now come from the game's traffic, decoded in the app the way RealmHound
does it (see [Drop rates from traffic](#drop-rates-from-traffic)). The guard's six drop-rate hooks
all stay, because drop and portal alerts (#74, #75) run on them for instant popups. The death-guard
hooks stay too; replacing `nexus` and dropping `death` were not pursued.

## What decides it

A hook can become a read only if it **only observes state the client keeps**. It can't if it:
- changes what the game does (drops a send, blocks an HP write, changes damage),
- needs the call itself: its return address, an argument the client doesn't store, or the order of
  calls inside one frame.

The guard's 1 ms timer runs on the main queue, between the game's frames. So a read effectively
samples **once per frame**. Network messages are handled inside frames, so several server ticks in one
frame (lag, catch-up) look like one change to a read. Anything created and removed in the same frame
is invisible to it.

## Every method in the profile

The profile has 20 methods. 14 of them are hooks, on 13 game functions (`update` and `newtick` share one).
The client build also hooks `SendMessage`, which isn't in the profile (see Findings).

| Hook | Data or effect | Recommendation | Why |
|---|---|---|---|
| `report` (hit report send) | drops your hit report while an escape is pending | **Keep** | changes behaviour |
| `notify` (player damage notification) | final damage of terrain/area hits; drops notifications while blocking | **Keep** | changes behaviour; needs the caller |
| `hp` (HP setter) | blocks a lethal local HP write; server HP after updates | **Keep** | changes behaviour; needs the caller and the stats/tick context |
| `damage` (projectile damage calculator) | the local damage of each shot, changed when lethal | **Keep** | changes behaviour |
| `SendMessage` (not in the profile) | blocks terrain/area sends; the tick reply's build time for the ordering proof | **Keep** | changes behaviour; the reply message isn't stored |
| `update` (NewTick handler) | RTT read from the tick message before it returns to its pool; tick entry time; HP after the tick | **Keep** | the message is pooled; the ordering proof needs the entry time, not the next frame |
| `stats` (stat dispatcher) | marks HP writes made inside a stats update (`update_source==2`), so `hp` treats them as server HP | **Keep** | "inside this call" is not state |
| `nexus` (Nexus call) | observe only: phase 7, which saves the incident history on a manual Nexus | **Replace** (not pursued) | see below |
| `death` (death screen) | observe only: phase 13, which saves the incident history when the death screen opens | **Drop** (not pursued) | the zero-HP sample already saves it |
| `enemydamage` (mob damage, base method) | each hit on a mob: damage and who caused it (from the caller) | **Keep** (drop rates, drop alerts) | your shots carry no damage in traffic; attribution comes from the return address |
| `damagemessage` (Damage message) | who the server says shot (your abilities) | **Keep** (drop alerts) | portal alerts need its kills; drop rates read it from traffic |
| `newobject` (new object) | each object's type and position; bag contents; portals | **Keep** (drop alerts) | the bag ring and wake-up (#75) and portals (#74) start here |
| `removeobject` (remove, from Update) | a hit mob gone = a kill | **Keep** (drop alerts) | a portal alert carries its kill |
| `statusapply` (status, every object) | server positions; your own stats when they change | **Keep** (drop alerts) | kill and portal positions for the nearest-kill link |
| `newtick` (same entry as `update`) | tick boundary: bags of the tick before go to the nearest kill | **Keep** (drop alerts) | portal alerts are sent at the tick that links them |

Drop rates read none of these except `enemydamage`: the app takes the rest from traffic. The guard
still writes its own loot lines, to `hook-loot-*.tsv`, which isn't imported; it is there to compare
the two paths again after a game update.

Not hooks:
- **Called by the guard:** `potion` (quickslot key), `join` and `join_cooldown` (party join). The
  guard's own Nexus goes through `il2cpp_runtime_invoke(nexus_method)`, which passes through the
  `nexus` hook; removing that hook doesn't change the call.
- **Callsite containers, never patched:** `collision`, `hit_handler`, `zero_hp_context`.

### `nexus`: replace (not pursued)

In the client build its only use is the incident history: phase 7 with `fatal_invoking == 0` saves
the last 64 events when you press Nexus yourself (`probe/hit_probe.h` `incident_remember`). The
socket's "Nexus in progress" flag (`SocketManager.FCOJPHFICAG`, already a profile field, read by the
death guard) turns on when any Nexus starts. A read that sees it turn on while the guard didn't ask
gives the same trigger, at most one frame later. The history then ends at that frame, not at the
call, which is fine for a diagnostic. Drops one of the nine all-or-none death-guard hooks.

Open: whether the flag stays on long enough to be seen (it should: the map change takes seconds).

### `death`: drop (not pursued)

Phase 13 also saves the history. `hit_probe_terminal_sample` already saves it when the tick sees your
HP at 0 outside the Nexus. The death screen follows that HP. Dropping the hook loses only the
"death screen opened" marker in the history. If that marker matters, a read of the GUI's death panel
replaces it instead.

## The first map: your state from the client

Traffic now gives your first map's stats (CreateSuccess comes before your first status), so these
reads aren't needed for drop rates. They stay here as the map from stat to client field.

Before #61, the loot hooks go in on the first tick that finds your player in the Nexus. The guard log of
the last session (`guard-23969.tsv`) shows `hit_probe_ready` and `loot_ready` on the same tick as the
first valid player row. By then the client has already applied your character's first full stats, and
later status messages carry only changes. That is why the first map misses gear enchantments and the
Crucible, and the loot bar fills them from RealmHound's `account_data.json`.

The client keeps all of them on the player object, so a read every tick has no gap:

| State | Stat | Client field (from the stat dispatcher) | Evidence |
|---|---|---|---|
| Level | 7 | `LKHPPBEGNOM.NJBEEONCHFA` int `0x200` (setter `DMGKLKGDMAE`) | disassembly |
| Gear (item types) | 8–19 | `LKHPPBEGNOM.IMONLKLEPJJ` `List<int>` `0x2D8` (setter `KNAOFAKIOLC(slot, item)`) | disassembly; the issue's notes |
| Loot drop potion, seconds left | 67 | `FKALGHJIADI.NJNDEBIGFMG` int `0x514` (setter `DBCDLMHBOPK`) | disassembly |
| Loot tier potion, seconds left | 68 | `FKALGHJIADI.OLCNEKEDDHJ` int `0x518` (setter `PBPPDCAMEDG`) | disassembly |
| Crucible on | 128 | `FKALGHJIADI.MFDDNNJHOHP` bool `0x6B3`: true when the stat's text is non-empty (setter `DJNGKAIMOGA`) | disassembly; matches #58 |
| Blood Ritual | 155 | `FKALGHJIADI.PINCMINGIGA` string `0x6B8`, and a bool at `0x768` = not empty (setter `EDAHNBPJOKH`) | disassembly |
| Enchantments | 80 | the text goes to the actor's virtual slot 96 (`LKHPPBEGNOM.OIIJPNOEJIC(string)`), then `GIMHPOJFOND.EHBFOBHNCAF(string)` and `EquipmentManager.UpdateEnchancedSlots()` | **open**: where the raw text is kept |
| Class | object type | `ObjectProperties.TypeAttribute` (string `0x60`) per the issue's notes | dump only; the path from the player to its properties isn't traced |
| Seasonal | 24 | handled by the dispatcher (`JNGDKFCBIGC.FMEOPMEHLFH`); field not traced | disassembly |

Notes:
- **Potion timers count down in the client.** A player method subtracts elapsed seconds from both
  `0x514` and `0x518`, and another zeroes them. So a read gives seconds left now, which is simpler than
  today's "last stat 67 minus seconds since" rule. The rule's pause in safe zones should show as the
  client not counting; check it live.
- **Stat 155 is text in this build.** The dispatcher reads the stat's string (`StatData+0x18`) and
  tests it with `IsNullOrEmpty`. `docs/loot-factors.md` calls it an int tier. The guard keeps text
  stats, so check what text a Blood Ritual character sends.
- **Enchantments:** `EHBFOBHNCAF` stores its string argument (`movq %rsi, 0x30(...)`), so the raw text
  is probably kept. If it is, the app's stat 80 parser works as is. If only parsed objects exist
  (`LKHPPBEGNOM` `0x170`, `0x2C8`), the read needs a new parser. This is step one of its issue.
- **Settle time:** in the same log, quickslot counts read 0 on the first valid tick and 6 a frame
  later. A read can't tell "not sent yet" from 0. Read every tick and treat a map's values as known
  only after a short settle (or once `loot_tick`'s class wait passes).

## Drop rates from traffic

The app captures the game's TCP stream (port 2050) with libpcap while a game it launched runs
(`app/GuardCapture.swift`) and decodes it (`app/GuardTraffic.swift`), ported from RealmHound (MIT,
github.com/pillarzz/RealmHound at `38d853f`):
- **Framing:** 4-byte big-endian size (it counts the 5-byte header), a type byte, the payload. RC4 runs
  over payloads only, one cipher per direction from the connection's first byte, with fixed keys.
- **Messages read:** CreateSuccess (your object id: a new map), MapInfo, Update (new objects, removed
  ids), NewTick (statuses), Damage, and your outgoing EnemyHit.
- **Loot rules:** the guard's, unchanged. A kill is a mob someone hit that the server removes; bags
  wait one tick and go to the nearest kill; your stats are written when they change.
- **Your projectile damage** isn't in traffic. The guard's `enemydamage` hook writes each hit to
  `hits-<started>-<pid>.tsv`, and the app joins those to its kills by object id and time. A kill is
  written 0.5 s after it happens so the hits arrive first.

It writes the same loot lines the guard did, as `loot-<started>-<pid>.tsv` (session format 6), so the
importer, database and views didn't change. A connection the decoder loses writes a `gap` line; a
message it can't parse writes one `status` line per message type and map.

**Parity run (2026-11-20, 33 maps):** against the guard's own file, traffic matched every one of the
guard's 1,463 kills (projectile, ability and max HP exact), all 703 bags with contents, every drop link
and the map info. It also had 9 kills the guard missed (your ability killing a mob in the same tick it
was removed), 6 portals on the first map, and your class and stats on the first map. "Since last hit"
differs by about 50 ms at p90: traffic times the packet, the guard times the call.

**Correction:** the connection's `CMAEBFGEKFC` (`0x120`) is your own object id, not a tick counter.

## Findings outside the profile

These are addresses in code, not in the profile, so `manage.py compare` doesn't report them after an
update. The runtime byte checks still refuse a mismatch.
- `probe/hit_probe.h`: `SEND_OFFSET` (a hooked method), `TERRAIN_NOTIFY_CALLER`, `AREA_NOTIFY_CALLER`,
  `TERRAIN_SEND_CALLER`, `TERRAIN_SEND_TAIL`, `AREA_SEND_CALLER`, `INCOMING_HP_CALLER`.
- `guard/loot_capture.h`: `LOOT_DAMAGE_CALLER`, `LOOT_DROP_CALLER`, `LOOT_OVERRIDE`,
  `LOOT_OVERRIDE_CALLER`.
- `app/GuardTraffic.swift`: the RC4 keys and message ids. A game update that changes them shows as
  `parse_failed` status lines and no kills.

## How to trace what RealmHound reads

RealmHound parses traffic, and its source is on GitHub (MIT): `realmhound-core/src/protocol/` has the
message layouts and `loot/` the loot rules. Read the source first. When the installed app is newer
than the source, its binary tells you **which stat** it uses, and the client's stat dispatcher tells
you **which field** holds that stat. Both are read only.

### 1. RealmHound: which stat

1. Find the behaviour's log line in `$HOME/Library/Application Support/RealmHound/logs/`, for example
   `[NEWTICK] Player crucible status`. To list them:
   `grep -ho '\[[A-Z_]*\] [A-Za-z ]*' *.log | sort | uniq -c | sort -rn`.
2. Take the x86_64 slice:
   `lipo /Applications/RealmHound.app/Contents/MacOS/RealmHound -thin x86_64 -output rh_x86`.
3. Find the string's file offset (Python `data.find(b'Player crucible status')`). Its `__TEXT` starts at
   file offset 0, so the address is `0x100000000 + offset`. Log templates are length-prefixed blobs in
   `__cstring`, so the code loads an address a few bytes **before** the text.
4. Disassemble once (about 5 s): `xcrun llvm-objdump -d --no-show-raw-insn rh_x86 > rh.s`. Grep for
   addresses just below the string's; a `leaq …(%rip)` loads it at the log site.
5. Read back from the log site to the test. Stat ids are byte compares on the stat entry's type byte,
   which sits at `+0x20` in 0x28-byte entries: `cmpb $0x43, 0x20(%rdx,%rsi)` is stat 67. Use
   `[[:space:]]` in grep patterns: objdump separates fields with tabs. Stat 128 hides as
   `cmpb 0x20(%rcx,%rdx), %r8b` with `%r8b = 0`, then `jo`, which overflows only for 0x80.

Rerun on 2026-11-19 (RealmHound in `/Applications`): the crucible string is at `0x10150152e`; its log
site loads `0x101501524` at `0x1009594dd`, and the `jo` test is at `0x1009591a5`, as #58 found. A
second function tests stats 24 and 67 (`0x10097e480`, `0x10097e4f0`).

6. Confirm against live data: RealmHound's `account_data.json` per character, and the guard's own stats.

### 2. The client: which field

1. Dump the build (`compatibility/manage.py analyze`; the dump is `build/compatibility/<profile>/dump/dump.cs`).
2. The stat dispatcher is the `stats` hook target, `HJMBOMEHGDJ.NAMGODOEDBO` (`0x91a6a0`). It jumps on
   `(stat - 0x80) & 0xff` through a table of 256 relative `int32`s right after the function
   (`0x91ce8c` in this build). Find it at the `movslq (%rcx,%rax,4)`; `jmpq *%rax`.
3. Read the table from the game file (`__TEXT` at file offset 0, so offset = address). Each entry +
   the table address is the case for that stat. The default (115 stats) skips the stat.
4. Map call targets to names with the dump's `// RVA:` lines. Each case calls a setter, mostly
   `FKALGHJIADI.*(int)` for the player or `LKHPPBEGNOM.*` for any object.
5. Disassemble the setter; its first `mov %esi, 0x…(%rdi)` is the field. Look up the offset in the
   class's field list in the dump. A virtual call (`callq *0x…(%rax)`) is slot `(offset − 0x138) / 0x10`;
   the dump prints `Slot: N` on each method.
6. Check other writers of the field (grep the offset in the class's code range). That is how the
   potion countdown was found.

The scripts that did this are short; keep them out of the repo until a replacement needs them again.
