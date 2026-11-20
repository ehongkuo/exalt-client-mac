/* Your projectile damage for the drop-rate capture (issues #38, #61). Included by guard.c in the client
 * build when the profile has the loot hooks. The app reads everything else about drops from the game's
 * traffic (app/GuardTraffic.swift); traffic doesn't carry what your own shots did, so this one hook
 * writes it to hits-<started>-<pid>.tsv beside the guard log, where the app joins it to its kills.
 * A failure here turns it off and is logged; it never stops the game.
 *
 *   damage method (base, enemies only): each hit of your projectiles, main and alt weapon
 *
 * The profile still lists the five other hooks #38 used (Damage message, new object, remove object,
 * status apply, NewTick); nothing installs them since #61.
 */
#include "loot_core.h"

static NotifyFunction loot_damage_original;
static NativeHook loot_hook;
/* Mobs' damage method is an override (0x980ac0) that calls the base one we hook from here, so the
 * real caller (your shot) is one frame up. */
#define LOOT_OVERRIDE 0x980ac0UL
#define LOOT_OVERRIDE_CALLER 0x980aecUL

static LootRing loot_ring;
static FILE *loot_hits_file;
static const void *loot_method;
static void *loot_id_field;
static uintptr_t loot_base;
static int loot_prepared, loot_attempted, loot_installed;
static _Atomic uint64_t loot_hit_count, loot_off_main;
static const char *_Atomic loot_refusal;

static void loot_refuse(const char *why) {
    const char *none = NULL;
    if (atomic_compare_exchange_strong(&loot_refusal, &none, why)) note("loot_refused\t%s\n", why);
}

static void loot_prepare(const void *game) {
    void *character = il2cpp_class_from_name(game, ENEMY_DAMAGE_OFFSET_NAMESPACE, ENEMY_DAMAGE_OFFSET_OWNER);
    void *entity = il2cpp_class_from_name(game, "", "KJMONHENJEN");
    if (!character || !entity) { loot_refuse("classes_missing"); return; }
    loot_method = find_method_named(character, ENEMY_DAMAGE_OFFSET_NAME, 7, "System.Boolean");
    if (!at_offset(loot_method, ENEMY_DAMAGE_OFFSET)) { loot_refuse("method_offsets_differ"); return; }
    loot_id_field = typed_field(entity, "HHPOJBFICAH", "System.Int32");
    if (!loot_id_field) { loot_refuse("fields_missing"); return; }
    Dl_info info;
    if (!dladdr((const void *)il2cpp_domain_get, &info) || !info.dli_fbase) { loot_refuse("game_base"); return; }
    loot_base = (uintptr_t)info.dli_fbase;
    loot_prepared = 1;
}

static int loot_live(void) {
    if (pthread_main_np()) return !atomic_load_explicit(&finished, memory_order_relaxed);
    atomic_fetch_add_explicit(&loot_off_main, 1, memory_order_relaxed);
    return 0;
}

static void loot_damage_observed(void *self, uint8_t flag0, int damage, void *effects, uint8_t kill, void *projectile,
                                 uint8_t a, uint8_t b, const void *info) {
    /* Read before forwarding, while the mob is still whole. */
    if (self && loot_live()) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0) - loot_base;
        /* The override keeps a frame pointer (checked at install), so one frame up is its caller. */
        if (caller == LOOT_OVERRIDE_CALLER) caller = (uintptr_t)(*(void *const *const *)__builtin_frame_address(0))[1] - loot_base;
        int source = caller == NOTIFY_CALLER ? LOOT_PROJECTILE : caller == NOTIFY_CALLER_ALT ? LOOT_PROJECTILE_ALT : -1;
        if (source >= 0) {
            LootEvent hit = {.ns = monotonic_ns(), .kind = LOOT_HIT, .source = (uint8_t)source, .v = {damage}};
            il2cpp_field_get_value(self, loot_id_field, &hit.id);
            if (loot_push(&loot_ring, &hit)) atomic_fetch_add_explicit(&loot_hit_count, 1, memory_order_relaxed);
        }
    }
    loot_damage_original(self, flag0, damage, effects, kill, projectile, a, b, info);
}

/* Same rule as the death guard's hooks: install once, in the Nexus, on the main thread. */
static void loot_install(void *player) {
    if (loot_attempted || !loot_prepared || !loot_hits_file || !guard_ok) return;
    if (!in_nexus || !map_ok || map_unknown_logged || !player) return;
#ifdef EXALT_CLIENT_FATAL
    if (config.death && !probe_attempted) return;
#endif
    loot_attempted = 1;
    static const unsigned char via_rax[] = {0xff, 0x90, 0x28, 6, 0, 0}, via_rbx[] = {0xff, 0x93, 0x28, 6, 0, 0};
    if (memcmp((void *)(loot_base + NOTIFY_CALLER - 6), via_rax, 6) || memcmp((void *)(loot_base + NOTIFY_CALLER_ALT - 6), via_rbx, 6)) {
        loot_refuse("caller_bytes"); return;
    }
    static const unsigned char frame[] = {0x55, 0x48, 0x89, 0xe5};   /* push rbp; mov rbp, rsp */
    const unsigned char *base_call = (const unsigned char *)(loot_base + LOOT_OVERRIDE_CALLER - 5);
    int32_t relative;
    memcpy(&relative, base_call + 1, sizeof relative);
    if (memcmp((void *)(loot_base + LOOT_OVERRIDE), frame, sizeof frame) || base_call[0] != 0xe8 ||
        LOOT_OVERRIDE_CALLER + (intptr_t)relative != ENEMY_DAMAGE_OFFSET) { loot_refuse("override_bytes"); return; }
    void *entry = *(void *const *)loot_method;
    if (memcmp(entry, enemydamage_prologue, sizeof enemydamage_prologue)) { loot_refuse("entry_bytes"); return; }
    int result = native_hook_install(&loot_hook, entry, (void *)loot_damage_observed, enemydamage_prologue,
                                     sizeof enemydamage_prologue, (void **)&loot_damage_original);
    if (result != HOOK_OK) {
        static char why[40];   /* static: loot_refusal keeps the pointer */
        snprintf(why, sizeof why, "redirect_error code=%d", result);
        loot_refuse(why); return;
    }
    loot_installed = 1;
    note("loot_ready\thits_only\n");
}

static void loot_tick(void *player) {
    if (ready && loot_prepared) loot_install(player);
}

static void loot_open(const char *folder) {
    char path[PATH_MAX];
    /* The app's traffic capture finds this by the game's pid. */
    int n = snprintf(path, sizeof path, "%s/hits-%.0f-%d.tsv", folder, start_epoch, getpid());
    int fd = n > 0 && (size_t)n < sizeof path ? open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
    loot_hits_file = fd >= 0 ? fdopen(fd, "w") : NULL;
    if (!loot_hits_file) { if (fd >= 0) close(fd); loot_refuse("file"); return; }
    fprintf(loot_hits_file, "hits_session\t%s\t%.3f\t%d\n", EXALT_GAME_SHA256, start_epoch, getpid());
    fflush(loot_hits_file);
}
/* Writer thread. */
static void loot_drain(int closing) {
    if (!loot_hits_file) return;
    static int refusal_written;
    static uint64_t lost_written;
    double epoch = start_epoch + (double)(monotonic_ns() - start_ns) / 1e9;
    const char *why = atomic_load(&loot_refusal);
    if (why && !refusal_written) { refusal_written = 1; fprintf(loot_hits_file, "status\t%.3f\trefused\t%s\n", epoch, why); }
    LootEvent e;
    char line[512];
    while (loot_pop(&loot_ring, &e)) {
        int length = loot_format(&e, start_epoch + (double)(e.ns - start_ns) / 1e9, line, sizeof line);
        if (length > 0) fwrite(line, 1, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1, loot_hits_file);
    }
    uint64_t lost = atomic_load(&loot_ring.lost);
    if (lost != lost_written) { fprintf(loot_hits_file, "gap\t%.3f\t%llu\tring_full\n", epoch, (unsigned long long)(lost - lost_written)); lost_written = lost; }
    if (closing) {
        fprintf(loot_hits_file, "hits_summary\t%.3f\tinstalled=%d\thits=%llu\tlost=%llu\toff_main=%llu\n", epoch, loot_installed,
                (unsigned long long)loot_hit_count, (unsigned long long)lost, (unsigned long long)loot_off_main);
        fclose(loot_hits_file); loot_hits_file = NULL;
    } else fflush(loot_hits_file);
}
