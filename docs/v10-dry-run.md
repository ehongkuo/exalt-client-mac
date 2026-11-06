# Policy v10: Dry Run session

Checks policy v10 (the ordering proof, [Nexus on death](nexus-on-death.md)) against live game
traffic before it is armed. Dry Run never Nexuses or blocks damage; it only logs what it would do.
The installed **Exalt Client Mac** app already contains v10.

## Setup

1. Use a disposable character. In Dry Run nothing saves it.
2. In Settings, turn **Nexus on death** on and **Armed** off (the panel reads "Dry run: only shows
   what it would do"). Turn auto-potions off. Click **Apply**.
3. Launch the game through the app and wait in Nexus for **Nexus on death: dry run**. If it shows
   "unavailable" or never appears, stop and report it: the guard may have refused to start.

## Session (about 10 minutes)

1. **Steady chip damage.** On the beach, let weak enemies wear your HP down to about a quarter,
   then Nexus manually.
2. **Bursts.** Take a few multi-hit bursts from something stronger, including at least one that
   would have killed you if you'd stayed. Nexus manually before dying if you can; a death is fine.
3. **Heals while hit** (optional). With a pet or ally healing you, take hits for a minute.
4. Wait five seconds with the game open, then report **done**, plus anything odd you noticed
   (lag spikes, the app's Nexus-on-death events appearing at high HP).

## What we check afterwards

From the newest `guard-*.tsv` in `~/Library/Application Support/Exalt Client Mac/logs`:

- `fatal_policy\tversion=10` is logged, and there's no `hit_probe_refused`.
- **Hits clear:** `guard_proof_clear` records keep up with the hits, and pending damage returns to
  0 between fights. Hits that stay pending would mean replies aren't being matched.
- **Dry requests** (`guard_death_nexus` with the dry result): each should come with HP that was
  really in danger. Note how many came at moderate HP, the expected early escapes when a hit
  lands within two updates of the previous one.
- **Deaths:** any death without an earlier dry request is a missed escape and blocks arming.

Arm v10 only after a session with no missed escapes and no stuck pending hits.

**Done 7 November** (`guard-10176`): passed. Results are in the
[report](per-hit-settlement-report.md), step 5.

## Armed session (the last check before release)

Dry Run showed v10 predicts the fatal burst. This session checks the part no session has shown yet:
that the escape actually lands. It also covers heals while hit. If it passes, v10 is ready to
release.

### Setup

1. Use a disposable character. If the escape fails, it dies.
2. In Settings, set **Potion trigger** and **Ceiling** to Off, so a potion can't save you and hide
   the result. Turn **Armed** on (the panel reads "Armed: drinks and Nexuses for you") and keep
   **Nexus on death** checked. Click **Apply**.
3. Launch the game through the app and wait in Nexus for **Nexus on death ready** (green). If it
   says "unavailable", stop and report it.

### Session (about 10 minutes)

1. **Heals while hit.** With a pet or ally healing you, take ordinary hits for a minute without
   dropping low. Nothing should happen: no Nexus.
2. **The burst.** Find the multi-hit enemy that killed you last time, or anything that can take you
   from about half HP to dead in one volley. Stand in it and don't Nexus yourself.
3. **Expected:** you're sent to Nexus with HP left, and the app's Nexus count goes to 1. The game's
   HP bar may show a big drop right before; that's the hits already in flight.
4. Wait five seconds in Nexus, then report **done**: whether you escaped or died, and roughly what
   HP you had in Nexus.

**Done 7 November** (`guard-11113`): escaped. Results are in the report, step 5.

Stop after the first escape; one is enough. If you die instead, stop and report it. That blocks
release.

### What we check afterwards

From the newest `guard-*.tsv`:

- **The escape:** `guard_death_nexus` with `result=1` (called), followed by a Nexus map change, with
  no death record after it.
- **The burst:** what was pending and projected at the request, compared with your HP in Nexus.
- **Heals:** no request during the heal phase, and pending back to 0 after it.
