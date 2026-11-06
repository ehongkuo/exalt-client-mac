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
