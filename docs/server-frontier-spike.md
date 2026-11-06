# Server frontier spike

Date: 2 November 2026. Analysis of existing captures only; no code or policy change.

Question: does the incoming protocol tell the guard which of its hit reports a server update already
contains (the frontier), or at least bound it more tightly than a local 800 ms timer?

## Data

Only sync captures decode the update fields (phases 40–42): `guard-40486.tsv` (951 updates, 4 hits)
and `guard-31242.tsv` (581 updates, 14 reports). Hits were attributed to HP decreases first-in,
first-out with an exact amount match, for analysis only. 15 attributed hits in total: enough to
show structure, not to set limits.

## Findings

### 1. Update fields

| Field (capture column) | Behavior | Reading |
|---|---|---|
| `server_time` | Rises 195–211 ms per update, median 203 | Server clock, ms |
| `value` | 200–220, median 201 | Server's own update interval, ms |
| `bullet` (the "quality" field) | 0 on the first update, then median 187–203, range 109–1203 | Probably the server's measured round trip for the client, ms |

The last reading is supported, not proven: the field correlates (0.4–0.7) with the measured
download delay of the previous one or two updates, as a round trip timed from the client's replies
would. The client's reply to each update carries only that update's ID and server time.

No field echoes a hit report or any other client message, and no incoming per-hit damage message
was seen for the player. **There is no exact frontier in the decoded data.**

### 2. The server clock can be aligned to the local clock

For each update, local arrival minus server time is the download delay plus a constant clock offset.
Its minimum stayed stable within about 1 ms across each session, so it is a usable reference. The
delay above that minimum: median about 60 ms, 90th percentile about 105 ms.

### 3. Download stalls are real and arrive in bursts

| Capture | Update | Arrived after | Delay above minimum | Then |
|---|---:|---:|---:|---|
| `guard-40486.tsv` | 223 | 1117 ms | 987 ms | Three more updates in the same instant |
| `guard-31242.tsv` | 69 | 650 ms | 532 ms | Two more updates in the same instant |
| `guard-31242.tsv` | 191 | 450 ms | 313 ms | One more in the same instant |

9 of about 1,500 updates arrived more than 300 ms late. Each tells the client what the server knew
up to a second earlier. A rule that ages hits on the local clock would treat a hit as contained by
an update built before the server could have received it: the per-hit-by-age Phase 1 as written
retires hits wrongly in exactly these stalls. The server's timestamp exposes them.

### 4. Inclusion against the server clock

Server-clock age = the update's server time, mapped to the local clock, minus the time the hit was
reported. For each attributed hit, the update before the one that first contained it, and that one:

| | Local arrival age | Server-clock age |
|---|---|---|
| Not yet contained (update before) | up to 267 ms | up to 186 ms |
| First contained | from 167 ms | from 149 ms |

On the server clock the overlap is about 40 ms; on the local clock about 100 ms, and it grows with
every download stall. A hit was always contained by the first or second update after it could have
reached the server, which suggests the server applies reported hits on its update boundary.

Correcting for upload delay with the round-trip field (round trip minus measured download delay)
did not separate the cases better on this sample: it still predicted containment up to 81 ms too
early. Inconclusive at 15 samples.

## Implications for the plan

1. Age hits on the server clock, not the local one. This removes download jitter and stalls, the
   largest source of error found, and makes a tick that arrives late harmless.
2. Bound the frontier per update instead of using one window. On the server clock: hits younger than
   a lower bound are certainly pending, hits older than an upper bound are assumed contained, and
   hits between are ambiguous and counted as pending. On this sample the bounds are about 150 and
   190 ms plus a safety margin; the band is much narrower than 800 ms.
3. Upload delay is the remaining unknown. A stalled upload delays when the server receives a hit
   while updates keep arriving normally, so the upper bound must cover upload delay and the server's
   update boundary. Candidate signals: the round-trip field (it lags by one or two updates) and the
   gap between the client's replies and the server's next update.
4. Measure before choosing bounds: dense combat and a laggy session in sync capture, to observe
   upload spikes and the ambiguous band at real decision points.

## Reproducing

The analysis used throwaway scripts, not committed. They read `server_time`, `value` and `bullet`
from phase 40, report times from phase 42, local damage from phase 12 and incoming HP from phase 6.
The clock reference is the minimum of arrival minus server time per capture generation. A
`probe/analyze_frontier.py` should replace them before new captures are judged.
