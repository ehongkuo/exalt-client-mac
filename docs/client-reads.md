# Guard hooks vs client reads (issue #61)

Checked on 2026-11-19 against game build `2ce88d8b…` (profile `2026-11-06`), from the il2cpp dump,
`llvm-objdump` and one guard log. Nothing here was live-tested unless a row says so. Each "replace"
issue has its own live check.

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
| `nexus` (Nexus call) | observe only: phase 7, which saves the incident history on a manual Nexus | **Replace** | see below |
| `death` (death screen) | observe only: phase 13, which saves the incident history when the death screen opens | **Drop** | the zero-HP sample already saves it |
| `enemydamage` (mob damage, base method) | each hit on a mob: damage and who caused it (from the caller) | **Keep** | attribution comes from the return address |
| `damagemessage` (Damage message) | who the server says shot (your abilities) | **Keep** | the message is pooled; it gives `enemydamage` its context |
| `newobject` (new object) | each object's type and position; bag contents; portals | **Replace** | the client's object table holds the same |
| `removeobject` (remove, from Update) | a hit mob gone = a kill | **Replace** (with `newobject`) | an id leaving the object table is the same event |
| `statusapply` (status, every object) | server positions; **your own stats** when they change | **Replace** (your stats); positions go with `newobject` | the player's fields hold your stats; see the first map |
| `newtick` (same entry as `update`) | tick boundary: bags of the tick before go to the nearest kill | **Replace** | the connection's tick counter is already a profile field |

Not hooks:
- **Called by the guard:** `potion` (quickslot key), `join` and `join_cooldown` (party join). The
  guard's own Nexus goes through `il2cpp_runtime_invoke(nexus_method)`, which passes through the
  `nexus` hook; removing that hook doesn't change the call.
- **Callsite containers, never patched:** `collision`, `hit_handler`, `zero_hp_context`.

### `nexus`: replace

In the client build its only use is the incident history: phase 7 with `fatal_invoking == 0` saves
the last 64 events when you press Nexus yourself (`probe/hit_probe.h` `incident_remember`). The
socket's "Nexus in progress" flag (`SocketManager.FCOJPHFICAG`, already a profile field, read by the
death guard) turns on when any Nexus starts. A read that sees it turn on while the guard didn't ask
gives the same trigger, at most one frame later. The history then ends at that frame, not at the
call, which is fine for a diagnostic. Drops one of the nine all-or-none death-guard hooks.

Open: whether the flag stays on long enough to be seen (it should: the map change takes seconds).

### `death`: drop

Phase 13 also saves the history. `hit_probe_terminal_sample` already saves it when the tick sees your
HP at 0 outside the Nexus. The death screen follows that HP. Dropping the hook loses only the
"death screen opened" marker in the history. If that marker matters, a read of the GUI's death panel
replaces it instead.

## The first map: your state from the client

Today the loot hooks go in on the first tick that finds your player in the Nexus. The guard log of
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

## The loot hooks without hooks

`HJMBOMEHGDJ` (the connection) has the client's object tables: `Dictionary<int, LKHPPBEGNOM>
DFALIKKKGLI` (`0xC0`) and two `Dictionary<int, KJMONHENJEN>` (`0xC8`, `0xD0`). Each object holds its
id (`KJMONHENJEN.HHPOJBFICAH` `0x34`) and position (`DGNPJNFGFPE` `0x68`), both profile fields
already. Polling them each frame gives new ids (with type and position), and ids that left (kills, if
the mob had your hits). Bags hold their items in the same gear list as the player (`0x2D8`). The
connection's tick counter (`CMAEBFGEKFC` `0x120`, a profile field) marks tick boundaries.

What a poll loses, to measure before replacing:
- **Several ticks in one frame merge.** A bag and a kill from different ticks in the same frame land in
  one "tick", so the nearest-kill match sees more candidates. Count how often the counter jumps by 2+.
- **Positions are the client's, which interpolates moving objects.** The hook reads the server's. Kills
  are placed where the mob was last drawn, which is close but not exact.
- **"Left the table" includes leaving view.** The hook already counts those as kills (see
  `guard/loot_capture.h` D), so no change there.
- **Your stats** come from the player fields above, not status messages.

`enemydamage` and `damagemessage` stay, so drop-rate capture still has two hooks. Their data (who
hit, and how much) exists only in the call.

## Findings outside the profile

These are addresses in code, not in the profile, so `manage.py compare` doesn't report them after an
update. The runtime byte checks still refuse a mismatch.
- `probe/hit_probe.h`: `SEND_OFFSET` (a hooked method), `TERRAIN_NOTIFY_CALLER`, `AREA_NOTIFY_CALLER`,
  `TERRAIN_SEND_CALLER`, `TERRAIN_SEND_TAIL`, `AREA_SEND_CALLER`, `INCOMING_HP_CALLER`.
- `guard/loot_capture.h`: `LOOT_DAMAGE_CALLER`, `LOOT_DROP_CALLER`, `LOOT_OVERRIDE`,
  `LOOT_OVERRIDE_CALLER`.

## How to trace what RealmHound reads

RealmHound parses traffic; its source isn't available. Its binary tells you **which stat** it uses.
The client's stat dispatcher tells you **which field** holds that stat. Both are read only.

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
