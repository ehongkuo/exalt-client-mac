/* Generated from the reviewed compatibility profile. Run compatibility/manage.py generate. */
#ifndef EXALT_BUILD_PROFILE_H
#define EXALT_BUILD_PROFILE_H
#define EXALT_GAME_SHA256 "2ce88d8b7bb4a0683953305be8c7041ca40aa72c8bc2f40128246b91a03e5909"
#define POTION_OFFSET 0x12b85d0UL
#define POTION_OFFSET_NAME "OnQuickslotHotkeyPressedHandler"
#define POTION_OFFSET_OWNER "EquipmentManager"
#define POTION_OFFSET_NAMESPACE "DecaGames.RotMG.Managers.Equipment"
#define NEXUS_OFFSET 0x918be0UL
#define NEXUS_OFFSET_NAME "GGGHNGEJPDE"
#define NEXUS_OFFSET_OWNER "HJMBOMEHGDJ"
#define NEXUS_OFFSET_NAMESPACE ""
#define JOIN_OFFSET 0xcfd7e0UL
#define JOIN_OFFSET_NAME "FDOIPKHKGNF"
#define JOIN_OFFSET_OWNER "IOPKEEBMGJK"
#define JOIN_OFFSET_NAMESPACE ""
#define JOIN_COOLDOWN_OFFSET 0x1e122e0UL
#define JOIN_COOLDOWN_OFFSET_NAME "LMCLHOGGKKG"
#define JOIN_COOLDOWN_OFFSET_OWNER "FKALGHJIADI"
#define JOIN_COOLDOWN_OFFSET_NAMESPACE ""
#define HIT_REPORT_OFFSET 0x929550UL
#define HIT_REPORT_OFFSET_NAME "NDACCDPJHBC"
#define HIT_REPORT_OFFSET_OWNER "HJMBOMEHGDJ"
#define HIT_REPORT_OFFSET_NAMESPACE ""
#define HIT_NOTIFY_OFFSET 0x1e12e40UL
#define HIT_NOTIFY_OFFSET_NAME "FNEBPDEDIJP"
#define HIT_NOTIFY_OFFSET_OWNER "FKALGHJIADI"
#define HIT_NOTIFY_OFFSET_NAMESPACE ""
#define HP_ASSIGN_OFFSET 0x1129cd0UL
#define HP_ASSIGN_OFFSET_NAME "NIDPCHCNDLJ"
#define HP_ASSIGN_OFFSET_OWNER "LKHPPBEGNOM"
#define HP_ASSIGN_OFFSET_NAMESPACE ""
#define DAMAGE_OFFSET 0x17cce10UL
#define DAMAGE_OFFSET_NAME "NGHDFBJLNFI"
#define DAMAGE_OFFSET_OWNER "HBEAKBIHANL"
#define DAMAGE_OFFSET_NAMESPACE ""
#define DEATH_SCREEN_OFFSET 0xe7aba0UL
#define DEATH_SCREEN_OFFSET_NAME "ShowDeathScreenPanel"
#define DEATH_SCREEN_OFFSET_OWNER "GuiManager"
#define DEATH_SCREEN_OFFSET_NAMESPACE "DecaGames.RotMG.Managers.GUI"
#define UPDATE_OFFSET 0x936da0UL
#define UPDATE_OFFSET_NAME "LDKKFMBNOCN"
#define UPDATE_OFFSET_OWNER "HJMBOMEHGDJ"
#define UPDATE_OFFSET_NAMESPACE ""
#define STATS_OFFSET 0x91a6a0UL
#define STATS_OFFSET_NAME "NAMGODOEDBO"
#define STATS_OFFSET_OWNER "HJMBOMEHGDJ"
#define STATS_OFFSET_NAMESPACE ""
#define DAMAGE_CALLER 0x17d12c2UL
#define NOTIFY_CALLER 0x17d14d4UL
#define NOTIFY_CALLER_ALT 0x17d1430UL
#define ZERO_HP_CALLER 0x925e54UL
#ifdef EXALT_PROFILE_HOOK_BYTES
static const unsigned char nexus_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x53,0x48,0x83,0xec,0x48,0x49,0x89,0xfe};
static const unsigned char report_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x54,0x53,0x41,0x89,0xd7};
static const unsigned char notify_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x50};
#ifdef HIT_PROBE_TEST
#define hp_prologue notify_prologue
#else
static const unsigned char hp_prologue[]={0x55,0x48,0x89,0xe5,0x89,0xb7,0x0c,0x02,0x00,0x00,0x48,0x8b,0x07,0x48,0x8b,0x88,0x48,0x08,0x00,0x00};
#endif
static const unsigned char damage_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x53,0x48,0x83,0xec,0x18,0xf3,0x0f,0x11,0x45,0xe0};
#ifdef HIT_PROBE_TEST
#define death_prologue notify_prologue
#else
static const unsigned char death_prologue[]={0x55,0x48,0x89,0xe5,0x48,0x8b,0xbf,0x40,0x01,0x00,0x00,0x48,0x85,0xff};
#endif
static const unsigned char update_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x48,0x83,0xec,0x28};
static const unsigned char stats_prologue[]={0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x48,0x81,0xec,0x98,0x00,0x00,0x00};
#endif
#endif
