# Fatal-intervention validation, 2026-10-13

The active fixture uses 200 observed HP and six same-frame calculated hits of 50. The first three reports and notifications reach the original game functions. Before the fourth report, one Nexus invocation sets the simulated local Nexusing flag. The fourth and later calculations return zero; three report calls and three local notifications are suppressed. The original calculator is still called on all six hits. An off-main report and notification are also suppressed by identity-only checks. Ordinary updates continue, and the simulated Nexus transition resets the latch.

The fixture deliberately makes the invalid native argument 0x3 fault if inspected. The active intervention preserves that argument and never inspects it. No original calculator result is changed in observation-only mode. Synthetic Nexus/death/map behavior is scripted and does not establish server acceptance.

Two failure cases are covered: a Nexus invocation that returns without setting its flag, and one that raises an exception. Both preserve original damage/report handling and do not make repeated automatic requests. The existing entry-byte mismatch refusal, pointer-regression, update-boundary, recovery and legacy-observer cases remain in the suite.

The fatal-policy tests cover exact-zero burst crossing, server HP baseline replacement (including unchanged HP), active escape latch preservation, one-request latching, failed-request behavior, scope resets, already-nonpositive HP, invalid damage and zero damage. No percentage threshold participates in this policy.

The native tests preserve original argument/return behavior outside active cancellation and validate the audited HP and death-screen prefixes. The regular guard still compiles independently; its core tests pass. Python and launcher syntax, signing and whitespace checks are completed when publishing this build.

Live use is unverified. Server acceptance, server-independent damage and damage paths outside the audited projectile branch remain unresolved. The conservative budget can cause early Nexus. The local Nexusing flag confirms client state only. Existing queued reports are unaffected.

The reconciliation fixture retains one 50-damage hit, applies an incoming HP assignment of 200, then runs the six-hit burst. The old damage is retired and the fourth burst hit triggers escape. A further HP assignment while escaping clears the budget without allowing any blocked report or notification through. Resetting on an assignment is not proof that the server processed every pending hit.
