# How it works

Exalt Client Mac has two parts: the **app** you see, and a small **guard** that runs inside the game. This page shows how they fit together with the game and DECA's server, then follows four everyday events from start to finish.

## The big picture

```mermaid
flowchart LR
    you(["You"])

    subgraph mac["Your Mac"]
        direction LR
        app["<b>Exalt Client Mac</b><br/>settings, live view,<br/>Join button"]
        file[("<b>Shared status file</b><br/>both sides read<br/>and write it")]
        subgraph game["The game (RotMG Exalt)"]
            direction TB
            engine["<b>Unity engine</b><br/>draws frames,<br/>reads your keyboard"]
            guard["<b>Guard</b><br/>our add-on, loaded<br/>when the game starts"]
            client["<b>DECA's game code</b><br/>HP, potions, chat,<br/>parties"]
        end
    end

    server[("<b>DECA's<br/>game server</b>")]

    you -->|clicks| app
    you -->|keys and mouse| engine
    app <--> file
    file <-->|"status out,<br/>settings and clicks in"| guard
    engine --> client
    guard -->|"reads HP and chat,<br/>uses potion / Nexus / Join"| client
    client <-->|"hits, item use,<br/>HP updates"| server

    classDef ours fill:#e1f2ee,stroke:#1f8a78,color:#1b2124
    classDef deca fill:#f8eedc,stroke:#b7791f,color:#1b2124
    classDef shared fill:#e6e9f7,stroke:#4f63b8,color:#1b2124
    classDef person fill:#ffffff,stroke:#5d676b,color:#1b2124
    class app,guard ours
    class engine,client,server deca
    class file shared
    class you person
    style mac fill:#f7f8f6,stroke:#b9c1bd,color:#1b2124
    style game fill:#fdfaf3,stroke:#d9b77a,color:#1b2124
```

Green is this project, amber is DECA's game and server, blue is the file the app and guard share. The app also starts the game, which is how the guard gets loaded into it.

A few things to know before the traces:

- **The guard only uses the game's own functions.** It reads values the game already has (like your HP) and calls the same functions the game's keys and menus call. It never edits game code or network traffic.
- **The guard checks in between frames.** The game draws a frame, then the guard takes a quick look (about 3 microseconds), roughly every 6 to 7 ms during combat.
- **The server is in charge of your HP.** The game shows the HP the server last sent, about every 200 ms. Everything the guard does is based on that number.

## Trace 1: You take damage

An enemy bullet hits you. Nothing here is started by the guard; it watches.

```mermaid
sequenceDiagram
    autonumber
    participant S as Game server
    participant G as Game code
    participant GD as Guard
    participant A as App

    Note over G: An enemy bullet touches your character
    G->>S: Reports the hit
    Note over S: Applies the damage
    S->>G: Sends your new HP
    G->>G: Health bar on screen drops
    GD->>G: Next check between frames: reads HP
    GD->>A: Writes HP to the shared file
    A->>A: App's health bar drops too
```

The delay that matters is step 3: HP only changes when the server's update arrives. That is why a single huge hit can still kill you; there is no moment in between for anything to react.

## Trace 2: The guard drinks a potion

Your HP falls below the potion trigger (50% by default) while **Armed** is on.

```mermaid
sequenceDiagram
    autonumber
    participant S as Game server
    participant G as Game code
    participant GD as Guard
    participant A as App

    GD->>G: Reads HP: 45%
    Note over GD: Below 50% trigger: drink<br/>from the first quickslot with potions
    GD->>G: Calls the game's own "use quickslot" function
    G->>S: Use-item request (same as pressing the key)
    S->>G: HP goes up on the next update
    GD->>G: Reads HP: the heal arrived
    Note over GD: Still under the 80% ceiling:<br/>drink again (at least 250 ms later)
    GD->>A: Adds "Potion, slot 1, sent" to the shared file
    A->>A: Shows it in the Actions list
```

The guard waits for each heal to show up (or 1 second) before drinking another, so it can't empty a stack while the server is catching up. If HP keeps falling to the Nexus threshold (25%), the same path calls the game's "go to Nexus" function instead.

## Trace 3: You press the potion key yourself

The guard isn't involved here. This trace is for comparison with Trace 2.

```mermaid
sequenceDiagram
    autonumber
    actor P as You
    participant E as Unity engine
    participant G as Game code
    participant S as Game server
    participant GD as Guard

    P->>E: Press the potion key
    E->>G: Key is read during the next frame
    G->>G: Runs its "use quickslot" function
    G->>S: Use-item request
    S->>G: HP goes up on the next update
    GD->>G: Next check: reads the higher HP
```

Steps 3 to 5 are exactly what the guard triggers in Trace 2. The only difference is who starts it: your key press, or the guard's decision.

## Trace 4: Someone calls "j" and you click Join

This is the one trace that starts in the app.

```mermaid
sequenceDiagram
    autonumber
    participant S as Game server
    participant G as Game code
    participant GD as Guard
    participant A as App
    actor P as You

    S->>G: Party chat message: "j cit" from Lyra
    GD->>G: Next chat check (10 times a second): new message
    Note over GD: Party channel, starts with "j",<br/>not from you: it's a call
    GD->>A: Writes "call from Lyra" to the shared file
    A->>P: Notification, sound, Join popup
    P->>A: Clicks Join
    A->>GD: Writes "join Lyra" to the shared file
    GD->>G: Calls the game's "join dungeon" function<br/>(what the ctrl-click menu runs)
    G->>S: Join request
    S->>G: Moves you into Lyra's dungeon
    A->>A: Brings the game to the front
```

Calls only alert while you're in the Nexus, Vault, Realm and other waiting areas, and go quiet once you're in a dungeon.

## Where this lives in the code

| Part | File | What to look for |
| --- | --- | --- |
| Starting the game with the guard | `app/GuardLaunch.swift` | `DYLD_INSERT_LIBRARIES` |
| Guard startup | `guard/guard.c` | `start()`: runs as the guard loads, starts its timers |
| Finding the game's functions | `guard/guard.c` | `prepare()`: looks up classes, fields and methods by name through the IL2CPP API |
| The check between frames | `guard/guard.c` | `tick()`: read HP, decide, act, check chat, publish |
| The decisions | `guard/guard_core.h` | thresholds, ceiling, pacing; pure C, no game access |
| Shared status file | `guard/live_state.h` | layout and the lock-free sequence lock |
| Alerts, popup, Join button | `app/GuardApp.swift`, `app/GuardModel.swift` | `PartyAlerts`, `JoinPopupRules` |
