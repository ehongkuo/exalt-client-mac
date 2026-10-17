# Early-Nexus correction and runtime efficiency

Policy version 3 restores authoritative HP windows after the confirmed 1206-HP/110-damage false
escape. It no longer carries old damage indefinitely across HP updates or healing. Same-window
projectile/ground/area bursts and confirmed escape latches remain protected. Server report ordering
is still uncertain; this is not acknowledgement-aware reconciliation. See the [audit](../docs/damage-status-audit.md).

Production-only efficiency changes skip discarded diagnostic snapshots and ordinary prediction
logs and reduce the fixed event queue by 192 KiB. Standalone diagnostics retain their existing tracing.
See [performance measurements](../docs/performance-audit.md) for component measurements and limits.

Current validation passes: 17 production tests, 24 diagnostic tests, 16 session-report tests, five
native-map tests and the undefined-behavior-sanitized policy suite. A signed corrected app builds
without touching the running installed app. The captured 1206-HP state yields PASS/projected 876,
where the archived version-2 policy yields REQUEST/projected -108.

## Historical validation through 2eccaad (superseded policy)

# Environmental guard validation

The Citadel run `D06-20261017T000048Z-AQqfYg` recorded full frostbite before incoming HP loss.
See [the evidence audit](../docs/damage-status-audit.md) for event IDs, timing and raw fingerprint.
The session completion marker is missing, so the whole-session report remains inconclusive.
The new environmental guard requests the normal Nexus escape at frostbite >= 100 or breath == 0
after positive breath in the same scope, regardless of HP. This is proactive escape, not cancellation
of server-owned damage. The oxygen transition and both new automatic triggers remain live-unverified.
No additional live test is required to prepare this review; this limitation remains explicit.

Current validation: 16 production intervention tests, 24 diagnostic tests, 16 session-report tests,
five map tests and eight shadow-ledger tests passed. Native trampolines and the fatal policy
(including undefined-behavior sanitization) passed; the production guard and Swift app compiled
with warnings treated as errors. The signed diagnostic package built and verified. The environmental
fixtures cover 100/101 frostbite, oxygen exhaustion after positive breath, inactive zero breath,
subthreshold frostbite, missing fields, dry run/disabled protection and bounded retry failures.

# Status and reconciliation hardening

The current policy retains uncertain damage across HP updates and cannot increase its HP bound from
healing or a higher stale assignment. It can therefore escape early during sustained combat. A
positive HP update that makes retained damage lethal can request Nexus without suppressing the
assignment. Failed requests continue retaining damage and become retryable after another positive HP
update. See [the native audit and tradeoffs](../docs/damage-status-audit.md).

The diagnostic condition source is corrected to the first two Int32 words in the living entity's
`COHCKAPOLCA` array. Null or short arrays are unavailable; corrected records carry `flag2=1`.
Legacy phase-29 values came from a sprite key and are no longer labeled as condition flags by readers.
The native map now verifies 15 methods, four fields, stat routing for HP/breath/frostbite and two
condition words, plus the instruction evidence. Individual bleeding flags and cancellable local
status/environmental damage calculations remain unresolved.

Validation passed for this pass: 12 production intervention tests, 23 diagnostic tests, 16 session-report
tests, five native-map tests, eight shadow-ledger tests and 16 compatibility tests. The fatal policy
also passes undefined-behavior sanitization for boundary arithmetic. Native trampoline checks,
production guard compilation, Swift app compilation, script checks and signed package verification pass.
The mixed-source native fixture preserves damage through unchanged/lower/healing updates, and a
separate fixture requests Nexus on a positive HP update without canceling the assignment.

The prior live results below validate implementation `73a01ef` and the shared hook wiring. They do
not measure the new conservative policy's false-positive rate. The signed verification package can
be rebuilt without replacing the installed client. Raw X01-X03 artifacts remain unchanged.

## Earlier expanded damage protection validation

The expanded implementation covers audited projectile, ground and radius/AOE boundaries. It shares
one fatal-damage policy and normal Nexus request, retains player/connection/socket handles through
escape, and suppresses only matching reports after local Nexusing is confirmed. Incoming authoritative
HP updates and unresolved status/meter damage are not claimed covered.

The new SendMessage hook uses a 17-byte whole-instruction prologue. An Intel native fixture executes
that exact prologue through its trampoline and checks argument forwarding. Runtime installation
validates its typed method, offset, prologue, both new notification dispatches and outgoing report
instructions before installing hooks. The new map is specific to the reviewed October 15 game hash.
Changing compatibility profiles requires re-auditing these additional boundaries.

Production fixtures exercise both ground and area routing, cumulative fatal thresholds, repeated
hits during escape, denied and exception-throwing requests, unrelated call sites, unrelated sockets,
Dry Run and disabled protection. The diagnostic-only `--verify` mode uses a synthetic 1-HP prediction
without writing actual HP. A native diagnostic fixture checks escape on the first 50-damage hit while
actual HP remains 200; production tests set the same environment variable and still require the normal
200-HP threshold, demonstrating that the override is unavailable in the client.

Validation passed: 16 compatibility tests, four native-map tests, 15 reporting tests, 33 guard fixtures,
22 diagnostic tests, native trampolines and fatal-policy checks, Swift model/settings/launch checks,
and cross-architecture state checks. The signed diagnostic package builds successfully; the production
guard compiles with warnings treated as errors. All 10 production intervention tests and the synthetic compact/expand UI regression also passed.
The ground/area report analysis assertions passed again after the final reporting changes.

Live X01/X02/X03 checks now show the expected projectile, ground and final radius/AOE cancellation
sequences and later Nexus arrivals. See [the evidence and capture-lifecycle caveat](../docs/damage-live-validation.md).
The generated whole-session reports remain inconclusive because quitting does not emit the timed-test
completion marker. The captured escape sequences do not require repeating the same three wiring checks.
A local Nexusing flag is not a server acknowledgement, and these checks do not prove universal lethal
survival. Bleeding, suffocation and frostbite require further source-specific evidence.

## Diagnostic validation

## Prior damage discovery milestone, 2026-10-16

The prior milestone added observation and reporting, without non-projectile protection. The installed GameAssembly
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
