# Early-Nexus correction and runtime efficiency

Policy version 3 restores authoritative HP windows after the confirmed 1206-HP/110-damage false
escape. It no longer carries old damage indefinitely across HP updates or healing. Same-window
projectile/ground/area bursts and confirmed escape latches remain protected. Server report ordering
is still uncertain; this is not acknowledgement-aware reconciliation. See the [audit](../docs/damage-status-audit.md).

Production-only efficiency changes skip discarded diagnostic snapshots and ordinary prediction
logs and reduce the fixed event queue by 192 KiB. Standalone diagnostics retain their existing tracing.
See [performance measurements](../docs/performance-audit.md) for component measurements and limits.

Current validation passes: 17 production tests, 24 diagnostic tests, 16 session-report tests, five
native-map tests and the undefined-behavior-sanitized policy suite. Production and diagnostic libraries compile with warnings treated as errors; the signed app build passes. The captured 1206-HP state yields PASS/projected 876,
where the earlier version-2 policy yields REQUEST/projected -108.

## Current live evidence and limits

Projectile, ground and radius/AOE traces show local escape requests, matching report suppression
and later Nexus arrivals at safe actual HP. See [live evidence](../docs/damage-live-validation.md).
The Citadel trace establishes full-frostbite/server-HP ordering; the new automatic environmental
escapes and oxygen transition remain live-unverified. Incoming HP updates do not acknowledge
individual hit reports, and local Nexusing does not confirm server acceptance.

Whole-session probe reports remain inconclusive when the unlimited-duration run lacks a quit-time
completion marker. Raw sessions and fingerprints are retained as ignored local evidence. This
validation does not establish universal lethal survival.
