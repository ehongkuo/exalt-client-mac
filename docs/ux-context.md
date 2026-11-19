# UX context: Exalt Client Mac, Drop rates tab

Set with /intent:intent (context mode). Every Intent skill run on this project should start from this.

## Users
- Today: one player (the author). Goal: useful to any player curious about drop rates, so design for
  someone without the author's context.
- Players know the game's terms (bags, tiers, UTs, shinies). They don't know stats terms (95% range,
  Poisson); say those in plain words.
- Questions, most asked first: where should I farm this item; can I trust this number; my odds of any
  item in a tier group; what does this dungeon give.

## How it's used
- Mostly a reference you look things up in, like a wiki: search, item page, dungeon page.
- Collects live data while the game runs, so numbers change while you look.

## Uncertainty
- Important now (639 kills, 984 bags), but temporary: the goal is less uncertainty as data grows.
- Each rate shows its precision as ±X% (about 1.96 ÷ √drops), or "too few drops" under 4 drops. No
  labels, thresholds or goal: the number tightens as data grows. Rates looser than ±50% are faded.

## Product and constraints
- SwiftUI macOS app, dark theme, tabs Guard and Drop rates. Redesign in issue #45.
- Data from captured game packets: Realm and event dungeons have no drop tags; shinies matched by name;
  the game's rarity and shiny marks ship in `data/icons` (copied from RealmHound's repo; drawn gems are the fallback),
  and each dungeon's item collection icon (beside its name in the header; the list keeps portal sprites) is cut
  from RealmHound's `CollectionIcon.png`.
- Changes go issue → staged build → merge; nothing installed from a PR branch. Public repo: no account
  or player names.

## Ethical stance
- Honest numbers: never look more certain than the data.
- No engagement hooks; the tab answers a question, it doesn't hold attention.
- Data stays on the machine.

## Success
- "Where should I farm X?" answered in two clicks or fewer.
- A firm rate and a loose one are told apart at a glance (the ±X% and the fading).
- A new player with an empty database sees what the tab will do, not a broken screen.
- No state looks broken: empty dungeon, never-dropped item, capture off, missing sprites.
