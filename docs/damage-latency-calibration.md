# Damage-to-HP visibility calibration

The production v8 quiet interval remains a 2–8 second timing assumption. It is not a measured p99.
Its inputs describe received tick cadence, not the complete report-to-server-to-client path.

## Diagnostic

`probe/analyze_latency.py` scans existing raw captures, without modifying the app or game. It uses
local monotonic timestamps from the audited damage calculator return (the boundary at which the
projection would change), the projectile report, and an incoming HP setter return. Thus its endpoint
includes time spent before the report, outbound delivery/queuing, server work and snapshot delivery.
It cannot separate those components or observe server execution times. A later HP decrease is a
visibility candidate, not an explicit acknowledgement.

It requires an explicitly passive capture, disabled gameplay automation, matching recorded game
fingerprint, observation counters without drops/off-main calls and no intervention/synthetic
verification. Exact duplicates and appended copies of the same capture count only once; divergent
copies are rejected. Every selected input is hashed. Captures with no projectile damage remain in
coverage accounting but supply no damage-latency samples.

Candidate evidence classes:

- Locally isolated exact decreases: the HP decrease equals the sole pending observed projectile's
  damage, without an intervening observed HP increase. Other unobserved causes remain a limitation.
- Isolated healing-compatible decreases: a smaller decrease, or an intervening increase, prevents
  exact amount matching.
- Overlapping, unexplained, transition-ended and unmatched reports remain explicitly unresolved.
  Later apparent matches in the same generation are quarantined if old unresolved reports could
  contaminate them. They cannot silently become clean observations.
- Supplementary FIFO illustration: only scopes with equal complete report/decrease counts, compatible
  amounts and causal ordering are aligned one-for-one. This preserves the potentially slow overlapping
  tail for inspection, but is explicitly an assumption and never promoted into an acknowledgement.

A measured p99 of only easy-to-match decreases would be biased if healing or overlap selectively
hides other reports. The diagnostic therefore never automatically certifies p99 or changes the
production window. More samples alone do not repair incorrect event attribution.

## Existing evidence

The first scan covered four passive runs of the currently recorded build; two contained 44 positive
projectile reports. Eighteen duplicate/archive copies were excluded. Nineteen reports remained
unresolved; 25 later candidates were quarantined by the unresolved history. The archives do not
provide a clean p99 calibration set under these filters.

One complete 11-hit sequence supports a supplementary FIFO inference:

| Metric | Inferred damage-to-HP visibility |
|---|---:|
| Minimum | 167.0 ms |
| Median | 300.6 ms |
| Observed p90 | 450.6 ms |
| Maximum | 667.1 ms |

The sample nearest-rank p99 is also 667.1 ms because there are only 11 observations. It is not an
established population p99. The result suggests typical visibility was a few hundred milliseconds
in that run, not several seconds. It does not establish a safe new production cutoff. Full results
and capture hashes: `build/reconciliation-candidate/latency-calibration.json` and `.md`.

## Additional capture, if needed

Use the existing app's clearly labelled observation mode (`build.sh --app-only --sync-capture`),
not a separate launcher or new project. Gameplay automation is off in this mode. Enter Nexus to
initialize, then use a healthy throwaway character and a single weak enemy. Take isolated small hits,
step away until the HP response arrives, and avoid terrain/status damage during the measurement.
Healing can remain natural; samples it obscures are not certified as clean. Manually Nexus before
health becomes dangerous. No deliberate death, manual labels, dungeon checklist or uploads are
needed. A new realm/session after Nexus supplies a new scope if an earlier burst was ambiguous.
The capture already contains the required fields; no additional native hot-path hooks are needed.

Use a short pilot first. For a tail target, 299 independent representative observations give a 95%
chance that the sample maximum reaches the underlying p99. That is not a precise p99 estimate;
same-session correlation, server/region differences and selectively visible HP decreases weaken the
claim. Report per-run distributions and unresolved fractions rather than pooling everything into one
apparently precise number. A proven per-report processing acknowledgement would be stronger evidence
if one is found.

Re-run against new and old captures without relabelling:

```sh
python3 probe/analyze_latency.py --input build/damage-diagnostic/data/sessions \
  --input "$HOME/Library/Application Support/Exalt Client Mac/logs" \
  --json build/reconciliation-candidate/latency-calibration.json \
  --report build/reconciliation-candidate/latency-calibration.md
```

The current report also includes preserved captures elsewhere in `build/`. The installed gameplay
app and timing settings are unchanged by this diagnostic.

## Isolated-hit follow-up, 21 October 2026

The next observation-only capture (`guard-40486.tsv`) contains four positive projectile reports and
951 tick/response pairs, with no recorded drops/off-main calls, no cap and no unresolved reports.
The recorded fingerprint matches the reviewed build. Three isolated HP decreases exactly match the
local damage; the fourth is 1 HP smaller, compatible with recovery.

| Local damage | Incoming HP | Visibility |
|---:|---:|---:|
| 89 | 225 → 136 | 566.691 ms |
| 54 | 225 → 171 | 383.551 ms |
| 89 | 225 → 136 | 400.330 ms |
| 74 | 138 → 65 | 200.527 ms |

All-four median is 391.941 ms. Calculator-return to outgoing SendMessage entry took 3–89 microseconds.
Four samples still do not establish population p99, and these matches remain inferred visibility
rather than keyed acknowledgements. The capture was copied while the process remained open; the
last counter is complete=0. Evidence: `build/reconciliation-candidate/latency-capture-40486/`.
No production timing parameter was changed from these measurements.
