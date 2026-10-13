# Exalt Client Mac

A macOS companion for Realm of the Mad God Exalt. It watches your HP from inside the running game and, at thresholds you set, drinks health potions or sends you back to the Nexus. A native SwiftUI app shows what it's doing in real time.

> Not affiliated with or endorsed by DECA Games. Third-party tools can conflict with the game's terms of service, so use it at your own risk. It reacts to the HP the server reports, which means a single hit that takes you from above the threshold to 0 still kills you.

## What it does

- **Auto-potion.** Starts drinking when HP drops to the potion trigger (default 50%) and keeps going until HP is over a ceiling (default 80%). After each potion it waits for the heal to show up in HP before drinking again (details under Potion pacing). Quickslots are used in order: the first until it's empty, then the next.
- **Auto-Nexus.** Returns to the Nexus once when HP is at or below the Nexus threshold (default 25%).
- **Party call alerts.** When another player starts a party chat message with "j" (any number of j's, as in "j cit" or "JJJJ") or "join", the app shows a notification, plays a sound and flashes the compact strip. Normal chat and your own messages never alert, calls only alert while you wait in the Nexus, Vault, Realm, a Guild Hall, the Pet Yard or the Daily Quest Room, and a burst of calls alerts once every 5 s. It can be switched off in the app.
- **One-click Join.** A call pops up a card at the top of the screen, over anything including full-screen video, with a **Join** button (also on the compact strip). Join does what the game's ctrl-click menu "Join dungeon" does for that player, then switches to the game. Clicking the notification just switches to the game.
- **Live view.** HP and thresholds, quickslot counts and cooldowns, the last 16 actions with millisecond timestamps, a session summary (potions used, Nexus count, closest call) and latency numbers. There's also a compact always-on-top strip that floats over the game without taking focus.
- **Log export.** **Export logs...** saves every session log plus your settings as one zip.
- **Settings while you play.** Thresholds and armed/dry-run change live from the app and are saved for the next launch.
- **One-click start.** The app checks the install and the game build, then opens DECA's launcher with the guard loaded for that launch only.

## How it works

```
Exalt Client Mac.app (arm64, SwiftUI)
    |  starts DECA's launcher with DYLD_INSERT_LIBRARIES=ExaltGuard.dylib
    v
RotMGExalt (x86_64 under Rosetta) + ExaltGuard.dylib (C)
    |  every check, on the game's main thread:
    |    read HP, max HP, quickslots and the current map through the IL2CPP runtime API
    |    decide (pure C state machine in guard_core.h)
    |    call the same game functions the potion and Nexus keys call
    |
    |  guard-live.bin: 4 KB memory-mapped file, two sequence-locked blocks
    |    guard -> app: live state, events, session summary
    |    app -> guard: settings changes, Join clicks
    v
Exalt Client Mac.app reads it once per screen refresh
```

The parts worth walking through:

1. **How does it get into the game?** The game is an x86_64 Unity IL2CPP build that runs under Rosetta and isn't built with the hardened runtime, so `DYLD_INSERT_LIBRARIES` on the launcher is inherited by the game. The library only activates in a process named `RotMGExalt`, and only on the game build whose SHA-256 is in `game-build.sha256`.
2. **How does it read HP without hardcoding memory layouts?** It resolves classes, fields and methods by name through the exported `il2cpp_*` functions, checks each field's type, and reads values with `il2cpp_field_get_value`. Objects are held with GC handles and checked against Unity's native pointer, so destroyed objects are never read.
3. **How does it act?** It calls the game's own key handlers, `EquipmentManager.OnQuickslotHotkeyPressedHandler` for potions and the Nexus handler, through `il2cpp_runtime_invoke`. Join calls the same two functions as the ctrl-click menu's "Join dungeon" button (found by logging which function each menu button's click handler points at, then disassembling it). The game's own checks still apply: potion count, cooldown and whether Nexus is allowed. It doesn't patch game code or touch network packets. Before arming, it checks that those methods are at the offsets expected for this build.
4. **How does the app see it without lag?** Two processes on different architectures (x86_64 under Rosetta and arm64) share a memory-mapped file. Each direction is a sequence lock: the writer bumps a counter to odd, copies the struct and bumps it to even, and the reader retries if the counter moved. The app reads it every frame through `TimelineView(.animation)`.

## Latency

| Stage | Measured |
| --- | --- |
| Server HP updates | about every 200 ms |
| Guard check after the game applies HP | at the end of that frame (6-7 ms frames in combat, about 1 ms timer when idle) |
| Decision and call into the game | about 3 µs per check |
| App display | one screen refresh behind the guard |

Checks have to run on the game's main thread, between frames, since that's where Unity's objects are safe to touch. HP is applied during a frame, so the first check after a hit is as early as anything outside the game's own code can see it.

One investigation finding shaped the design: the client reports each bullet hit to the server before applying any damage locally, and the HUD follows the server's HP. So no reader of client HP can step in between bullets of a single volley. Percentage thresholds were the right scope for this tool.

## Party calls

The guard reads the chat window's messages every 100 ms. The game reuses message objects for new messages, so a message counts as new when an object's sender, channel or text changes, and messages already in the chat when the guard starts are only remembered. A message is a call when its channel is party chat, its sender isn't your character, and its first word is only j's or is "join". The guard logs only the caller's name; message text never goes to the log. The app checks for new calls 10 times a second on a timer, so alerts still work while its windows are hidden behind a full-screen game.

## Potion pacing

The game has no client-side potion cooldown, and HP only updates when the server reports it, about every 200 ms. An early version drank whenever HP was under the target, so it kept drinking on the old HP before the first heal arrived and emptied 7 potions in 316 ms.

Now each potion has to show its effect first:

1. **Drink one potion** and remember the HP at that moment.
2. **Wait for the heal.** The next potion is allowed once HP rises above that value, or after 1 s if it never does (for example when a hit lands at the same time).
3. **Never closer than 250 ms**, even when heals show up fast.

A new drop to the trigger starts a fresh run immediately. The integration tests model this with potions that heal 100 HP 200 ms after the drink.

## Safety checks

- **Pinned build.** It refuses to arm if the game file hash differs, or if the potion or Nexus method isn't at its expected offset. A DECA update switches it off until the build is re-inspected.
- **Field validation.** It acts only after the player HP field has matched the HUD at least once for the current player object.
- **Settle time.** It waits until max HP has been stable for 500 ms after a map change, a new character or an equipment swap. New player objects briefly carry stale HP and a placeholder max HP.
- **Never in the Nexus.** It reads the current map name from the game's map info and does nothing in the Nexus.
- **Contained errors.** If a call into the game throws, it logs the exception text and turns off only that action. A potion error never disables the Nexus.

## Testing

| Layer | What's covered |
| --- | --- |
| `core_tests.c` | Decision logic: thresholds, ceiling, pacing, settle time, the Nexus rule, settings validation |
| `live_tests.c`, `live_cross.c` | Sequence-lock consistency under concurrent writes, both in one process and between an x86_64 writer and an arm64 reader in separate processes (millions of reads per run, zero torn reads) |
| `test_guard.py` + `fixture.c` | 32 integration tests: the real guard library loaded into a synthetic `RotMGExalt` process with a fake IL2CPP runtime and scripted HP, covering potions, Nexus, ceiling, game cooldown, settings sent mid-session, wrong or lagging HUD fields, game exceptions, unknown maps, party chat calls (reused message objects, history, normal chat, own messages), Join (once per click, game errors, no party, unexpected build) and the live file |
| `app/*Tests.swift` | Live-file decoding, connection state, settings rules and file, launch checks, hashing, session summary |
| `build.sh` UI check | Builds a test copy of the app, switches to the compact strip and back, and fails if the app quits |

None of the tests touch the real game.

## Build

Needs macOS 13 or later, the Xcode command line tools, and DECA's launcher installed in `/Applications`.

```sh
./build.sh              # tests, then build into build/ and install to ~/Applications
./build.sh --test-only  # tests only
```

The app keeps settings and logs in `~/Library/Application Support/Exalt Client Mac/`. The icon is generated at build time from the installed launcher's icon (`app/recolor_icon.swift`), so no DECA artwork is stored in this repo. If the launcher isn't installed, a drawn fallback icon is used (`app/make_icon.swift`).

`Start Guard.command` is the original Terminal launcher, kept as a fallback.

## Layout

| Path | Contents |
| --- | --- |
| `guard.c` | The library loaded into the game: IL2CPP binding, sampling, actions, logging, live state |
| `guard_core.h` | Pure decision logic and settings parsing, shared by the guard and its tests |
| `live_state.h` | Shared-memory layout and the sequence lock |
| `timing_core.h` | Sample record and the lock-free ring buffer the guard logs through |
| `app/` | SwiftUI app: model, launch checks, views and tests |
| `fixture.c`, `ui_fixture.c` | Synthetic game process and synthetic live-state writer used by the tests |
| `live_dump.c`, `live_control.c` | Command-line tools to read the live state and send settings, used by tests |

## Limits

- **Pinned to one game build.** Class and method names in Exalt's IL2CPP build are obfuscated and may change with each update, so each update needs re-inspection before the guard will arm.
- **One-shots still kill.** It acts on server HP updates, which arrive about every 200 ms.
- **No Sick check yet.** The game appears to refuse potions while Sick on its own, but that isn't confirmed.
