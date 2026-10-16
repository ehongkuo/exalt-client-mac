# Compatibility comparison

Baseline: `exalt-macos-intel-2026-10-12`
Observed GameAssembly: `ad0698246ccd226ff4dd1245961c003f3be99d12dda1bb438c9d1be9b4a4b51f`

**Read-only findings. This report does not establish behavioral compatibility or approve a build for runtime use.**

Unchanged means the listed identity and entry/offset checks matched. It does not mean the whole method is unchanged.
New-build candidates require a native-code audit and live readiness checks. No profile or installed app was modified.

## Methods

| Item | Finding | Previous | Observed |
|---|---|---|---|
| potion | moved | `0x52cc60` | `0x1fe30f0` |
| nexus | moved | `0x7264f0` | `0x1841500` |
| join | moved | `0xa3d060` | `0x13e7dc0` |
| join_cooldown | moved | `0x11f7e00` | `0x1962b60` |
| report | moved | `0x712c10` | `0x1853fb0` |
| notify | moved | `0x11f6a60` | `0x1970a90` |
| hp | changed | `0x177ca50` | `0x1af1670` |
| damage | moved | `0x2051720` | `0x650e90` |
| death | moved | `0x6d8f70` | `0x1f92870` |
| update | moved | `0x71a120` | `0x18496e0` |
| stats | moved | `0x71e940` | `0x184ae90` |
| collision | moved | `0x2056cd0` | `0x6534f0` |
| zero_hp_context | moved | `0x70d600` | `0x1840c60` |

## Fields

| Item | Finding | Previous | Observed |
|---|---|---|---|
| QuickSlot.GCKDOJPIMLD | unchanged | `0x1cc` | `0x1cc` |
| QuickSlot.JFBFHHAJOAK | unchanged | `0x1dc` | `0x1dc` |
| NCAFKHMPKJC.MJGBECCHGIP | unchanged | `0x18` | `0x18` |
| NCAFKHMPKJC.FHLCMICEGNM | unchanged | `0x20` | `0x20` |
| KJMONHENJEN.DGNPJNFGFPE | unchanged | `0x68` | `0x68` |
| KJMONHENJEN.EFAGNJBDCOM | unchanged | `0x90` | `0x90` |
| EquipmentManager.FirstQuickslotIndex | unchanged | `0x20` | `0x20` |
| EquipmentManager.quickSlots | unchanged | `0x60` | `0x60` |
| CPHENFGHHNA.DPGEBOCBKEF | unchanged | `0x10` | `0x10` |
| CPHENFGHHNA.HOAKHDPFALM | unchanged | `0x18` | `0x18` |
| CPHENFGHHNA.JPDFALDPJCK | unchanged | `0x28` | `0x28` |
| GuiManager.hpProgressBar | unchanged | `0x68` | `0x68` |
| GuiManager.JLFBFCOFDOF | unchanged | `0x200` | `0x200` |
| HJMBOMEHGDJ.PNIHHODGAEE | unchanged | `0x40` | `0x40` |
| HJMBOMEHGDJ.FIAJOKGHGGK | unchanged | `0xe8` | `0xe8` |
| HJMBOMEHGDJ.NIDFCHODLIH | unchanged | `0x160` | `0x160` |
| ProgressBar.BBFODHPMFCC | unchanged | `0x50` | `0x50` |
| ProgressBar.OJAHBHNIGDI | unchanged | `0x54` | `0x54` |
| ChatSlotController.HPGHGFMACLH | unchanged | `0x28` | `0x28` |
| SocketManager.FCOJPHFICAG | unchanged | `0x40` | `0x40` |
| FKALGHJIADI.EAKILNOKDDC | unchanged | `0x660` | `0x660` |
| ChatManager.CPEAFDEENOD | unchanged | `0xc0` | `0xc0` |
| RealmQuestsManager.PNOBIMOELCK | unchanged | `0x80` | `0x80` |
| LKHPPBEGNOM.DPGEBOCBKEF | unchanged | `0x178` | `0x178` |
| LKHPPBEGNOM.OADOHPKBPJB | unchanged | `0x208` | `0x208` |
| LKHPPBEGNOM.ABCPKBGJPEP | unchanged | `0x20c` | `0x20c` |
| Object.m_CachedPtr | unchanged | `0x10` | `0x10` |

## Call sites

| Item | Finding | Previous | Observed |
|---|---|---|---|
| damage_calculation | moved | `0x2057082` | `0x6538a2` |
| projectile_notification | moved | `0x20573b0` | `0x653bd0` |
| zero_hp_assignment | moved | `0x70d804` | `0x1840e64` |

🤖 Generated with Codex
