# Exalt Client Mac

A macOS companion app for Realm of the Mad God Exalt. It runs alongside the game and:

- **drinks health potions and returns you to the Nexus** at HP thresholds you choose,
- **pings you when someone calls "j" in party chat**, with a one-click **Join** that takes you into their dungeon,
- **shows what it's doing live**, in a window or a small strip that floats over the game.

<p>
  <img src="docs/join-popup.png" width="380" alt="Join popup: party call from Lyra, j cit, with a Join button">
  &nbsp;
  <img src="docs/compact-strip.png" width="340" alt="Compact strip: armed, HP 85%, flashing for a party call with a Join button">
</p>

<details open>
<summary><b>Full view</b> (top, and scrolled to the bottom)</summary>
<p>
  <img src="docs/full-view.png" width="360" alt="Full view: map, health bar at 85% with threshold markers, session summary, party calls with a Join button, and settings">
  &nbsp;
  <img src="docs/full-view-scrolled.png" width="360" alt="Full view scrolled down: settings, quickslots, recent potion and Nexus actions, and latency numbers">
</p>
</details>

Screenshots are taken from a test build fed by a synthetic writer (`tests/ui_fixture.c`), not the real game.

> Not affiliated with or endorsed by DECA Games. Third-party tools can conflict with the game's terms of service; use it at your own risk. It reacts to the HP the server reports, so a single hit that takes you from above a threshold to 0 still kills you.

## Features

**HP guard**
- **Auto-potion.** Starts drinking at the potion trigger (default 50%) and keeps going until HP is over the ceiling (default 80%), one potion per heal. Quickslots are used in order.
- **Auto-Nexus.** Returns to the Nexus once when HP reaches the Nexus threshold (default 25%).
- **Dry run.** Off by default: the guard shows what it would do without doing it until you switch it to Armed.

**Party calls**
- **Alerts.** When another player starts a party message with "j" ("j", "JJJJ", "j cit") or "join", you get a notification, a sound and a flash on the compact strip. Normal chat and your own messages never alert.
- **Only while you're waiting.** Calls alert in the Nexus, Vault, Realm, Guild Hall, Pet Yard and Daily Quest Room, and go quiet once you're in a dungeon. A burst of calls alerts once every 5 s.
- **One-click Join.** A card pops up at the top of the screen, over anything including full-screen video. **Join** does what the game's ctrl-click menu "Join dungeon" does for that player, then switches to the game. The compact strip has the same button.

**App**
- **Live view:** HP with threshold markers, quickslots, the last 16 actions, a session summary (potions used, Nexus count, closest call) and latency numbers.
- **Compact strip:** a small always-on-top bar that never takes focus from the game.
- **Settings while you play:** thresholds and Armed / Dry run apply to the running game instantly and are saved.
- **Export logs:** every session log plus your settings, zipped.

## Getting started

Requirements: macOS 13 or later on Apple silicon, the Xcode command line tools (`xcode-select --install`), and DECA's launcher in `/Applications`.

```sh
git clone https://github.com/ehongkuo/exalt-client-mac.git
cd exalt-client-mac
./build.sh            # runs the tests, builds, installs to ~/Applications
```

Then:

1. Open **Exalt Client Mac** (Launchpad or `~/Applications`).
2. In **Party calls**, click **Test alert** once and allow notifications.
3. Click **Start game**, then **Play** in DECA's launcher.
4. Set your thresholds and switch **Armed** on when you're happy with what Dry run shows.

The game must be started from the app; that's how the guard gets loaded. Settings and logs are kept in `~/Library/Application Support/Exalt Client Mac/`.

## How it works

```
Exalt Client Mac.app  (Swift, arm64)
   │  Start game: opens DECA's launcher with DYLD_INSERT_LIBRARIES=ExaltGuard.dylib
   ▼
RotMGExalt  (Unity IL2CPP, x86_64 under Rosetta)  +  ExaltGuard.dylib  (C)
   │  every frame, on the game's main thread:
   │    read HP, quickslots, map and party chat through the IL2CPP runtime API
   │    decide (pure C state machine)
   │    call the game's own potion / Nexus / Join functions
   │
   │  guard-live.bin: 4 KB memory-mapped file, sequence-locked blocks
   │    guard → app:  live state, events, session summary, party calls
   │    app → guard:  settings changes, Join clicks
   ▼
Exalt Client Mac.app reads it once per screen refresh
```

The ideas that make it work:

1. **Getting into the game.** The game runs under Rosetta and isn't built with the hardened runtime, so a library named in `DYLD_INSERT_LIBRARIES` when the launcher starts is loaded into the game. The guard only activates in the game process, and only on the exact game build it was checked against (SHA-256 in `guard/game-build.sha256`).
2. **Reading without hardcoded addresses.** Unity IL2CPP games export a runtime API (`il2cpp_class_from_name`, `il2cpp_field_get_value`, ...). The guard finds classes and fields by name, checks each field's type, and holds objects through GC handles, so it never reads a destroyed object. Names are obfuscated, so each is pinned to this game build.
3. **Acting like a key press.** Potions, Nexus and Join call the same game functions as the potion key, the Nexus key and the ctrl-click menu, through `il2cpp_runtime_invoke`. The game's own checks (potion count, whether Nexus is allowed, party membership) still apply. It never patches game code or edits network traffic, and it refuses to act if any of those functions isn't where this build puts it.
4. **Talking across architectures.** The guard (x86_64) and the app (arm64) share a memory-mapped file. Each direction is a sequence lock: the writer makes a counter odd, copies the data, then makes it even; the reader retries if the counter moved. No locks, no sockets, and the app always sees a consistent snapshot.

## Design notes

These came from measuring the real game and shaped how the guard behaves.

- **Why thresholds and not "dodge the hit":** the client reports each bullet hit to the server before it applies any damage, and the HUD follows the server's HP. Nothing reading client HP can act between bullets of one volley, so the guard acts on HP percentages as early as the client sees them.
- **Latency:** HP arrives from the server about every 200 ms. The guard checks at the end of every frame (6-7 ms frames in combat), and a check takes about 3 µs. The app draws one screen refresh behind the guard.
- **Potion pacing:** the game has no client-side potion cooldown, and an early version emptied 7 potions in 316 ms while waiting for the first heal to show. Now each potion has to show its heal first (or 1 s passes), with at least 250 ms between potions.
- **Reading chat:** the game reuses chat message objects, so a message counts as new when an object's sender, channel or text changes. Message text never goes to the log; only the caller's name does.
- **Finding Join:** the guard logged which function each ctrl-click menu button runs, which pointed to "Join dungeon". Disassembling that function showed it calls the party manager with the player's name, so the app's Join calls exactly that.
- **Party finder (investigated, not built):** the server leaves full parties out of the finder list it sends, and the client allows a list refresh only every 30 s. A full party's status isn't on your machine at all until a slot opens and a later refresh includes it.

## Safety checks

- **Pinned build.** A DECA update changes the game file hash, and the guard won't start until the new build is inspected.
- **Field validation.** It acts only after the HP field it reads has matched the HUD for the current character.
- **Settle time.** After a map change, a new character or an equipment swap, it waits until max HP has been stable for 500 ms.
- **Never in the Nexus.** It reads the current map and doesn't act there.
- **Contained errors.** If the game throws during a call, the error is logged and only that action is switched off. A potion error never disables the Nexus.

## Testing

None of the tests touch the real game. The guard is tested by loading the real library into a synthetic `RotMGExalt` process with a fake IL2CPP runtime.

| Tests | What's covered |
| --- | --- |
| `tests/core_tests.c` | Decision logic: thresholds, ceiling, pacing, settle time, the Nexus rule, settings validation, party call matching |
| `tests/live_tests.c`, `tests/live_cross.c` | The sequence lock under concurrent writes, in one process and between an x86_64 writer and an arm64 reader (millions of reads, zero torn reads) |
| `tests/test_guard.py` + `tests/fixture.c` | 32 integration tests: potions, Nexus, ceiling, settings sent mid-session, wrong or lagging HUD fields, game exceptions, unknown maps, party calls (reused messages, history, normal chat, own messages), Join (once per click, game errors, no party, unexpected build), the live file |
| `app/*Tests.swift` | Live-file decoding, connection state, settings, launch checks, session summary, party alert and Join popup rules |
| `build.sh` UI check | Builds a test copy of the app, switches to the compact strip and back, and fails if the app quits or shows the wrong window |

```sh
./build.sh --test-only   # all tests (opens a test window briefly; don't run while playing)
./build.sh --app-only    # build and install without tests, safe while the game runs
```

## Project layout

| Path | Contents |
| --- | --- |
| `guard/` | The library loaded into the game: `guard.c` (IL2CPP binding, checks, actions, chat, Join, logging), `guard_core.h` (pure decision logic), `live_state.h` (shared-memory layout and sequence lock), `timing_core.h` (lock-free log ring), `game-build.sha256` (the inspected game build) |
| `app/` | The SwiftUI app: model, launch checks, views, icon generation and tests |
| `tests/` | Native and integration tests, the synthetic game and a synthetic live-state writer |
| `tools/` | `live_dump` and `live_control`: read the live file and send settings or Join clicks from the command line |
| `build.sh` | Tests, build, ad hoc signing and install |

The app icon is generated at build time from the installed launcher's icon (`app/recolor_icon.swift`), so no DECA artwork is stored here. Without the launcher, a drawn fallback is used.

## Limits

- **One game build at a time.** Exalt's code names are obfuscated and can change with every update, so each update needs re-inspection before the guard will start.
- **One-shots still kill.** The guard acts on server HP updates, about every 200 ms.
- **Sick is not checked.** The game appears to refuse potions while Sick on its own, but that isn't confirmed.
