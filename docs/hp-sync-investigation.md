# Normal HP synchronization and intervention timing

Status: native send/receive boundaries mapped; exact snapshot-to-hit coverage remains unverified.
The synchronization probe is observation-only. No revised escape decision is implemented here.

## Normal gameplay, without companion actions

The inspected projectile path calculates damage locally, reports a projectile/shooter pair, then
notifies local presentation. The inspected report does not serialize HP or damage. Live ordinary
hits can leave the stored HP unchanged until a received stat assignment arrives.

The server's status/tick message `BJEENKGELLO` contains a tick number, timing values and entity
status records. Stat ID 1 becomes a direct assignment to entity HP. A tick can omit unchanged HP.
Two prior observation-only recordings have 174 positive HP assignments; all use this received-stat
route. They establish received recovery, not the individual VIT/pet producer or the number of heal procs.

After applying tick statuses, the client sends `FKGDHGJDNAO`, containing that tick number, a
server-origin timing value and timed position records. The inspected tick response has no HP field.
It identifies a received tick; it does not by itself acknowledge which outgoing hits the server
included in that tick. The normal client's stored HP is refreshed from server state. The companion's
pending-damage estimate is additional state, with additional reconciliation requirements.

Native boundaries for the currently reviewed build:

| Boundary | Address | Observed fields / behavior |
|---|---|---|
| Projectile report | `0x1853fb0`; initializer `0x7e2830` | Projectile + shooter IDs |
| Tick receive handler | `0x18496e0` | Tick ID `+0x10`, timing `+0x14/+0x18/+0x1c`, statuses `+0x20` |
| HP assignment | Call `0x184c110` → `0x1af1670` | Received integer replaces HP at entity `+0x20c` |
| Tick response | `0x184a0a0`; send `0x184a2f8` | Received tick ID, timing value, timed positions |
| Tick response serializer | `0x1460f20` | Packet `+0x1c/+0x20/+0x28`, no HP field |
| Received damage handlers | `0x1840650`, `0x1841230` | Target, damage, projectile/shooter, raw flags |

GameAssembly SHA-256: `ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`.
Addresses and metadata are build-specific. A class called Regeneration is not evidence of an HP
producer; inspected metadata also contains animation/presentation classes with such names.

## Where to intervene

For a client-reported hit, the latest causal opportunity is before its damage-producing report is
forwarded. Waiting for an incoming lethal HP/death message is too late to withhold that report.
The existing projectile calculator/report hooks already straddle this boundary. Moving a hook a
few instructions later does not repair an uncertain HP estimate.

Ground/area damage must also be stopped before its local HP effect where applicable, so its final
notification hook remains relevant. Successful local Nexusing must precede suppression; received
server HP/death is never rewritten into a fabricated survival state. These statements describe
placement and local ordering, not a guarantee that the server accepts an escape.

The missing decision input is which previous reports a received HP snapshot already includes.
If that coverage is verified, use its authoritative HP and replay only uncovered inputs. Healing
included in the snapshot is naturally included in that HP; additional local healing should only
be replayed after its actual prediction and coverage semantics are verified. If coverage is absent,
net HP and packet arrival spacing cannot uniquely separate damage from overlapping healing.

## Observation-only synchronization trace

Build in the canonical repository with `sh probe/build-sync-probe.sh`. It produces the separate
signed `build/damage-diagnostic/ExaltSyncProbe.dylib`. Launch the existing diagnostic command with
`--sync`; the installed companion app is not replaced. This mode forces intervention off even if
an inherited environment requests it. Existing diagnostic behavior forces gameplay automation off.

It records decoded numeric fields using the existing tick/send hooks and two additional diagnostic
damage-handler hooks. The latter validate method identity, signature, address and full instruction
prefixes before redirecting, and always forward the original call once with unchanged arguments.
Fields are accessed only for validated message classes on the main thread. There are no raw packet
payloads, credentials, packet modifications, inferred acknowledgements, auto Nexus or nullified hits.
The extra trace is capped at 12,000 events and uses the existing bounded recorder/queue.

| Phase | Meaning |
|---|---|
| 40 / 46 | Actual decoded tick at entry / return; return copies entry fields because the message is pooled inside the handler |
| 41 | Outgoing tick response at SendMessage entry |
| 42 | Outgoing projectile-hit report at SendMessage entry |
| 43 / 44 | Received damage-handler entry / return, including calls targeting other players |

For these phases, `update_context` stores local player ID. Phase 43 `projectile` stores target ID;
`owner` is shooter, `bullet` projectile ID, `value` damage. Flags 0/1/2 are raw message booleans;
flag 3 identifies the handler. Tick phases retain the packet tick ID, server-origin value in
`server_time`, timing field in `value`, and undecoded quality field in `bullet`. Phase 40 correlation
links the ordinary phase-16 update context; phases 44/46 link their entry records. None of those
local record IDs are protocol acknowledgements.

Use `python3 probe/analyze_sync.py LOG` after ordinary healthy gameplay with some regeneration,
pet healing if available, and a few small hits. Manually Nexus afterward. No death test, separate
sessions, manual labels or uploads are required. The decoder lists same-key incoming damage
candidates and keyed tick responses, preserves ambiguous/reused keys, and explicitly leaves
snapshot coverage unverified. A matching incoming message may support correlation but still does
not prove which HP assignment includes the hit. Missing/dropped/capped observations are reported.

This capture is the next step toward selecting the escape condition, not a new timing heuristic.
The previous dense chart was a synthetic replay with assumed local healing visibility; its exact
divergence is not measured server behavior and must not be used as protocol evidence.

### Capture through the installed app

`zsh ./build.sh --app-only --sync-capture` builds and installs the observation-only recorder inside the existing Exalt Client Mac app. Its dedicated observation screen uses the normal Start game flow, reports recorder readiness after initialization in Nexus, and exposes no automation controls. It does not save over normal gameplay settings. The launch environment explicitly disables intervention and one-HP verification; the native diagnostic build also forces intervention off independently. Logs remain in the usual Application Support log folder.

The readiness field is reused only in this diagnostic build: 0 waiting, 1 recorder ready, 2 event cap reached, -1 initialization refused. Normal production builds retain the original field meaning. Rebuild without `--sync-capture` to restore the regular gameplay app.

## Installed-app passive capture, 20 October 2026


- 14 outgoing projectile reports, each paired with the local notification path: 11 positive damage values and 3 zero values.
- 98 HP setter calls: 80 increases, 11 decreases, 7 unchanged assignments. All 98 were incoming-stat assignments (source 1), caller `0x184c115`. This supports server-driven stored HP for this observed run; it does not prove absence of other HP producers globally.
- Small +1/+2 increases and larger +41 increases used the same incoming-stat route. Neither increase size nor timing identifies VIT, pet or potion conclusively.
- All 389 decoded tick IDs and associated server values matched the outgoing response tuple. Median receive-handler-to-SendMessage-entry delay was 0.020 ms (range 0.002–0.938 ms). This is local handler timing, **not network RTT or server acknowledgement latency**.
- No incoming damage events were captured by either of the two instrumented decoded damage handlers. Therefore this capture provides no projectile-keyed incoming acknowledgement; it does not prove no other acknowledgement path exists.

## Concrete overlapping-hit example

Times below are client monotonic receipt/call times relative to the first report. Stored HP is the game's integer HP field, not a companion prediction.

| Time | Event | Stored HP |
|---:|---|---:|
| 0 ms | Projectile A sent; following local notification has damage 44 | 225 |
| 282.945 ms | Projectile B sent; following local notification has damage 44 | 225 |
| 366.611 ms | Incoming tick 90 starts | 225 |
| 366.654 ms | Tick 90 assigns HP | 181 |
| 566.289 ms | Incoming tick 91 starts | 181 |
| 566.339 ms | Tick 91 assigns HP | 138 |

The arithmetic is consistent with one 44-damage hit becoming visible first, followed by a second 44-damage hit and 1 HP recovery. This attribution is an inference, not a keyed acknowledgement. What is directly measured: two reports went out while HP remained 225; later incoming ticks assigned 181 and 138. Reading 181 as a fresh baseline and clearing *all* outstanding reports would remove the other hit from the guard's projection. Conversely, subtracting both reports forever after receiving 138 would count damage twice. The tick-response tuple establishes which tick the client processed, not which outgoing projectile reports that tick's HP includes.

A further sequence shows a notification for 54 damage at stored HP 78, followed by manual Nexus at HP 78, then an incoming assignment to 25 about 134 ms after the Nexus call. This is not a death and does not measure when server-side Nexus completed; it illustrates why last stored HP can lag damage even around a Nexus request.


The capture loaded the intended passive recorder: 389 incoming ticks and matching responses, no recorded queue drops, no event cap reached. This was a copied window from an ongoing session (`complete=0`). Preserve PR 10 as draft: tick response matching does not establish per-hit HP coverage. Detailed evidence and hashes are saved in `build/hp-sync-audit-20261020/app-capture-31242/`.
