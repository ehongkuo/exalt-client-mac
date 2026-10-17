# Nexus on death integration

Enable **Nexus on death** in the client Settings and click **Apply**. The toggle is off for existing saved settings. Keep potion settings as desired. For an isolated predicted-death test, temporarily set the potion trigger and ceiling to Off, then enable Armed and this toggle. Percentage Auto-Nexus has been removed; old saved `nexus` values are discarded, and existing potion and death-toggle values are preserved. Enter Nexus and wait for **Nexus on death ready** before entering a fresh map with a throwaway character.

The app shows “Nexus on death” events and counts successful local requests in its Nexus session total. Its logs are in `~/Library/Application Support/Exalt Client Mac/logs`. The validated standalone diagnostic, source checkpoint `639068f`, logs and live test reports remain available for future development. The integrated client has recorded three successful projectile escapes with potions disabled; percentage-threshold removal still needs its own live UI check.

Prediction now retains uncertain damage across HP assignments, including unchanged, healing and delayed updates. The bound cannot rise until a validated scope reset; this prioritizes a conservative escape and can Nexus early during sustained combat. See the [status and reconciliation audit](damage-status-audit.md) for the regression and tradeoff. Suppression starts only when the local Nexusing flag is confirmed. Settings changes cannot cancel an already-started escape. Failed requests preserve the original damage path and are logged. Dry Run never requests an automatic Nexus or suppresses damage.

The hooks prepare in Nexus and validate method signatures, offsets and complete entry bytes. If preparation is refused, the UI reports that the feature is unavailable while the existing guard remains usable. Turning the feature on outside Nexus waits for preparation there. No installed game files are modified.

The expanded implementation also guards final damage notifications from the audited ground and
radius/AOE paths, before their HP effects and outgoing reports. It uses the same pending-damage budget
as projectiles, without counting projectile notifications again. Ground and area reports are suppressed
only at their exact audited SendMessage call sites, on the retained escaping socket. Nexus messages and
unrelated traffic pass through. Method identity, entry bytes, notification dispatches and report call
instructions are checked before installing any of the nine hooks.

This is not universal death prevention. Incoming server HP assignments are authoritative observations;
ignoring a zero assignment cannot undo a death already decided remotely. Breath and frostbite meter
setters are called from the incoming stat handler (`0x184cb6f` and `0x184c7da` respectively), which does
not establish a cancellable local damage calculation. Projectile, ground and area escape wiring has
live evidence; the Citadel trace establishes full-meter/server-HP ordering. Environmental escape
and server acceptance under lethal conditions remain unverified. Bleeding alone is nonlethal.

The minimum check is one projectile, one ground and one radius/AOE escape, with automatic log capture;
see [verification steps and native evidence](damage-testing.md). Testing every enemy or tile is unnecessary
once shared native routing is demonstrated. [Damage-source evidence](damage-sources.md) records the
remaining gaps.

## Environmental escape

With Nexus on death enabled and Armed, the same validated Nexus request/latch now also runs at
`frostbite >= 100`, regardless of HP. Exhausted oxygen (`breath == 0`) uses the same request, but only
after a positive breath value was observed in the same validated player/map/connection scope. This
avoids interpreting a default zero as active suffocation. Negative breath is inactive. Missing meter
fields disable their trigger. Scope changes clear the breath history and retry timer.

The Citadel trace shows full frostbite followed by incoming server HP assignments, not a cancellable
local hit. These guards deliberately escape at the hazardous meter limit, even at full HP; they do
not wait for predicted death or cancel/rewrite server HP. Requests retry at most once per second on
failure. Dry run records intentions without invoking Nexus. Normal observation mode remains passive.
Oxygen uses a shared escape routine, but its meter transition has not been observed in a live run.
Bleeding alone cannot kill players and does not require a dedicated lethal-source test.
