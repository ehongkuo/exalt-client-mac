# Nexus on death integration

Enable **Nexus on death** in the client Settings and click **Apply**. The toggle is off for existing saved settings. Keep potion settings as desired. For an isolated predicted-death test, temporarily set the potion trigger and ceiling to Off, then enable Armed and this toggle. Percentage Auto-Nexus has been removed; old saved `nexus` values are discarded, and existing potion and death-toggle values are preserved. Enter Nexus and wait for **Nexus on death ready** before entering a fresh map with a throwaway character.

The app shows “Nexus on death” events and counts successful local requests in its Nexus session total. Its logs are in `~/Library/Application Support/Exalt Client Mac/logs`.

Policy version 10 keeps projectile, ground and area damage in the same fixed 128-entry ledger, in
report order. A hit leaves the ledger only through the ordering proof
([hardening plan](nexus-hardening-plan.md), Phase 1). HP changes and elapsed time never clear a hit.
Server HP is only the baseline, so it already includes every heal and every untracked loss.

The ordering proof works as follows:

- Each hit is paired with the client's next reply to a tick. Hit reports and replies share one
  ordered connection, so the reply travels behind the hit.
- Each tick carries the round trip of the latest reply the server received (the tick message's
  `PHBFAKPBEAB`). A new value dates one earlier reply: the one whose tick build time plus the value
  falls between the previous and current build times. The server had that reply, and every hit
  sent before it, by then. A repeated value proves nothing.
- A hit clears on the first tick built at least 200 ms after that bound. With no new round trips (a
  stall or lag), hits stay pending.

Clearing late can only cause an early escape. Expect one when a new hit lands within about two
ticks of the previous one being applied: the earlier hit is still pending, so it is counted twice.
This matters most on low-HP characters (one replay: 225 max HP, hits of 44–54). If the guard can't
find the round-trip or reply fields at install, Nexus on death refuses to start
(`hit_probe_refused\tfatal_proof_fields`), because no hit could ever clear.

A positive hit still requests Nexus when projected HP is nonpositive, updates are stale, or the
ledger fills. Staleness uses the cadence-based rule (at least 1.5 seconds, at most 6 seconds). Only
progressing ticks refresh that heartbeat. Zero damage doesn't trigger the stale or capacity
failsafes. Logs distinguish projected-lethal (reason 1), stale updates (2), and capacity (3). There
is no fixed percentage-HP escape threshold. Each tick that clears hits writes one
`guard_proof_clear` record with the hits cleared, pending damage, projection, tick ID, round trip
and the number of replies proven; the analyzer includes it.

Suppression starts only after local Nexusing is confirmed; an already-started escape survives settings
changes and HP updates. Dry run never invokes Nexus or suppresses damage. See the
[captured failure and reconciliation audit](nexus-failure-2026-10-20.md), and the
[three beach tests](beach-stress-tests.md).

The hooks prepare in Nexus and validate method signatures, offsets and complete entry bytes. If preparation is refused, the UI reports that the feature is unavailable while the existing guard remains usable. Turning the feature on outside Nexus waits for preparation there. No installed game files are modified.

The expanded implementation also guards final damage notifications from the audited ground and
radius/AOE paths, before their HP effects and outgoing reports. It uses the same pending-damage budget
as projectiles, without counting projectile notifications again. Ground and area reports are suppressed
only at their exact audited SendMessage call sites, on the retained escaping socket. Nexus messages and
unrelated traffic pass through. Method identity, entry bytes, notification dispatches and report call
instructions are checked before installing any of the nine hooks.

Protection targets locally computed damage before its HP effect and covered outgoing report.
Incoming HP assignments update the prediction baseline; they never trigger an escape or get
cancelled. Incoming death handling is also outside this local-damage policy. The working scope assumes
client-computed damage is reported afterward; no received-state workaround is part of the mechanism.

The minimum check is one projectile, one ground and one radius/AOE escape, with automatic log capture;
see [verification steps and native evidence](damage-testing.md). Testing every enemy or tile is unnecessary
once shared native routing is demonstrated. [Damage-source evidence](damage-sources.md) records the
remaining gaps.

## Shared local HP hatch and environmental scope

The shared HP hatch, introduced in version 6, guards the controlled player before its HP setter. A locally
computed transition from positive HP to zero/negative HP invokes the same validated Nexus request as
projectile, ground and AOE damage. Only confirmed local Nexusing cancels that write and subsequent
local HP reductions. Healing and positive nonlethal local writes pass without charging the prediction
budget a second time. Known incoming-update contexts/caller and the incoming death caller bypass
this guard. Dry run, disabled protection and failed requests never pretend cancellation.

The existing escape latch continues to suppress audited projectile/ground/area notifications and
reports on the retained escaping player/connection/socket. Scope changes clear the latch normally.

Meter limits alone never request Nexus. Frostbite 100+ and exhausted breath are hazardous conditions,
not lethal inputs. The production client no longer reads these meters; standalone diagnostics can
still observe them. A local environmental producer using the guarded calculation, notification or HP
setter routes gets the same hatch. A distinct local frostbite/suffocation calculation/report path has
not yet been located, so source-specific routing remains unverified. This is a coverage limit, not a
reason to restore meter-limit escapes or received-HP escape attempts. See the
[client-side boundary audit](damage-status-audit.md#client-side-boundary-audit).

## Planned hardening

Known gaps and the proposed fixes are tracked in the [hardening plan](nexus-hardening-plan.md).
