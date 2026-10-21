# Nexus on death integration

Enable **Nexus on death** in the client Settings and click **Apply**. The toggle is off for existing saved settings. Keep potion settings as desired. For an isolated predicted-death test, temporarily set the potion trigger and ceiling to Off, then enable Armed and this toggle. Percentage Auto-Nexus has been removed; old saved `nexus` values are discarded, and existing potion and death-toggle values are preserved. Enter Nexus and wait for **Nexus on death ready** before entering a fresh map with a throwaway character.

The app shows “Nexus on death” events and counts successful local requests in its Nexus session total. Its logs are in `~/Library/Application Support/Exalt Client Mac/logs`.

Policy version 8 retains projectile, ground and area damage in the same fixed 128-entry ledger.
Observed HP decreases still retire estimates oldest-first by their net amount; this is an inference,
not identification of individual hits. HP increases supply a higher baseline without discarding
pending hits or adding a separate estimated healing credit. The strict whole-event/history model
in [the design proposal](nexus-reconciliation-design.md) is not implemented or assumed proven.

Individual hits no longer expire by age. A quiet rebase clears the remaining ledger only after:

- No positive predicted damage inputs for the settlement allowance.
- A continuous interval of progressing tick IDs and server-origin timing values for that allowance.
- A completed tick actually assigns the controlled player's HP, including a same-value assignment.
- No new damage input occurs inside that tick handler and no escape is already latched.

The allowance is max(2 seconds, four smoothed tick intervals plus eight observed jitter values),
capped at 8 seconds. These are explicit candidate policy parameters, not a measured upper bound on
server processing or network delay. Receive gaps over 1 second, bunched ticks under 20 ms, or skipped
IDs restart the healthy interval. Duplicate/reversed tick IDs or timing values cannot qualify and
invalidate the interval. Counters support UInt32 wrap. A tick omitting unchanged HP updates liveness
but cannot itself rebase. A standalone stat setter and elapsed local time also cannot rebase.

The rebase condition assumes earlier reports have settled during healthy, quiet communication. It
is not a server acknowledgement. A long-delayed stream that still appears healthy can violate that
assumption. During continuous damage with healing, estimates can remain conservative and trigger an
early escape; quiet rebasing needs a new HP-bearing tick to recover. This change does not establish
coverage for untracked HP losses or equality between local and server damage calculations.

A positive hit still requests Nexus when projected HP is nonpositive, updates are stale, or the
ledger fills. Staleness uses the prior cadence-based rule (at least 1.5 seconds, at most 6 seconds),
independently of the new settlement allowance. Only validated progressing completed ticks refresh
that heartbeat. Zero damage does not restart the quiet timer or trigger the stale/capacity failsafes.
Logs distinguish projected-lethal (reason 1), stale updates (2), and capacity (3). There is no fixed
percentage-HP escape threshold. Each actual rebase writes one `guard_quiet_rebase` record containing
retired damage, quiet duration, allowance, tick ID and `assumed_settled=1`; the analyzer includes it.

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
