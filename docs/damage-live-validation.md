# Live verification: October 16, 2026

Reviewed the user's X01, X02 and X03 bundles against implementation commit `73a01ef`.
All sessions recorded the expected game fingerprint, hook readiness and diagnostic 1-HP prediction.
Actual observed player HP was 235 at each target decision and remained 235 in subsequent valid samples.
These were small-hit wiring checks, not lethal-hit survival tests.

| Run | Target request event | Damage | Cancellation evidence | Later Nexus arrival |
|---|---:|---:|---|---:|
| X01 projectile | 28405 | 91 | Phase 22 accepted; phase 23 player-hit report withheld; phase 24 notification caller `0x653bd0` withheld | Event 29362, 2.244 seconds later |
| X02 ground | 59167 | 60 | Phase 22 accepted; phase 24 caller `0x196ed65` withheld; phase 30 report caller `0x196ed90` withheld | Event 60384, 1.962 seconds later |
| X03 final radius/AOE | 166160 | 121 | Phase 22 accepted; phase 24 caller `0x183f7be` withheld; phase 30 report caller `0x183f880` withheld | Event 167638, 2.326 seconds later |

X03 contains four automatic requests. The first three are projectile escapes (damage 75, 75, 31).
The final request is the distinct radius/AOE notification/report pair above, matching the user's
identification of the final escape as the AOE test. The logs establish the native path; they do not
identify the particular enemy or attack independently.

All three bundle manifests match their copied raw-file SHA-256 fingerprints. Text and flight records
contain the same integer event data and event counts (1,137 / 1,229 / 4,720); reconstructed epoch values
differ only by text rounding. No flight records were overwritten or incomplete. Recorded counters show
zero dropped events and zero off-main calls. No death-screen or nonpositive-HP event was recorded.

## Scope and completion caveat

The three targeted sequences establish live wiring: automatic local Nexus request, the corresponding
notification/report cancellation, and a later client-observed Nexus arrival. No additional repetition
of these same three native families is needed for this wiring check.

The generated session reports remain `inconclusive` solely because `status complete` is absent. Their
`automatic_escape_observed` fields are true. The standalone build uses `SESSION_NS=0`; `finish()` is
called only when a nonzero duration expires, and the reviewed guard has no process-exit completion
handler. Quitting the game therefore does not produce the timed-test completion marker. This is a
capture-lifecycle limitation, not a failed escape sequence. Preserve the original reports and raw logs;
do not relabel the whole sessions as complete or weaken the reporter's safety checks.

This evidence does not prove survival against truly lethal damage, server ordering races, bleeding,
suffocation or frostbite. It does confirm the newly added ground and radius/AOE cancellation wiring
alongside the existing projectile wiring. No installed app or game file was replaced during review.

## Preserved local artifacts

Under the existing worktree's ignored `build/damage-diagnostic/data/sessions/` directory:

- `X01-20261016T225239Z-rWyibB/bundle/guard-80936.tsv`, SHA-256 `8b1d073b203fa5e29309e10c7c5884ffe4a690a599a6914a3a4cbb3ccf4a1aec`
- `X02-20261016T225525Z-xDA7d0/bundle/guard-81207.tsv`, SHA-256 `65c10f8f64e6204797211b34eba9e6441f9827b47bd5b2f80641137d7b8375f1`
- `X03-20261016T225803Z-EAPAXf/bundle/guard-81474.tsv`, SHA-256 `e913b8376c7d95ecdbb2a852559471e9641d31c3c2c488e4351d322385871ea1`

Each bundle also preserves its flight recorder, manifest and original generated reports.
