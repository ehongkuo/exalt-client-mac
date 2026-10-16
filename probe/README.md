# Fatal-hit Nexus experiment

This is an active prototype for the audited incoming-projectile path. It estimates possible lethal damage, requests the normal Nexus function before the fatal hit report, then suppresses that report and subsequent local projectile damage while escape is pending.

The normal percentage-threshold guard, auto potions and party Join remain disabled. Other damage sources are not covered. A local Nexus request does not guarantee server acceptance or survival.

## Run the live test

1. Quit Exalt and the DECA launcher, then open `Start Hit Diagnostic.command` in this folder.
2. Press Return, click Play and wait in Nexus until Terminal says `Probe installed. Fatal Nexus intervention is ON.` If installation is refused, stop.
3. Use the throwaway character and enter a fresh realm/map. Test the planned projectile burst that would kill the character without intervention. A fresh map avoids carrying earlier unconfirmed hits into the test.
4. If Nexus occurs, remain there for five seconds. If the character dies, remain on the death screen for five seconds. Then quit normally and report what happened.
5. If the request fails locally or the client remains stuck waiting for escape, stop the test and quit normally.

The prototype runs until the game is closed. Restarting the game normally removes the injected hooks. To use the same build without intervention, run:

```sh
'/Users/ehongkuo/Documents/Codex/2026-10-11/can/outputs/exalt-hit-probe/Start Hit Diagnostic.command' --observe
```

## Fatal prediction

The trigger uses no percentage threshold:

```text
projected HP = latest observed player HP - local damage retained since the latest server HP assignment
trigger when projected HP <= 0
```

All positive calculated damage is retained between server HP assignments. After the validated incoming update/stat handler assigns player HP, that HP replaces the prediction baseline and retained damage becomes zero, even if HP is unchanged or increased. This is a baseline reset, not a verified hit-specific acknowledgement. A delayed update may omit recently reported hits, so this policy can underestimate outstanding damage. Uncovered damage sources remain unresolved.

The native calculation-return hook performs this decision synchronously before returning to the collision routine. It preserves opaque native arguments without inspecting them. At the first possible lethal hit, it retains GC handles for the validated player and connection, invokes the same normal Nexus method as the game, and checks the connection's SocketManager Nexusing flag.

After that local flag is present:

- The current and later audited calculation calls return zero instead of their original damage value.
- The player-hit report method forwards no matching report for the latched connection.
- The audited local projectile notification forwards no matching call for the latched player.

Other game events continue, including incoming HP assignments, death messages, networking and map changes. Diagnostic events are still recorded. Previously sent or queued reports are not recalled or reordered. If Nexus throws, cannot retain handles, or returns without the local flag, damage calls remain unchanged. Only one automatic request is attempted per window; another map/player window allows a new attempt.

Server HP assignments reset the damage budget while preserving an active escape latch. Confirmed Nexus or a new validated map/player/connection resets both the budget and latch. Temporary missing GUI/player readings do not clear the latch. Off-main matching reports and known projectile notifications can be suppressed using atomic identity comparisons, without inspecting game objects or writing the main-thread event ring. Their counts appear separately in the summary.

## Trace

The existing hit, HP, update-boundary, Nexus and death events remain available. Nexus-function entry uses flag0 to distinguish the automatic invocation from a manual invocation. Additional phases are:

| Phase | Meaning |
|---|---|
| 20 | Conservative fatal prediction |
| 21 | Nexus request starting, or an existing local Nexusing flag |
| 22 | Request result: local flag present, exception or handle failure |
| 23 | Player-hit report withheld |
| 24 | Local projectile notification withheld |
| 25 | Nexus observed or scope changed; budget reset |
| 26 | HP reached zero while suppression was active |
| 27 | Live fatal budget after an audited calculation |

| 28 | Incoming server HP assignment; retained damage reset, escape latch preserved |

For fatal phases 20-28, `projectile` contains retained numeric damage and `update_context` contains projected HP encoded as signed 64-bit. They are numeric diagnostic aliases, not object identities or update-parent IDs. The analyzer decodes these into `fatal_intervention`. The former observation-only shadow hypotheses are not replayed for an intervened session because its damage handling was modified.

```sh
python3 analyze.py data/logs/guard-<pid>.tsv
python3 analyze.py data/logs/hit-flight-<pid>.bin
```

Recover the binary only after quitting the game. It retains the most recent 8,192 published events and reports overwritten or incomplete slots. Periodic counters are snapshots. Text logs and the file-backed recorder survive ordinary process exit; power-loss recovery is not guaranteed.

## Coverage and interpretation

The calculation hook is limited to return address `0x6538a2` in the inspected projectile collision path. The report hook is HJMBOMEHGDJ.NDACCDPJHBC at `0x1853fb0`; the notification hook suppresses the controlled-player notification from the audited caller `0x653bd0`. Other damage paths remain unmapped and unchanged.

A successful synthetic test establishes local request/suppression ordering, not server behavior. A live survival result must be checked against the recorded prediction, actual withheld reports, Nexus request and observed map transition. An early conservative escape is not proof that a genuinely lethal hit was prevented. A server death after suppression is recorded, rather than hidden.

Every hook validates runtime method parameters, game-build offsets and complete instruction-prefix bytes before installation. The previous invalid-instance crash regression remains enabled. Runtime objects are accessed only through validated game references and retained handles. Installed game files are unchanged.

Supported GameAssembly SHA-256:
`ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`

One diagnostic folder is maintained in place. Historical sessions are under `data/sessions` and analyses under `data/analyses`. Source is in `/Users/ehongkuo/Development/exalt-client-mac-hit-probe`; build with `sh probe/build-probe.sh`. The main checkout is unchanged. Probe work remains uncommitted.
