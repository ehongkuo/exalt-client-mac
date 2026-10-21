# Version 7: three beach tests

Use the rebuilt **Exalt Client Mac** app with a disposable character. Enable **Armed** and
**Nexus on death**, Apply, and wait for **Nexus on death ready** in Nexus. Temporarily turn auto-potions
off for B01/B02 so they do not obscure the result. This experimental build can still fail or escape
early. No dungeon, key, pet, recording or terminal command is required.

Use the same weak beach enemies as the previous test. Return to Nexus between tests, wait five
seconds, then re-enter the Realm. Keep the app/game open; the recorder resets for the new map scope.
Confirmed automatic escapes and manual Nexus both save recent history automatically.

| ID | What to do | What we check |
|---|---|---|
| **B01 — recovery** | Take one small hit at healthy HP, retreat for at least three seconds, and recover through natural regeneration or an HP potion if available. Repeat three times, then manually Nexus. | Well-spaced nonlethal hits should not accumulate into a stale-damage escape after healing. |
| **B02 — steady damage** | With auto-potions off, let one weak beach shooter keep hitting the throwaway character until the guard escapes. | A lethal projection should request Nexus and suppress its report; the character should arrive alive. This is the focused lethal test. |
| **B03 — overlap** | Let two weak beach shooters hit together. If you have an HP potion, use one during the hits; otherwise run the burst without it and report that. | Mixed timing across HP updates; healing/burst behavior; successful request, report suppression and alive Nexus arrival. An uncertainty-based early escape is possible and needs log review. |

Stop after any death, stuck escape or apparent full-health false escape; leave the game open long
enough for logs to drain and report it. Do not repeatedly expose more characters after a failure.
If there is no escape and you do not want to continue the lethal test, manually Nexus and report that.

Send: **test ID, enemy, alive/dead result, approximate HP before escape, and whether you healed**.
Example: `B02, beach pirate, alive in Nexus, roughly 25 HP, no healing`.
No need to upload logs unless requested; they are captured locally.

Network stalls, ledger exhaustion, request rejection and injected timing variations are exercised by
offline fixtures. Do not deliberately disconnect Wi-Fi during combat for these tests. Passing these
three tests provides targeted live evidence, not proof against every network condition or damage source.
