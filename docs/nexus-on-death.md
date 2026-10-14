# Nexus on death integration

Enable **Nexus on death** in the client Settings and click **Apply**. The toggle is off for existing saved settings. Keep potion settings as desired. For an isolated predicted-death test, temporarily set the potion trigger and ceiling to Off, then enable Armed and this toggle. Percentage Auto-Nexus has been removed; old saved `nexus` values are discarded, and existing potion and death-toggle values are preserved. Enter Nexus and wait for **Nexus on death ready** before entering a fresh map with a throwaway character.

The app shows “Nexus on death” events and counts successful local requests in its Nexus session total. Its logs are in `~/Library/Application Support/Exalt Client Mac/logs`. The validated standalone diagnostic, source checkpoint `639068f`, logs and live test reports remain available for future development. The integrated client has recorded three successful projectile escapes with potions disabled; percentage-threshold removal still needs its own live UI check.

The prediction and cancellation behavior matches the validated prototype: incoming HP assignments replace the baseline, local projectile calculations accumulate between assignments, and a crossing of zero requests Nexus before the hit report. Suppression starts only when the local Nexusing flag is confirmed. Settings changes cannot cancel an already-started escape. Failed requests preserve the original damage path and are logged. Dry Run never requests an automatic Nexus or suppresses damage.

The hooks prepare in Nexus and validate method signatures, offsets and complete entry bytes. If preparation is refused, the UI reports that the feature is unavailable while the existing guard remains usable. Turning the feature on outside Nexus waits for preparation there. No installed game files are modified.

The app integration must be tested live. The earlier five successful projectile escapes do not establish universal death prevention. Other damage sources, stale HP updates, unacknowledged reports, server ordering and interrupted transitions remain unresolved. The edge-case simulation work was deferred when integration was requested; this change does not claim to resolve those races.

🤖 Generated with Codex
