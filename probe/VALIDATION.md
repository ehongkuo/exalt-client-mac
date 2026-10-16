# Diagnostic validation

## Damage discovery milestone, 2026-10-16

This milestone adds observation and reporting, not non-projectile protection. The installed GameAssembly
hash still matches the reviewed `ad069824...` build. Static verification passed for seven mapped methods,
five notification dispatch sites, three optional field declarations and the selected native instruction
evidence. The field declarations were checked against the matching retained metadata dump; the breath
and frostbite UI readers load the controlled-player reference declared at GUI field `+0xc8`.

Passed the full test-only build: 16 compatibility tests, 33 guard fixtures, 21 diagnostic tests, seven
production intervention tests, eight shadow-ledger tests, native trampoline/fatal-policy tests, Swift
model/settings/launch tests, cross-architecture shared-state checks and the synthetic compact/expand UI.
The new map tests pass all four cases. The session-report tests were rerun after their final additions:
15 pass, including malformed/incomplete evidence, raw meter context, exact notification correlation, live-process
refusal, bundle overwrite refusal, invalid samples and death recovery from the binary tail.

The standalone build reran all 21 diagnostic tests against the final recorder/analyzer changes and
built a signed `ExaltHitProbe.dylib` under `build/damage-diagnostic/`. A separate production guard compile
with `-Wall -Wextra -Werror` passed. The new native fixtures confirm that unavailable fields preserve
original calls, raw 64-bit context survives text/flight recovery, and unknown calculator callers never
request Nexus, suppress damage or enter shadow budgets. Map transitions remain recorded when first
encountered inside a hook.

No live gameplay tests for terrain, AOE, bleeding, oxygen or frostbite have been executed. There is no
new evidence of server acceptance, no exhaustive source-coverage claim and no survival guarantee.
The installed app and game files were not replaced. Follow `docs/damage-testing.md` beginning with D00.

## Earlier projectile validation, 2026-10-13

The active fixture uses 200 observed HP and six same-frame calculated hits of 50. The first three reports and notifications reach the original game functions. Before the fourth report, one Nexus invocation sets the simulated local Nexusing flag. The fourth and later calculations return zero; three report calls and three local notifications are suppressed. The original calculator is still called on all six hits. An off-main report and notification are also suppressed by identity-only checks. Ordinary updates continue, and the simulated Nexus transition resets the latch.

The fixture deliberately makes the invalid native argument 0x3 fault if inspected. The active intervention preserves that argument and never inspects it. No original calculator result is changed in observation-only mode. Synthetic Nexus/death/map behavior is scripted and does not establish server acceptance.

Two failure cases are covered: a Nexus invocation that returns without setting its flag, and one that raises an exception. Both preserve original damage/report handling and do not make repeated automatic requests. The existing entry-byte mismatch refusal, pointer-regression, update-boundary, recovery and legacy-observer cases remain in the suite.

The fatal-policy tests cover exact-zero burst crossing, server HP baseline replacement (including unchanged HP), active escape latch preservation, one-request latching, failed-request behavior, scope resets, already-nonpositive HP, invalid damage and zero damage. No percentage threshold participates in this policy.

The native tests preserve original argument/return behavior outside active cancellation and validate the audited HP and death-screen prefixes. The regular guard still compiles independently; its core tests pass. Python and launcher syntax, signing and whitespace checks are completed when publishing this build.

Live use is unverified. Server acceptance, server-independent damage and damage paths outside the audited projectile branch remain unresolved. The conservative budget can cause early Nexus. The local Nexusing flag confirms client state only. Existing queued reports are unaffected.

The reconciliation fixture retains one 50-damage hit, applies an incoming HP assignment of 200, then runs the six-hit burst. The old damage is retired and the fourth burst hit triggers escape. A further HP assignment while escaping clears the budget without allowing any blocked report or notification through. Resetting on an assignment is not proof that the server processed every pending hit.
