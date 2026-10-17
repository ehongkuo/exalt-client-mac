# Player HP loss: discovery map

The implementation now protects audited projectile, ground and radius/AOE boundaries using a shared
escape policy. Newly added paths have native and fixture evidence; live verification is still pending.
Status and meter damage remain unresolved; saturated meters alone do not trigger escape. See the [minimal verification process](damage-testing.md).

## Evidence levels

- **Candidate:** a mechanic to investigate; no source-specific native path established.
- **Static:** metadata and native instructions match the installed build.
- **Observed:** a labeled in-game session captures the mechanism. None added by this change yet.
- **Intervention verified:** requires a separate protection change, synthetic checks and live evidence.

The map is deliberately open-ended. Server behavior and future dungeon mechanics prevent a claim
that every possible lethal cause has been enumerated. Unattributed HP decreases stay unattributed.

## Inventory and tests

| Mechanism | Current evidence | Recorded path | Test |
|---|---|---|---|
| Enemy projectiles, overlapping hits, armor-piercing variants | Existing audited path; variants sharing this route need no separate test | Calculator `0x650e90`, collision `0x6534f0`, notification caller `0x653bd0` | D01 |
| Grenades, explosions and other radial attacks | Static area/radius-handler candidate; not yet a live-confirmed grenade | Handler `0x183f290`, generic calculation call `0x183f6ed`, notification caller `0x183f7be` | D02 |
| Bleeding (nonlethal alone) and other player damage-over-time effects | Bleeding test not required for lethal-source coverage; other status mechanisms unresolved | Condition-mask words, HP assignments and sampled changes | D03 |
| Lava and damaging ground | Static terrain path; individual tile rules need live confirmation | Terrain routine `0x196eb80`, notification caller `0x196ed65`, report call `0x196ed8b` | D04 |
| Dungeon floor hazards, damaging water, traps or contact hazards | Candidate; some may share terrain, area or projectile code | Record exact hazard and resulting callers; do not assume a shared implementation | D05 |
| Oxygen depletion / suffocation | Breath meter statically mapped; drain/death source unresolved | Player `NMLPJEBCBAE` at `+0x52c`, breath-bar reader `0x1df40a0` | D06 |
| Ice Citadel frostbite | Frostbite meter statically mapped; drain/death source unresolved | Player `DLNIODKGIKA` at `+0x530`, frostbite-bar reader `0x1df5800` | D07 |
| HP/max-HP changes from equipment, buffs, consumables or ability costs | Candidates and reconciliation controls; not inherently damage | HP/max changes, notification and update context | D08/D09 |
| Scripted effects, direct server HP changes or death messages | Shared HP/death paths audited; specific causes unresolved | Stat application `0x184ae90`, HP setter `0x1af1670`, death screen from reviewed profile | D05/D10 |
| Simultaneous or mixed sources | No independent source label can be inferred from timing alone | Per-caller notifications, update boundaries, raw meters | D10 |

Damage amplifiers and defensive effects belong in the test matrix too: armor piercing, defense changes,
exposed/curse-like effects, healing prevention, invulnerability, and ground protection. A condition name
does not establish that it drains HP. Player bleeding behavior must be measured separately from damage
players inflict on enemies. We do not assume bleeding alone is lethal or infer its floor from a wiki.

DECA's [Ice Citadel public-testing introduction](https://remaster.realmofthemadgod.com/?p=4582) describe frostbite damage
at a full meter. Their [bleeding update](https://remaster.realmofthemadgod.com/?p=3164) distinguishes
enemy bleeding changes from player behavior. These are mechanic-discovery references, not proof of the
installed implementation or current numerical damage rates.

## Native findings

`probe/damage_paths.json` stores build-specific method identities, signatures, field facts, caller
encodings and instruction evidence. Its SHA-256 matches `compatibility/profiles/2026-10-15.json`.
`probe/map_damage.py` checks the fingerprint and every recorded byte range. With `--dump`, it also
checks unambiguous metadata identities and field type/storage/offset. It never approves intervention.

| Finding | Native evidence | Meaning and limit |
|---|---|---|
| Projectile calculator | Direct call at `0x65389d`, returns `0x6538a2` | Existing intervention boundary, before player-hit reporting |
| Terrain guard | `0x196ecab` tests `ObjectProperties.protectFromGroundDamage` at `+0x6f4` | Confirms terrain-related logic, not every tile's behavior |
| Terrain calculation and report | `0x196ece3` calls `PGILJGPLGHJ(UInt32, UInt32)`; `0x196ed5f` dispatches notification; `0x196ed8b` calls `OHCGGNLKLGF(Int32, Vector2)` | Separate from the audited projectile calculator; notification value is an observation, not a server acknowledgement |
| Radius handler | `HJMBOMEHGDJ.LFDOGJNGAIG` at `0x183f290` uses a position/radius comparison, calls `KJMONHENJEN.LPEDCDIDDLM` at `0x183f6ed`, and dispatches notification at `0x183f7b8` | Radius/AOE path now guarded before notification effects and its separate report |
| Shared incoming damage notifications | Returns `0x18407cf` and `0x18413af` | Incoming handler branches; source and controlled-player identity require live evidence |
| HP baseline replacement | Call at `0x184c110` from `NAMGODOEDBO` to `NIDPCHCNDLJ` | Incoming stat application; does not identify which pending hits the server processed |
| Breath meter | `CharacterGUIInfoSection.UpdateBreathBar` reads player `+0x52c` at `0x1df40c5` | Raw meter value, not a confirmed damage prediction |
| Frostbite meter | `UpdateFrostbiteBar` reads player `+0x530` at `0x1df5825` | Raw meter value, not a confirmed damage prediction |
| Condition masks | `LKHPPBEGNOM.COHCKAPOLCA`, `Int32[]`, `+0x250` | First two words recorded; individual meanings remain undecoded. Legacy `+0xf8` was a sprite key. |
| Direct HP writes | `0x1af197a` and `0x1af978a` initialize both max HP and HP; base notification can write zero at `0x1af6232` | Alternate state paths, not evidence of a DOT routine |

The initial direct-call search found only one caller of the projectile calculator. That search is not
proof against indirect calls, inlining or shared code. The diagnostic now records other calculator
callers as **unmapped**, without using them for prediction, pairing or intervention.

## Recorder additions

Phase 29 adds context without changing the version-4 binary event layout:

- `projectile`: first two Int32 condition-mask words, packed as unsigned 64-bit.
- `value` / `owner`: raw breath / frostbite values.
- `flag0`: availability bits, 1 flags, 2 breath, 4 frostbite, 8 local Nexusing.
- `flag1`: local Nexusing when available.
- `flag2=1`: corrected condition-array provenance. Older records contain a sprite key, not condition flags.
- `correlation`: HP-assignment or notification entry ID when captured at that boundary; zero for sampling.

Context is sampled at most every 20 ms and published on change, plus at HP-assignment and notification
entry. Optional missing fields are marked unavailable. Main-thread game calls are preserved.
Off-main calls remain counted rather than individually traced. Unobserved changes that occur entirely
between samples remain a coverage limit.

For newly recorded calculator events, `flag1=1` marks explicit provenance and `flag0` says whether
the caller is audited. Older traces remain readable. Unknown callers never enter the shadow budget.
Player/map/connection changes create a new observation generation, including changes first seen inside
a hook rather than the sampling timer. Runtime event ordering and the flight format are regression-tested.

## What follows live observation

Use the checklist in [damage-testing.md](damage-testing.md). For each mechanism we need the sequence
from trigger to calculation/notification, HP updates and escape/death. A local Nexusing flag and an
observed Nexus map are separate facts. Even a successful escape does not establish a prevented lethal hit.

The next protection PR should select only source paths whose player identity, ABI, ordering and
pre-commit boundary are established. For sources observed only through incoming lethal HP updates, lethal-only cancellation requires
a verified earlier damage boundary; a meter-limit escape is not equivalent.

## Expanded protection

Final ground and radius/AOE notification values enter the same `FatalPolicy` as projectile calculations.
Projectile notifications are never charged again. Only a confirmed local Nexus request publishes the
retained player/connection/socket latch. Ground report helpers tail-call `SendMessage`, preserving
return `0x196ed90`; area reports call it at `0x183f87b` and return `0x183f880`. The send hook checks these
exact callers and socket identity, and preserves every other message. Phase 30 records a blocked
non-projectile report on the main thread. Failed requests and disabled protection preserve damage.

The breath setter call at `0x184cb6f` and frostbite setter call at `0x184c7da` belong to the incoming
stat handler. This proves how meter values arrive, not whether their HP loss is locally predictable.
We have not established a universal pre-damage boundary for status/environmental effects.

The [status and reconciliation audit](damage-status-audit.md) records incoming stat IDs, corrected
condition provenance, unresolved DOT boundaries and the conservative pending-damage policy.
