# Game compatibility update, October 15, 2026

The installed GameAssembly changed from `0d11bbb7d32c25203c1083300fbd3d8208f0b3215469e93553b6cab9f988d739`
to `ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`. The app correctly refused to
launch the old integration. This update keeps the hash check and retargets the existing features.
Forgefire is separate and is not included.

## What changed

| Function | Old address | Current address |
|---|---|---|
| Potion quickslot handler | `0x52cc60` | `0x1fe30f0` |
| Nexus input | `0x7264f0` | `0x1841500` |
| Party Join | `0xa3d060` | `0x13e7dc0` |
| Join cooldown | `0x11f7e00` | `0x1962b60` |
| Player-hit report | `0x712c10` | `0x1853fb0` |
| Projectile notification | `0x11f6a60` | `0x1970a90` |
| HP assignment | `0x177ca50` | `0x1af1670` |
| Projectile damage calculation | `0x2051720` | `0x650e90` |
| Death-screen display | `0x6d8f70` | `0x1f92870` |
| Incoming update | `0x71a120` | `0x18496e0` |
| Incoming stat application | `0x71e940` | `0x184ae90` |

Method identities and signatures were matched in the new IL2CPP version 31 metadata dump, then checked
against native implementations. Twenty-three relevant field declarations and offsets matched the old
build. Runtime field-type and method-signature checks remain active.

The HP assignment still writes the integer at `0x20c`, then invokes its virtual callback. That callback
and its MethodInfo moved from class slots `0x718`/`0x720` to `0x9a8`/`0x9b0`. The hook prefix and native
fixture now preserve the new loads. The eight complete hook prefixes match the installed binary.

In `HBEAKBIHANL.GJFKGLJEGKO`, the controlled-player damage calculation call now returns at `0x6538a2`.
Its result still feeds the HP comparison and the hit-report path. The local projectile notification
returns at `0x653bd0` via virtual slot `0x898` and MethodInfo slot `0x8a0`.
`FKALGHJIADI.FNEBPDEDIJP` is slot 118 in the updated metadata, matching that virtual call.
The separate zero-HP assignment caller now returns at `0x1840e64`.

The normal Nexus input reaches the connection's escape routine at `0x1841830`, which calls
`SocketManager.Nexusing` at `0x199e040` before sending the normal request. The manager's local Nexusing
flag remains `FCOJPHFICAG`. This establishes the current client path, not server acceptance.

## Verification

`python3 tests/verify_game_build.py` verifies the installed hash, all eight hook prefixes, three action
entry prefixes and three audited caller sites. The build runs this check before its synthetic tests.
The native HP fixture tests the changed virtual callback slots while preserving the assigned HP.
Existing tests cover potion pacing, manual Join, Arm/Dry Run, death-hook toggles, failed Nexus requests,
server HP reconciliation and preserving the escape latch.

Raw disassembly and the method mapping are retained locally in `build/game-update-audit/`. They are
ignored by Git. Live readiness and behavior must still be confirmed in Nexus after installing the app.
This update does not broaden damage-source coverage or guarantee survival.

🤖 Generated with Codex

## Installed verification

Passed: 33 guard tests, 19 diagnostic tests, seven production intervention tests, eight shadow-ledger
tests, native trampoline/policy checks, Swift model/settings/launch checks, cross-architecture shared
state checks and compact/expand UI regression. Two offset-rejection cases were also rerun after updating
their intentionally invalid addresses. The UI regression required desktop access; its initial sandboxed
process exited before showing a window. The restricted icon-generation step also failed; the normal
desktop build completed and the signed installed bundle matches its build output.

The previous app is preserved under `build/game-update-audit/backup/Exalt Client Mac.app`. Existing
settings and logs were retained. The new installed app was opened and its Start game button successfully
opened DECA's launcher with the guard. Actual updated-game hook installation and gameplay have not yet
been observed. Wait for readiness in Nexus before relying on the feature.
