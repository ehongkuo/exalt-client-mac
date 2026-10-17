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

This is not universal death prevention. Incoming server HP assignments are authoritative observations;
ignoring a zero assignment cannot undo a death already decided remotely. Breath and frostbite meter
setters are called from the incoming stat handler (`0x184cb6f` and `0x184c7da` respectively), which does
not establish a cancellable local damage calculation. Projectile, ground and area escape wiring has
live evidence; the Citadel trace establishes full-meter/server-HP ordering. Lethal environmental damage cancellation
and server acceptance under lethal conditions remain unverified. Bleeding alone is nonlethal.

The minimum check is one projectile, one ground and one radius/AOE escape, with automatic log capture;
see [verification steps and native evidence](damage-testing.md). Testing every enemy or tile is unnecessary
once shared native routing is demonstrated. [Damage-source evidence](damage-sources.md) records the
remaining gaps.

## Environmental meters and current coverage

Meter limits alone never request Nexus: frostbite 100+ and exhausted breath indicate hazardous
conditions, not lethal damage. The former unconditional meter escapes have been removed. Meter
values remain available in the standalone diagnostic build; the production client does not poll them.
The shared scope/latch cleanup still runs on every guard tick.

The Citadel trace records frostbite 100 at HP 740/740, followed about 178 ms later by incoming HP 726.
This supports the distinction between a saturated meter and a lethal input. The incoming HP assignment
is not an audited local damage calculation/report boundary. No source-specific cancellable frostbite
or suffocation tick has been established. The settings text labels environmental death prevention
unverified, including the incoming-HP fallback below.

Nonlethal incoming HP updates rebase the normal prediction window. Subsequent audited projectile,
ground and area damage still enters the common lethal prediction and confirmed-escape latch.
Incoming zero-HP assignments are not discarded or rewritten as positive HP: hiding that state would
not establish that a server-originated death was prevented. Policy version 5 adds a last-chance
request before a nonpositive incoming HP value is written locally, restricted to the audited incoming
stat call site. It does not establish server-side cancellation; see the
[native trace](damage-status-audit.md#nonpositive-hp-and-death-native-trace).
