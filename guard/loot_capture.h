/* Drop-rate capture hooks (issue #38). Included by guard.c in the client build when the profile has
 * the loot hooks. Records every kill of a mob you damaged and every bag as it arrives, into
 * loot-<started>-<pid>.tsv beside the guard log. A failure here turns capture off and is logged;
 * it never stops the game.
 *
 *   A  damage method (base, enemies only): your hits and kill flags
 *   B  new object: bags and their contents, and each object's type
 *   C  Damage message: who the server says shot (abilities)
 *   D  remove object, from the server's Update: a mob you hit is gone. The kill flag alone misses
 *      most kills: the game sets it only when one shot outdoes the HP the server last sent, and it
 *      never lowers a mob's HP itself (staging run 1: 0 kill flags over 32 kills RealmHound saw).
 *   E  status apply (every object's stats, on arrival and each tick): your own stats when they
 *      change, for the loot factors among them
 * Once per map it also writes the map's info message raw (seed, strings such as modifiers).
 */
#include "loot_core.h"

typedef void (*LootMessageFunction)(void *, void *, void **, const void *);
typedef void (*LootObjectFunction)(void *, void *, const void *);
typedef void (*LootRemoveFunction)(void *, int32_t, const void *);
typedef void (*LootStatusFunction)(void *, void *, int32_t, int32_t, uint8_t, const void *);
static NotifyFunction loot_damage_original;
static LootMessageFunction loot_message_original;
static LootObjectFunction loot_object_original;
static LootRemoveFunction loot_remove_original;
static LootStatusFunction loot_status_original;
enum { LOOT_HOOK_COUNT = 5 };
static NativeHook loot_hooks[LOOT_HOOK_COUNT];
/* Return addresses (checked at install): the Damage handler's call into the damage method, and the
 * Update handler's call into remove-object for each dropped id. Other callers remove projectiles. */
#define LOOT_DAMAGE_CALLER 0x92658fUL
#define LOOT_DROP_CALLER 0x936072UL

static LootRing loot_ring;
static LootHits loot_hits;
static LootType loot_types[LOOT_TYPES];
static FILE *loot_file;
static const void *loot_methods[LOOT_HOOK_COUNT];
static void *loot_id_field, *loot_shooter_field, *loot_type_field, *loot_status_field, *loot_status_id_field,
            *loot_pos_field, *loot_stats_field, *loot_x_field, *loot_y_field,
            *loot_stat_type_field, *loot_stat_int_field, *loot_stat_text_field, *loot_own_field;
/* Raw, until a staging run shows what they hold: two connection ints (character id?), and the map
 * info message's ints and strings (seed, difficulty, dungeon modifiers?). */
static void *loot_connection_ints[2], *loot_info_ints[5], *loot_info_texts[2], *loot_info_list;
static ListFields loot_stat_list;
static uintptr_t loot_base;
static int loot_prepared, loot_attempted, loot_installed;
static int32_t loot_self_id, loot_shooter;   /* your object id, from the connection */
static void *loot_connection;
static uint32_t loot_map, loot_named_map = UINT32_MAX;
static _Atomic uint64_t loot_kills, loot_bags, loot_off_main;
static const char *_Atomic loot_refusal;

static void loot_refuse(const char *why) {
    const char *none = NULL;
    if (atomic_compare_exchange_strong(&loot_refusal, &none, why)) note("loot_refused\t%s\n", why);
}

static void loot_prepare(const void *game) {
    void *character = il2cpp_class_from_name(game, ENEMY_DAMAGE_OFFSET_NAMESPACE, ENEMY_DAMAGE_OFFSET_OWNER);
    void *handler = il2cpp_class_from_name(game, DAMAGE_MESSAGE_OFFSET_NAMESPACE, DAMAGE_MESSAGE_OFFSET_OWNER);
    void *receiver = il2cpp_class_from_name(game, NEW_OBJECT_OFFSET_NAMESPACE, NEW_OBJECT_OFFSET_OWNER);
    void *entity = il2cpp_class_from_name(game, "", "KJMONHENJEN"), *message = il2cpp_class_from_name(game, "", "MMDLNDNCGMA");
    void *data = il2cpp_class_from_name(game, "", "KBGIJJLLFFD"), *status = il2cpp_class_from_name(game, "", "BOEANEODCOA");
    void *pos = il2cpp_class_from_name(game, "", "FFLIAABAAFP"), *stat = il2cpp_class_from_name(game, "", "CGOECEPGBBG");
    if (!character || !handler || !receiver || !entity || !message || !data || !status || !pos || !stat) {
        loot_refuse("classes_missing"); return;
    }
    loot_methods[0] = find_method_named(character, ENEMY_DAMAGE_OFFSET_NAME, 7, "System.Boolean");
    loot_methods[1] = find_method_named(handler, DAMAGE_MESSAGE_OFFSET_NAME, 2, "MMDLNDNCGMA");
    loot_methods[2] = find_method_named(receiver, NEW_OBJECT_OFFSET_NAME, 1, "KBGIJJLLFFD");
    loot_methods[3] = find_method_named(il2cpp_class_from_name(game, REMOVE_OBJECT_OFFSET_NAMESPACE, REMOVE_OBJECT_OFFSET_OWNER),
                                        REMOVE_OBJECT_OFFSET_NAME, 1, "System.Int32");
    loot_methods[4] = find_method_named(il2cpp_class_from_name(game, STATUS_APPLY_OFFSET_NAMESPACE, STATUS_APPLY_OFFSET_OWNER),
                                        STATUS_APPLY_OFFSET_NAME, 4, "BOEANEODCOA");
    if (!at_offset(loot_methods[0], ENEMY_DAMAGE_OFFSET) || !at_offset(loot_methods[1], DAMAGE_MESSAGE_OFFSET) ||
        !at_offset(loot_methods[2], NEW_OBJECT_OFFSET) || !at_offset(loot_methods[3], REMOVE_OBJECT_OFFSET) ||
        !at_offset(loot_methods[4], STATUS_APPLY_OFFSET)) {
        loot_refuse("method_offsets_differ"); return;
    }
    loot_id_field = typed_field(entity, "HHPOJBFICAH", "System.Int32");
    loot_shooter_field = typed_field(message, "HHPOJBFICAH", "System.Int32");
    loot_type_field = typed_field(data, "JHIKGCPGEDB", "System.UInt16");
    loot_status_field = typed_field(data, "ANBOELDHAIK", "BOEANEODCOA");
    loot_status_id_field = typed_field(status, "HHPOJBFICAH", "System.Int32");
    loot_pos_field = typed_field(status, "BMKMLEPFEJK", "FFLIAABAAFP");
    loot_stats_field = typed_field(status, "PLAMMIIHNHB", "System.Collections.Generic.List<CGOECEPGBBG>");
    loot_x_field = typed_field(pos, "<CHOGDNLDCMD>k__BackingField", "System.Single");
    loot_y_field = typed_field(pos, "<HDJDHDGIBON>k__BackingField", "System.Single");
    loot_stat_type_field = typed_field(stat, "MPOLBNPCMKP", "System.Byte");
    loot_stat_int_field = typed_field(stat, "GNAMBLMALLL", "System.Int32");
    loot_stat_text_field = typed_field(stat, "HKLKENHBFLH", "System.String");
    loot_own_field = typed_field(receiver, "CMAEBFGEKFC", "System.Int32");
    loot_connection_ints[0] = typed_field(receiver, "CBIKBMMKKGC", "System.Int32");
    loot_connection_ints[1] = typed_field(receiver, "HOHDMDGBEBK", "System.Int32");
    void *map_info = il2cpp_class_from_name(game, "", "NCAFKHMPKJC");
    static const char *const info_ints[] = {"FIJHPAMHMKN", "FLMJIMDEFOP", "IGHPIBHBBOE", "NBODPGADKHF", "BJLGEEKOKLM"};
    int info_ok = map_info != NULL;
    for (int i = 0; info_ok && i < 5; ++i) info_ok = (loot_info_ints[i] = typed_field(map_info, info_ints[i], "System.Int32")) != NULL;
    if (info_ok) {
        loot_info_texts[0] = typed_field(map_info, "PMEKDGIJFDF", "System.String");
        loot_info_texts[1] = typed_field(map_info, "NDFKPKPKPCP", "System.String");
        loot_info_list = typed_field(map_info, "DGGDBIMMDHE", "System.String[]");
    }
    if (!(loot_id_field && loot_shooter_field && loot_type_field && loot_status_field && loot_status_id_field &&
          loot_pos_field && loot_stats_field && loot_x_field && loot_y_field && loot_stat_type_field &&
          loot_stat_int_field && loot_stat_text_field && loot_own_field && loot_connection_ints[0] && loot_connection_ints[1] &&
          info_ok && loot_info_texts[0] && loot_info_texts[1] && loot_info_list && max_field && position_field)) {
        loot_refuse("fields_missing"); return;
    }
    Dl_info info;
    if (!dladdr((const void *)il2cpp_domain_get, &info) || !info.dli_fbase) { loot_refuse("game_base"); return; }
    loot_base = (uintptr_t)info.dli_fbase;
    loot_prepared = 1;
}

/* Your stats as last written, so only changes are written (and all of them again on each map). */
static int32_t loot_player_values[256];
static uint8_t loot_player_known[256];
/* Ids restart with each map, so damage is forgotten when the server gives you a new object id. */
static void loot_new_map(void) {
    ++loot_map;
    loot_hits_clear(&loot_hits);
    memset(loot_player_known, 0, sizeof loot_player_known);
}

static void loot_kill(const LootHit *h, int source, uint64_t now) {
    LootEvent e = {.ns = now, .id = h->id, .map = loot_map, .type = loot_type_get(loot_types, h->id), .kind = LOOT_KILL,
                   .source = (uint8_t)source, .pos = {h->pos[0], h->pos[1], h->pos[2]},
                   .v = {h->damage[0], h->damage[1], h->damage[2], h->max, (int32_t)((now - h->last_ns) / 1000000)}};
    if (loot_push(&loot_ring, &e)) atomic_fetch_add_explicit(&loot_kills, 1, memory_order_relaxed);
}
static void loot_hit(void *self, int damage, int kill, uintptr_t caller) {
    int source = loot_source(caller, NOTIFY_CALLER, NOTIFY_CALLER_ALT, LOOT_DAMAGE_CALLER, loot_shooter, loot_self_id);
    if (source >= LOOT_YOURS && !kill) return;   /* the common case: someone else's hit */
    int32_t id = 0;
    il2cpp_field_get_value(self, loot_id_field, &id);
    uint64_t now = monotonic_ns();
    LootHit *h = loot_hit_add(&loot_hits, id, source, damage, now);
    if (kill) h = loot_hit_kill(&loot_hits, id);
    if (!h) return;
    /* Where it was when you last hit it: removal comes later, when only its id is known. */
    if (!h->max) il2cpp_field_get_value(self, max_field, &h->max);
    il2cpp_field_get_value(self, position_field, h->pos);
    if (kill) loot_kill(h, source, now);
}
static int loot_live(void) {
    if (pthread_main_np()) return !atomic_load_explicit(&finished, memory_order_relaxed);
    atomic_fetch_add_explicit(&loot_off_main, 1, memory_order_relaxed);
    return 0;
}
/* Diagnostics while kills are unproven live (the first staging run captured none): hook A calls by
 * return address, noted every 60 s, and the first plain and kill-flagged calls in full. */
typedef struct { uint32_t caller, calls, kills; } LootCaller;
static LootCaller loot_callers[8];
static int loot_traced[2];
static uint64_t loot_next_callers;
static void loot_trace(void *self, uintptr_t caller, int damage, int kill) {
    for (int i = 0; i < 8; ++i) {
        LootCaller *c = &loot_callers[i];
        if (c->calls && c->caller != caller) continue;
        c->caller = (uint32_t)caller; ++c->calls; c->kills += kill != 0;
        break;
    }
    if (loot_traced[kill != 0] >= 8) return;
    ++loot_traced[kill != 0];
    int32_t id = 0;
    il2cpp_field_get_value(self, loot_id_field, &id);
    note("loot_trace\tcaller=0x%lx\tkill=%d\tid=%d\tdamage=%d\ttype=%u\ttracked=%d\tself=%d\tshooter=%d\tmap=%u\n",
         (unsigned long)caller, kill, id, damage, loot_type_get(loot_types, id),
         id && loot_hits.slot[(uint32_t)id % LOOT_HITS].id == id, loot_self_id, loot_shooter, loot_map);
}
static void loot_note_callers(void) {
    uint64_t now = monotonic_ns();
    if (now < loot_next_callers) return;
    loot_next_callers = now + 60 * NSEC_PER_SEC;
    char text[512] = "";
    for (int i = 0, n = 0; i < 8 && loot_callers[i].calls; ++i)
        n += snprintf(text + n, sizeof text - (size_t)n, "\t0x%x=%u/%u", loot_callers[i].caller, loot_callers[i].calls, loot_callers[i].kills);
    note("loot_callers%s\n", text);
}

static void loot_damage_observed(void *self, uint8_t flag0, int damage, void *effects, uint8_t kill, void *projectile,
                                 uint8_t a, uint8_t b, const void *info) {
    /* Read before forwarding, while the mob is still whole. */
    if (self && loot_live()) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0) - loot_base;
        loot_trace(self, caller, damage, kill);
        loot_hit(self, damage, kill, caller);
    }
    loot_damage_original(self, flag0, damage, effects, kill, projectile, a, b, info);
}
static void loot_message_observed(void *self, void *message, void **target, const void *info) {
    if (loot_live()) { loot_shooter = 0; if (message) il2cpp_field_get_value(message, loot_shooter_field, &loot_shooter); }
    loot_message_original(self, message, target, info);
}

/* Reads the message, not the game object: a bag's first status (its contents) is in it. */
static void loot_object(void *connection, void *data) {
    /* A new map starts when the server gives you a new id, which it does before it sends the map's
     * objects; so bags already on the ground when you arrive belong to the new map. (Run 1 moved
     * the boundary only once your new player object existed, after that first batch.) */
    int32_t own = 0;
    il2cpp_field_get_value(connection, loot_own_field, &own);
    if (connection != loot_connection || own != loot_self_id) { loot_connection = connection; loot_self_id = own; loot_new_map(); }
    uint16_t type = 0;
    il2cpp_field_get_value(data, loot_type_field, &type);
    void *status = read_reference(data, loot_status_field);
    if (!status) return;
    int32_t id = 0;
    il2cpp_field_get_value(status, loot_status_id_field, &id);
    loot_type_set(loot_types, id, type);
    if (!loot_is_bag(type)) return;
    uint64_t now = monotonic_ns();
    LootEvent bag = {.ns = now, .id = id, .map = loot_map, .type = type, .kind = LOOT_BAG, .v = {-1, -1, -1, -1, -1, -1, -1, -1}};
    void *pos = read_reference(status, loot_pos_field);
    if (pos) { il2cpp_field_get_value(pos, loot_x_field, &bag.pos[0]); il2cpp_field_get_value(pos, loot_y_field, &bag.pos[1]); }
    LootEvent extra[16];
    int extras = 0;
    void *const *stats = NULL;
    int32_t n = list_items(read_reference(status, loot_stats_field), "CGOECEPGBBG[]", &loot_stat_list, &stats);
    for (int32_t i = 0; i < n; ++i) {
        if (!stats[i]) continue;
        uint8_t stat = 0; int32_t value = 0;
        il2cpp_field_get_value(stats[i], loot_stat_type_field, &stat);
        il2cpp_field_get_value(stats[i], loot_stat_int_field, &value);
        int slot = loot_item_slot(stat);
        if (slot >= 0) { bag.v[slot] = value; continue; }
        if (extras == 16) continue;
        LootEvent *e = &extra[extras++];
        *e = (LootEvent){.ns = now, .id = id, .map = loot_map, .type = type, .kind = LOOT_BAG_STAT, .v = {stat, value}};
        read_text(read_reference(stats[i], loot_stat_text_field), e->text, sizeof e->text);
    }
    if (loot_push(&loot_ring, &bag)) atomic_fetch_add_explicit(&loot_bags, 1, memory_order_relaxed);
    for (int i = 0; i < extras; ++i) loot_push(&loot_ring, &extra[i]);
}
static void loot_object_observed(void *self, void *data, const void *info) {
    if (data && loot_live()) loot_object(self, data);
    loot_object_original(self, data, info);
}
static void loot_player_status(void *connection, void *status) {
    int32_t id = 0, own = 0;
    il2cpp_field_get_value(status, loot_status_id_field, &id);
    il2cpp_field_get_value(connection, loot_own_field, &own);
    if (!id || id != own) return;
    void *const *stats = NULL;
    int32_t n = list_items(read_reference(status, loot_stats_field), "CGOECEPGBBG[]", &loot_stat_list, &stats);
    uint64_t now = monotonic_ns();
    for (int32_t i = 0; i < n; ++i) {
        if (!stats[i]) continue;
        uint8_t stat = 0; int32_t value = 0;
        il2cpp_field_get_value(stats[i], loot_stat_type_field, &stat);
        void *text = read_reference(stats[i], loot_stat_text_field);
        if (!loot_player_stat_kept(stat) || (text && il2cpp_string_length(text) > 0)) continue;
        il2cpp_field_get_value(stats[i], loot_stat_int_field, &value);
        if (loot_player_known[stat] && loot_player_values[stat] == value) continue;
        loot_player_known[stat] = 1; loot_player_values[stat] = value;
        LootEvent e = {.ns = now, .id = id, .map = loot_map, .kind = LOOT_PLAYER_STAT, .v = {stat, value}};
        loot_push(&loot_ring, &e);
    }
}
static void loot_status_observed(void *self, void *status, int32_t time, int32_t tick, uint8_t first, const void *info) {
    if (status && loot_live()) loot_player_status(self, status);
    loot_status_original(self, status, time, tick, first, info);
}
static void loot_remove_observed(void *self, int32_t id, const void *info) {
    if ((uintptr_t)__builtin_return_address(0) - loot_base == LOOT_DROP_CALLER && loot_live()) {
        LootHit *h = loot_hit_kill(&loot_hits, id);
        if (h) loot_kill(h, LOOT_REMOVED, monotonic_ns());
    }
    loot_remove_original(self, id, info);
}

/* Same rule as the death guard's hooks: install once, in the Nexus, on the main thread. */
static void loot_install(void *player) {
    if (loot_attempted || !loot_prepared || !loot_file || !guard_ok) return;
    if (!in_nexus || !map_ok || map_unknown_logged || !player) return;
    loot_attempted = 1;
    static const unsigned char via_rax[] = {0xff, 0x90, 0x28, 6, 0, 0}, via_rbx[] = {0xff, 0x93, 0x28, 6, 0, 0};
    if (memcmp((void *)(loot_base + NOTIFY_CALLER - 6), via_rax, 6) || memcmp((void *)(loot_base + NOTIFY_CALLER_ALT - 6), via_rbx, 6) ||
        memcmp((void *)(loot_base + LOOT_DAMAGE_CALLER - 6), via_rbx, 6)) { loot_refuse("caller_bytes"); return; }
    const unsigned char *drop_call = (const unsigned char *)(loot_base + LOOT_DROP_CALLER - 5);   /* call rel32 */
    int32_t relative;
    memcpy(&relative, drop_call + 1, sizeof relative);
    if (drop_call[0] != 0xe8 || LOOT_DROP_CALLER + (intptr_t)relative != REMOVE_OBJECT_OFFSET) { loot_refuse("caller_bytes"); return; }
    const unsigned char *bytes[] = {enemydamage_prologue, damagemessage_prologue, newobject_prologue, removeobject_prologue,
                                    statusapply_prologue};
    size_t lengths[] = {sizeof enemydamage_prologue, sizeof damagemessage_prologue, sizeof newobject_prologue,
                        sizeof removeobject_prologue, sizeof statusapply_prologue};
    void *replacements[] = {(void *)loot_damage_observed, (void *)loot_message_observed, (void *)loot_object_observed,
                            (void *)loot_remove_observed, (void *)loot_status_observed};
    void **originals[] = {(void **)&loot_damage_original, (void **)&loot_message_original, (void **)&loot_object_original,
                          (void **)&loot_remove_original, (void **)&loot_status_original};
    void *entries[LOOT_HOOK_COUNT];
    for (int i = 0; i < LOOT_HOOK_COUNT; ++i) {
        entries[i] = *(void *const *)loot_methods[i];
        if (memcmp(entries[i], bytes[i], lengths[i])) { loot_refuse("entry_bytes"); return; }
    }
    for (int i = 0; i < LOOT_HOOK_COUNT; ++i) {
        int result = native_hook_install(&loot_hooks[i], entries[i], replacements[i], bytes[i], lengths[i], originals[i]);
        if (result != HOOK_OK) {
            for (int j = i - 1; j >= 0; --j) if (native_hook_remove(&loot_hooks[j]) != HOOK_OK) __builtin_trap();
            loot_refuse("redirect_error"); return;
        }
    }
    loot_installed = 1;
    note("loot_ready\tformat=%d\n", LOOT_FORMAT);
}

static void loot_tick(void *player) {
    if (!ready || !loot_prepared) return;
    loot_install(player);
    if (!loot_installed || !player) return;
    loot_note_callers();
    /* Name each map once, when your player object with the new id exists. The server sent the map's
     * info before your id, so by then the name is this map's, never the previous one's. */
    int32_t id = 0;
    il2cpp_field_get_value(player, loot_id_field, &id);
    if (loot_map == loot_named_map || !last_map_info || !id || id != loot_self_id) return;
    loot_named_map = loot_map;
    uint64_t now = monotonic_ns();
    LootEvent e = {.ns = now, .map = loot_map, .kind = LOOT_MAP};
    snprintf(e.text, sizeof e.text, "%s", live_data.map);
    loot_push(&loot_ring, &e);
    LootEvent info = {.ns = now, .map = loot_map, .kind = LOOT_MAP_INFO, .v = {loot_type_get(loot_types, id)}};
    for (int i = 0; i < 5; ++i) il2cpp_field_get_value(last_map_info, loot_info_ints[i], &info.v[1 + i]);
    il2cpp_field_get_value(loot_connection, loot_connection_ints[0], &info.v[6]);
    il2cpp_field_get_value(loot_connection, loot_connection_ints[1], &info.v[7]);
    char a[80], b[80], list[90] = "";
    read_text(read_reference(last_map_info, loot_info_texts[0]), a, sizeof a);
    read_text(read_reference(last_map_info, loot_info_texts[1]), b, sizeof b);
    void *array = read_reference(last_map_info, loot_info_list);
    size_t used = 0;
    for (uint32_t i = 0, count = array ? il2cpp_array_length(array) : 0; i < count && used + 2 < sizeof list; ++i) {
        char item[sizeof list];
        read_text(((void *const *)((char *)array + 0x20))[i], item, sizeof item);
        int w = snprintf(list + used, sizeof list - used, "%s%s", i ? ";" : "", item);
        if (w < 0) break;
        used += (size_t)w < sizeof list - used ? (size_t)w : sizeof list - used - 1;
    }
    snprintf(info.text, sizeof info.text, "%s\t%s\t%s", a, b, list);
    loot_push(&loot_ring, &info);
}

static void loot_open(const char *folder) {
    char path[PATH_MAX];
    int n = snprintf(path, sizeof path, "%s/loot-%.0f-%d.tsv", folder, start_epoch, getpid());
    int fd = n > 0 && (size_t)n < sizeof path ? open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
    loot_file = fd >= 0 ? fdopen(fd, "w") : NULL;
    if (!loot_file) { if (fd >= 0) close(fd); loot_refuse("file"); return; }
    fprintf(loot_file, "loot_session\t%d\t%s\t%.3f\t%d\n", LOOT_FORMAT, EXALT_GAME_SHA256, start_epoch, getpid());
    fflush(loot_file);
}
/* Writer thread. */
static void loot_drain(int closing) {
    if (!loot_file) return;
    static int refusal_written;
    static uint64_t lost_written, next_summary;
    uint64_t now = monotonic_ns();
    double epoch = start_epoch + (double)(now - start_ns) / 1e9;
    const char *why = atomic_load(&loot_refusal);
    if (why && !refusal_written) { refusal_written = 1; fprintf(loot_file, "status\t%.3f\trefused\t%s\n", epoch, why); }
    LootEvent e;
    char line[512];
    while (loot_pop(&loot_ring, &e)) {
        int length = loot_format(&e, start_epoch + (double)(e.ns - start_ns) / 1e9, line, sizeof line);
        if (length > 0) fwrite(line, 1, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1, loot_file);
    }
    uint64_t lost = atomic_load(&loot_ring.lost);
    if (lost != lost_written) { fprintf(loot_file, "gap\t%.3f\t%llu\tring_full\n", epoch, (unsigned long long)(lost - lost_written)); lost_written = lost; }
    if (closing || now >= next_summary) {
        next_summary = now + 60 * NSEC_PER_SEC;
        fprintf(loot_file, "loot_summary\t%.3f\tinstalled=%d\tkills=%llu\tbags=%llu\tlost=%llu\toff_main=%llu\tevictions=%llu\n",
                epoch, loot_installed, (unsigned long long)loot_kills, (unsigned long long)loot_bags,
                (unsigned long long)lost, (unsigned long long)loot_off_main, (unsigned long long)loot_hits.evictions);
    }
    if (closing) { fprintf(loot_file, "status\t%.3f\tcomplete\n", epoch); fclose(loot_file); loot_file = NULL; }
    else fflush(loot_file);
}
