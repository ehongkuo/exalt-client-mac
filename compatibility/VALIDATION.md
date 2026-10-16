# Compatibility profile validation

October 15, 2026. Branch: `feat/compatibility-profiles`, based on compatibility fix `720ae8d`.

## Actual game inputs

The current binary passed verification against the selected reviewed profile. The complete local dumper
workflow ran against the installed GameAssembly and metadata, then produced reports without editing a
profile or runtime output. Input fingerprints are retained in the generated JSON report.

- Current baseline against current binary/dump: 13 methods, 27 fields and three call sites unchanged.
- Previous reference against current binary/dump: 12 methods moved, one HP method entry changed,
  27 fields unchanged and three call sites moved.
- Both reports retain `approved_for_runtime: false` and `manual_review_required: true`.

The previous-to-current report reproduced the native findings from the manual game-update audit. A copy
is retained in [examples/previous-to-current.md](examples/previous-to-current.md). Generated dumps and
full reports remain local under `build/compatibility/validation/`.

## Automated checks

The compatibility tests cover profile completeness and role mappings, duplicate keys/constants,
unreviewed/historical generation rejection, stale generated files, malformed Mach-O bounds/architecture,
method overloads and nested/array types, changed static storage, missing/ambiguous identities and calls,
unknown-build rejection, bounded output creation, the external dumper workflow, input changes during
analysis and preserving manual-review status.

The existing fixture addresses and method names now consume the generated profile. Wrong-offset cases
still perturb the address deliberately; gameplay decision assertions remain unchanged. Actual-binary
verification independently checks the profile's fingerprint, entry prefixes and caller destinations.

The first refactored run passed 33 guard tests, 19 diagnostic tests, seven production intervention tests,
eight shadow-ledger tests, native trampoline/policy checks, Swift model/settings/launch checks and shared
state/cross-architecture tests. The UI regression could not open a desktop window in the restricted
sandbox; a separate desktop-access run passed all four compact/expand transitions with synthetic data.

After centralizing fixture addresses, a parallel rerun hit macOS library-load failures/startup deadlines
in some diagnostic fixtures. The real game was not involved. The serial desktop-access rerun passed all 19 diagnostic tests and all seven production intervention
tests. Results are recorded in `probe-serial.log` and `client-serial.log`; the guard fixture rerun passed
all 33 cases in `guard-final.log`. The 16 compatibility tests passed after their final schema and CLI
changes, including rejecting input mutation and incorrect caller roles.

## Build

A separate app bundle was built and signed under `build/Exalt Client Mac.app`. Its bundled
`compatibility-profile.json` and build fingerprint match the selected source profile. Native runtime
values remain compiled constants; no per-frame profile parsing, scanning or polling was added.
The installed app and user settings were not replaced by this task. No real gameplay actions were run.

Logs and the staged app are ignored build artifacts. This validation establishes profile/tooling and
synthetic regression behavior; it does not approve an unknown game version or expand damage coverage.

🤖 Generated with Codex
