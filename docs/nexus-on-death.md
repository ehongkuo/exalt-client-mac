# Nexus on death integration

Enable **Nexus on death** in the client Settings and click **Apply**. The toggle is off for existing saved settings. Keep potion settings as desired. For an isolated predicted-death test, temporarily set the potion trigger and ceiling to Off, then enable Armed and this toggle. Percentage Auto-Nexus has been removed; old saved `nexus` values are discarded, and existing potion and death-toggle values are preserved. Enter Nexus and wait for **Nexus on death ready** before entering a fresh map with a throwaway character.

The app shows “Nexus on death” events and counts successful local requests in its Nexus session total. Its logs are in `~/Library/Application Support/Exalt Client Mac/logs`.

Prediction uses the latest authoritative HP assignment as a new baseline. Projectile, ground and
area damage accumulate within that window; healing and unchanged incoming HP also start a new
window so old damage cannot accumulate indefinitely. This restores the previously working client's
HP-window behavior. Incoming HP is not a per-report acknowledgement, so late/in-flight report ordering
remains a limitation. Suppression starts only after local Nexusing is confirmed; an already-started
escape survives settings changes and HP updates. Dry run never invokes Nexus or suppresses damage.
See the [false-escape audit and correction](damage-status-audit.md).

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

Policy version 6 adds a guard before the shared HP setter for the controlled player. A locally
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
