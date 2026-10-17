/* ExaltGuard.dylib: loaded into the game by Exalt Client Mac. Reads HP, quickslots, the map and
 * party chat through the IL2CPP runtime, and calls the same game functions as the potion and
 * Nexus keys and the ctrl-click menu's "Join dungeon". Optional predicted-death protection
 * redirects audited projectile functions. Default is dry run. */
/* The diagnostic build forces legacy actions off; the client build keeps their settings. */
#include "guard_core.h"
#include "timing_core.h"
#include "live_state.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
#define EXALT_PROFILE_HOOK_BYTES
#endif
#include "build_profile.h"

enum { RESULT_DRY = 0, RESULT_CALLED = 1, RESULT_EXCEPTION = -1, RESULT_UNAVAILABLE = -2, RESULT_EMPTY = -3 };
#define MAX_QUICKSLOTS 8

#define API(ret, name, args) static ret (*name) args
API(void *, il2cpp_domain_get, (void));
API(const void **, il2cpp_domain_get_assemblies, (const void *, size_t *));
API(const void *, il2cpp_assembly_get_image, (const void *));
API(const char *, il2cpp_image_get_name, (const void *));
API(void *, il2cpp_class_from_name, (const void *, const char *, const char *));
API(const void *, il2cpp_class_get_type, (void *));
API(void *, il2cpp_type_get_object, (const void *));
API(const void *, il2cpp_class_get_methods, (void *, void **));
API(const char *, il2cpp_method_get_name, (const void *));
API(uint32_t, il2cpp_method_get_param_count, (const void *));
API(const void *, il2cpp_method_get_param, (const void *, uint32_t));
API(void *, il2cpp_runtime_invoke, (const void *, void *, void **, void **));
API(void *, il2cpp_object_get_class, (void *));
API(const char *, il2cpp_class_get_name, (void *));
API(void *, il2cpp_class_get_parent, (void *));
API(void *, il2cpp_class_get_field_from_name, (void *, const char *));
API(const void *, il2cpp_field_get_type, (void *));
API(int, il2cpp_field_get_flags, (void *));
API(char *, il2cpp_type_get_name, (const void *));
API(void, il2cpp_field_get_value, (void *, void *, void *));
API(void, il2cpp_field_static_get_value, (void *, void *));
API(void, il2cpp_free, (void *));
API(uint32_t, il2cpp_array_length, (void *));
API(void, il2cpp_runtime_class_init, (void *));
API(void, il2cpp_format_exception, (const void *, char *, int));
API(int32_t, il2cpp_string_length, (void *));
API(uint16_t *, il2cpp_string_chars, (void *));
API(void *, il2cpp_gchandle_new, (void *, uint8_t));
API(void *, il2cpp_gchandle_get_target, (void *));
API(void, il2cpp_gchandle_free, (void *));
API(void *, il2cpp_string_new, (const char *));

#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
static void hit_probe_drain(void);
#endif
static FILE *logfile;
static void *gui_handle, *player_handle, *equipment_handle;
static void *bar_field, *player_field, *hp_field, *position_field, *native_field;
static void *max_field, *player_hp_field, *connection_field, *bar_aux_field, *quickslots_field, *stack_field;
static void *gui_class, *bar_class, *player_class, *equipment_class, *connection_class, *quickslot_class, *library;
static const void *find_method, *potion_method, *nexus_method;
static int guard_ok, base_logged;
static int potion_off;  /* set after a game exception in that action only */
/* Current map, from the map-info message the game keeps on RealmQuestsManager. */
static void *realm_quests_class, *realm_quests_handle, *map_info_field, *map_name_field, *map_display_field;
static void *last_map_info, *last_map_name;
static int map_ok, in_nexus, map_unknown_logged;
static uint64_t next_map_lookup, next_equipment_lookup;
/* Party chat calls. ChatManager keeps the chat window's slots (ChatSlotController), each showing
 * one message model (CPHENFGHHNA). The game reuses message objects for new messages, so a
 * message is new when an object's sender, channel or text changes. Only the sender of a party
 * call is logged; message text never goes to the log. */
#define CHAT_SEEN 256
static void *chat_class, *chat_handle, *chat_slots_field, *chat_slot_class, *chat_slot_model_field;
static void *chat_message_class, *chat_sender_field, *chat_channel_field, *chat_text_field, *own_name_field;
static void *chat_list_class, *chat_items_field, *chat_size_field;
static void *chat_object;   /* compared only, never read: it may have been collected */
static int chat_primed;
static struct { void *object; uint64_t hash; } chat_seen[CHAT_SEEN];
static unsigned chat_seen_next;
static uint64_t next_chat_lookup, next_chat_poll;
static char own_name[64];
/* Join: runs what the menu's "Join dungeon" button runs, when the user clicks Join in the app.
 * A request waits up to JOIN_WAIT_NS for a player object (for example during a map load). */
#define JOIN_WAIT_NS (2 * NSEC_PER_SEC)
static void *party_manager_field;
static const void *join_method, *join_cooldown_method;
static int join_ok, join_off;
static uint32_t last_join_seq, last_join_request, pending_join;
static char pending_join_name[32];
static uint64_t pending_join_deadline;
static void *cooldown_field;          /* QuickSlot.GCKDOJPIMLD: the game's quickslot cooldown flag */
static uintptr_t validated_player;    /* player whose HP field has matched the HUD at least once */
/* Live state for Exalt Client Mac (see live_state.h). */
static LiveState *live;
static LiveData live_data;
static uint64_t gap_window_start;
static uint32_t gap_window_max;
static uint32_t last_control_seq, last_control_request;
static int logged_stacks[MAX_QUICKSLOTS], logged_cooling[MAX_QUICKSLOTS], logged_slot_count = -1;
static void *quickslot_base_field;
static GuardConfig config;
static GuardState guard;
static dispatch_source_t timer, writer;
static SampleRing ring;
static Detector detector;
static uint64_t sequence, start_ns, previous_ns, next_lookup, drops;
static double start_epoch;
static Record last_logged;
static uint64_t last_logged_ns;
static _Atomic int finished;
static int ready;
/* 0 = run until the game exits. Tests set a short session. */
#ifndef SESSION_NS
#define SESSION_NS 0ULL
#endif
#define HEARTBEAT_NS NSEC_PER_SEC
/* Check every 1 ms: HP lands on whatever frame the server update arrives, so a short period
 * cuts the wait between the game applying HP and the guard seeing it. About 3 us per check. */
#ifndef PERIOD_NS
#define PERIOD_NS 1000000ULL
#endif

/* One-off status lines from the game thread, printed by the writer. */
#define NOTE_CAPACITY 32
static char notes[NOTE_CAPACITY][1024];
static _Atomic uint64_t note_head, note_tail;
__attribute__((format(printf, 1, 2))) static void note(const char *format, ...) {
    uint64_t head = atomic_load_explicit(&note_head, memory_order_relaxed);
    if (head - atomic_load_explicit(&note_tail, memory_order_acquire) == NOTE_CAPACITY) return;
    va_list args;
    va_start(args, format);
    vsnprintf(notes[head % NOTE_CAPACITY], sizeof notes[0], format, args);
    va_end(args);
    atomic_store_explicit(&note_head, head + 1, memory_order_release);
}

static uint64_t monotonic_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * NSEC_PER_SEC + (uint64_t)t.tv_nsec;
}
static LatencyStats latency;
static uint64_t next_latency_note;
static void latency_note(void) {
    /* Fixed-size existing note queue; the background writer performs file I/O. */
    note("guard_latency\tchecks=%llu\tvalid=%llu\tgaps_ge20ms=%llu\tgaps_ge100ms=%llu"
         "\tvalid_gaps_ge100ms=%llu\tmax_gap_us=%llu\tmax_valid_gap_us=%llu\tmax_work_us=%llu"
         "\tstage_samples=%llu\tlookup_us=%llu\tguard_us=%llu\tservices_us=%llu\tpublication_us=%llu\n",
         (unsigned long long)latency.checks, (unsigned long long)latency.valid_checks,
         (unsigned long long)latency.gaps_20ms, (unsigned long long)latency.gaps_100ms,
         (unsigned long long)latency.valid_gaps_100ms, (unsigned long long)(latency.max_gap_ns / 1000),
         (unsigned long long)(latency.max_valid_gap_ns / 1000), (unsigned long long)(latency.max_work_ns / 1000),
         (unsigned long long)latency.stage_samples, (unsigned long long)(latency.lookup_ns / 1000),
         (unsigned long long)(latency.guard_ns / 1000), (unsigned long long)(latency.services_ns / 1000),
         (unsigned long long)(latency.publication_ns / 1000));
}
static const char *safe(const char *s) { return s ? s : ""; }

static int bind_api(void) {
    if (!library) {
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char *path = _dyld_get_image_name(i), *leaf = strrchr(path, '/');
            if (leaf && !strcmp(leaf + 1, "GameAssembly.dylib")) {
                library = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
                break;
            }
        }
    }
    void *source = library ? library : RTLD_DEFAULT;
#define BIND(name) do { *(void **)(&name) = dlsym(source, #name); if (!name) return 0; } while (0)
    BIND(il2cpp_gchandle_new); BIND(il2cpp_gchandle_get_target); BIND(il2cpp_gchandle_free);
    BIND(il2cpp_domain_get); BIND(il2cpp_domain_get_assemblies);
    BIND(il2cpp_assembly_get_image); BIND(il2cpp_image_get_name);
    BIND(il2cpp_class_from_name); BIND(il2cpp_class_get_type);
    BIND(il2cpp_type_get_object); BIND(il2cpp_class_get_methods);
    BIND(il2cpp_method_get_name); BIND(il2cpp_method_get_param_count);
    BIND(il2cpp_method_get_param); BIND(il2cpp_runtime_invoke);
    BIND(il2cpp_object_get_class); BIND(il2cpp_class_get_name);
    BIND(il2cpp_class_get_parent); BIND(il2cpp_class_get_field_from_name);
    BIND(il2cpp_field_get_type); BIND(il2cpp_field_get_flags);
    BIND(il2cpp_type_get_name); BIND(il2cpp_field_get_value);
    BIND(il2cpp_field_static_get_value); BIND(il2cpp_free); BIND(il2cpp_array_length);
    BIND(il2cpp_runtime_class_init); BIND(il2cpp_format_exception);
    BIND(il2cpp_string_length); BIND(il2cpp_string_chars); BIND(il2cpp_string_new);
    return 1;
}

static int type_is(void *field, const char *expected) {
    char *type = il2cpp_type_get_name(il2cpp_field_get_type(field));
    int match = type && !strcmp(type, expected);
    if (type) il2cpp_free(type);
    return match;
}
static void *typed_field(void *klass, const char *name, const char *expected) {
    void *field = il2cpp_class_get_field_from_name(klass, name);
    if (!field || (il2cpp_field_get_flags(field) & 16)) return NULL;
    return type_is(field, expected) ? field : NULL;
}
static const void *find_method_named(void *klass, const char *name, uint32_t params, const char *param_type) {
    void *iterator = NULL;
    const void *method;
    while ((method = il2cpp_class_get_methods(klass, &iterator))) {
        if (strcmp(safe(il2cpp_method_get_name(method)), name) ||
            il2cpp_method_get_param_count(method) != params) continue;
        if (!param_type) return method;
        char *type = il2cpp_type_get_name(il2cpp_method_get_param(method, 0));
        int match = type && !strcmp(type, param_type);
        if (type) il2cpp_free(type);
        if (match) return method;
    }
    return NULL;
}
static void *ancestor_named(void *klass, const char *name) {
    for (int depth = 0; klass && depth < 6; ++depth, klass = il2cpp_class_get_parent(klass))
        if (!strcmp(safe(il2cpp_class_get_name(klass)), name)) return klass;
    return NULL;
}
/* MethodInfo begins with the compiled method pointer. */
static int at_offset(const void *method, uintptr_t offset) {
    Dl_info info;
    if (!method || !dladdr((const void *)il2cpp_domain_get, &info) || !info.dli_fbase) return 0;
    return (uintptr_t)*(void *const *)method - (uintptr_t)info.dli_fbase == offset;
}

static void prepare_guard(const void *game) {
    equipment_class = il2cpp_class_from_name(game, POTION_OFFSET_NAMESPACE, POTION_OFFSET_OWNER);
    connection_class = il2cpp_class_from_name(game, NEXUS_OFFSET_NAMESPACE, NEXUS_OFFSET_OWNER);
    quickslot_class = il2cpp_class_from_name(game, "DecaGames.RotMG.Managers.Equipment", "QuickSlot");
    if (!equipment_class || !connection_class || !quickslot_class) { note("guard_refused\tclasses_missing\n"); return; }
    potion_method = find_method_named(equipment_class, POTION_OFFSET_NAME, 1, "System.Int32");
    nexus_method = find_method_named(connection_class, NEXUS_OFFSET_NAME, 0, NULL);
    if (!at_offset(potion_method, POTION_OFFSET) || !at_offset(nexus_method, NEXUS_OFFSET)) {
        note("guard_refused\tmethod_offsets_differ\n"); return;
    }
    /* Static readonly, set by the game's static constructor; read it only when drinking. */
    quickslot_base_field = il2cpp_class_get_field_from_name(equipment_class, "FirstQuickslotIndex");
    if (!quickslot_base_field || !(il2cpp_field_get_flags(quickslot_base_field) & 16) ||
        !type_is(quickslot_base_field, "System.Int32")) {
        note("guard_refused\tquickslot_field_missing\n"); return;
    }
    quickslots_field = typed_field(equipment_class, "quickSlots", "DecaGames.RotMG.Managers.Equipment.QuickSlot[]");
    stack_field = typed_field(quickslot_class, "JFBFHHAJOAK", "System.Int32");  /* stack count; 0 = empty */
    cooldown_field = typed_field(quickslot_class, "GCKDOJPIMLD", "System.Boolean");
    guard_ok = max_field && player_hp_field && connection_field && quickslots_field && stack_field && cooldown_field;
    realm_quests_class = il2cpp_class_from_name(game, "DecaGames.RotMG.UI.Managers", "RealmQuestsManager");
    void *map_info_class = il2cpp_class_from_name(game, "", "NCAFKHMPKJC");
    if (realm_quests_class && map_info_class) {
        map_info_field = typed_field(realm_quests_class, "PNOBIMOELCK", "NCAFKHMPKJC");
        map_name_field = typed_field(map_info_class, "MJGBECCHGIP", "System.String");
        map_display_field = typed_field(map_info_class, "FHLCMICEGNM", "System.String");
    }
    map_ok = map_info_field && map_name_field && map_display_field;
    chat_class = il2cpp_class_from_name(game, "DecaGames.RotMG.UI.Managers", "ChatManager");
    chat_slot_class = il2cpp_class_from_name(game, "DecaGames.RotMG.Chat.UI", "ChatSlotController");
    chat_message_class = il2cpp_class_from_name(game, "", "CPHENFGHHNA");
    if (chat_class && chat_slot_class && chat_message_class) {
        chat_slots_field = typed_field(chat_class, "CPEAFDEENOD", "System.Collections.Generic.List<DecaGames.RotMG.Chat.UI.ChatSlotController>");
        chat_slot_model_field = typed_field(chat_slot_class, "HPGHGFMACLH", "CPHENFGHHNA");
        chat_sender_field = typed_field(chat_message_class, "DPGEBOCBKEF", "System.String");   /* "Name,a19d" */
        chat_channel_field = typed_field(chat_message_class, "JPDFALDPJCK", "System.String");  /* "*Party*", "*Guild*" or empty */
        chat_text_field = typed_field(chat_message_class, "HOAKHDPFALM", "System.String");
    }
    if (!(chat_slots_field && chat_slot_model_field && chat_sender_field && chat_channel_field && chat_text_field)) {
        chat_slots_field = NULL;
        live_data.chat_status = CHAT_UNAVAILABLE;
        note("guard_chat_unavailable\n");
    }
    void *party_class = il2cpp_class_from_name(game, JOIN_OFFSET_NAMESPACE, JOIN_OFFSET_OWNER);
    if (party_class) join_method = find_method_named(party_class, JOIN_OFFSET_NAME, 1, "System.String");
    join_cooldown_method = find_method_named(player_class, JOIN_COOLDOWN_OFFSET_NAME, 1, "System.Int32");
    party_manager_field = typed_field(player_class, "EAKILNOKDDC", "IOPKEEBMGJK");
    join_ok = party_manager_field && at_offset(join_method, JOIN_OFFSET) && at_offset(join_cooldown_method, JOIN_COOLDOWN_OFFSET);
    if (!join_ok) note("guard_join_unavailable\n");
    if (guard_ok) note("guard_ready\n");
    else note("guard_refused\tplayer_fields_missing\n");
}

static int prepare(void) {
    if (!bind_api()) return 0;
    void *domain = il2cpp_domain_get();
    if (!domain) return 0;
    size_t n = 0;
    const void **assemblies = il2cpp_domain_get_assemblies(domain, &n);
    if (!assemblies || n > 4096) return 0;
    const void *game = NULL, *unity = NULL;
    for (size_t i = 0; i < n; ++i) {
        const void *image = il2cpp_assembly_get_image(assemblies[i]);
        if (!image) continue;
        const char *name = safe(il2cpp_image_get_name(image));
        if (!strcmp(name, "Assembly-CSharp.dll")) game = image;
        if (!strcmp(name, "UnityEngine.CoreModule.dll")) unity = image;
    }
    if (!game || !unity) return 0;
    gui_class = il2cpp_class_from_name(game, DEATH_SCREEN_OFFSET_NAMESPACE, DEATH_SCREEN_OFFSET_OWNER);
    bar_class = il2cpp_class_from_name(game, "DecaGames.RotMG.UI.Helpers", "ProgressBar");
    player_class = il2cpp_class_from_name(game, HIT_NOTIFY_OFFSET_NAMESPACE, HIT_NOTIFY_OFFSET_OWNER);
    void *object = il2cpp_class_from_name(unity, "UnityEngine", "Object");
    if (!gui_class || !bar_class || !player_class || !object) return 0;
    find_method = find_method_named(object, "FindObjectOfType", 1, "System.Type");
    if (!find_method) return 0;
    bar_field = typed_field(gui_class, "hpProgressBar", "DecaGames.RotMG.UI.Helpers.ProgressBar");
    player_field = typed_field(gui_class, "JLFBFCOFDOF", "FKALGHJIADI");
    hp_field = typed_field(bar_class, "OJAHBHNIGDI", "System.Single");
    bar_aux_field = typed_field(bar_class, "BBFODHPMFCC", "System.Single");
    native_field = typed_field(object, "m_CachedPtr", "System.IntPtr");
    void *entity = ancestor_named(player_class, "KJMONHENJEN");
    void *character = ancestor_named(player_class, "LKHPPBEGNOM");
    if (entity) {
        position_field = typed_field(entity, "DGNPJNFGFPE", "Unity.Mathematics.float3");
        connection_field = typed_field(entity, "EFAGNJBDCOM", "HJMBOMEHGDJ");
    }
    if (character) {
        max_field = typed_field(character, "OADOHPKBPJB", "System.Int32");
        player_hp_field = typed_field(character, "ABCPKBGJPEP", "System.Int32");
        own_name_field = typed_field(character, "DPGEBOCBKEF", "System.String");  /* same name as the chat sender field */
    }
    if (!(bar_field && player_field && hp_field && native_field && position_field)) return 0;
    prepare_guard(game);
    return 1;
}

static void release(void **handle) {
    if (*handle) il2cpp_gchandle_free(*handle);
    *handle = NULL;
}
static int native_alive(void *object) {
    void *pointer = NULL;
    il2cpp_field_get_value(object, native_field, &pointer);
    return pointer != NULL;
}
static void *read_reference(void *object, void *field) {
    void *value = NULL; il2cpp_field_get_value(object, field, &value); return value;
}
static void *find_object(void *klass) {
    void *reflection = il2cpp_type_get_object(il2cpp_class_get_type(klass));
    void *args[] = {reflection}, *exception = NULL;
    void *found = reflection ? il2cpp_runtime_invoke(find_method, NULL, args, &exception) : NULL;
    return exception ? NULL : found;
}

/* Copies a managed string as ASCII (other characters become '?'), for logging and comparison. */
static void read_text(void *string, char *out, size_t size) {
    out[0] = 0;
    if (!string || size < 2) return;
    int32_t length = il2cpp_string_length(string);
    const uint16_t *chars = il2cpp_string_chars(string);
    size_t n = 0;
    for (int32_t i = 0; chars && i < length && n + 1 < size; ++i)
        out[n++] = chars[i] < 0x80 && chars[i] >= 0x20 && chars[i] != '\t' ? (char)chars[i] : '?';
    out[n] = 0;
}
static void map_unknown(const char *why) {
    in_nexus = 0;
    if (!map_unknown_logged) { map_unknown_logged = 1; note("guard_map_unknown\t%s\n", why); }
}
/* Updates in_nexus. If the map can't be read, assumes it is not the Nexus (the guard keeps
 * protecting) and logs that once. */
static void update_map(uint64_t now) {
    if (!map_ok) { map_unknown("fields_missing"); return; }
    void *quests = realm_quests_handle ? il2cpp_gchandle_get_target(realm_quests_handle) : NULL;
    if (!quests || il2cpp_object_get_class(quests) != realm_quests_class || !native_alive(quests)) {
        release(&realm_quests_handle);
        if (now < next_map_lookup) { in_nexus = 0; return; }
        next_map_lookup = now + 500 * NSEC_PER_MSEC;
        quests = find_object(realm_quests_class);
        if (!quests || il2cpp_object_get_class(quests) != realm_quests_class || !native_alive(quests)) {
            map_unknown("manager_missing"); return;
        }
        realm_quests_handle = il2cpp_gchandle_new(quests, 0);
    }
    void *info = read_reference(quests, map_info_field);
    void *name = info ? read_reference(info, map_name_field) : NULL;
    if (!info || !name) { map_unknown("no_map_info"); return; }
    if (info == last_map_info && name == last_map_name) return;
    last_map_info = info; last_map_name = name;
    char text[64], display[64];
    read_text(name, text, sizeof text);
    read_text(read_reference(info, map_display_field), display, sizeof display);
    in_nexus = !strcasecmp(text, "Nexus") || !strcasecmp(display, "Nexus") || !strcasecmp(display, "{s.nexus}");
    snprintf(live_data.map, sizeof live_data.map, "%s", text);
    note("guard_map\t%s\t%s\t%s\n", text, display, in_nexus ? "nexus" : "not_nexus");
}
static uint64_t fnv1a(const char *text) {
    uint64_t hash = 1469598103934665603ULL;
    for (; *text; ++text) hash = (hash ^ (uint8_t)*text) * 1099511628211ULL;
    return hash;
}
/* Copies a managed string as UTF-8, dropping control characters and never splitting a character. */
static void read_utf8(void *string, char *out, size_t size) {
    out[0] = 0;
    if (!string || size < 2) return;
    int32_t length = il2cpp_string_length(string);
    const uint16_t *chars = il2cpp_string_chars(string);
    size_t n = 0;
    for (int32_t i = 0; chars && i < length; ++i) {
        uint32_t c = chars[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < length && chars[i + 1] >= 0xDC00 && chars[i + 1] < 0xE000)
            c = 0x10000 + ((c - 0xD800) << 10) + (uint32_t)(chars[++i] - 0xDC00);
        else if (c >= 0xD800 && c < 0xE000) c = 0xFFFD;
        if (c < 0x20 || c == 0x7F) continue;
        unsigned char b[4];
        size_t k;
        if (c < 0x80) { b[0] = (unsigned char)c; k = 1; }
        else if (c < 0x800) { b[0] = (unsigned char)(0xC0 | c >> 6); b[1] = (unsigned char)(0x80 | (c & 63)); k = 2; }
        else if (c < 0x10000) {
            b[0] = (unsigned char)(0xE0 | c >> 12); b[1] = (unsigned char)(0x80 | (c >> 6 & 63));
            b[2] = (unsigned char)(0x80 | (c & 63)); k = 3;
        } else {
            b[0] = (unsigned char)(0xF0 | c >> 18); b[1] = (unsigned char)(0x80 | (c >> 12 & 63));
            b[2] = (unsigned char)(0x80 | (c >> 6 & 63)); b[3] = (unsigned char)(0x80 | (c & 63)); k = 4;
        }
        if (n + k + 1 > size) break;
        memcpy(out + n, b, k);
        n += k;
    }
    out[n] = 0;
}
/* Returns 1 when `object` is new or its contents changed since last seen, and remembers them. */
static int chat_changed(void *object, uint64_t hash) {
    for (unsigned i = 0; i < CHAT_SEEN; ++i) {
        if (chat_seen[i].object != object) continue;
        if (chat_seen[i].hash == hash) return 0;
        chat_seen[i].hash = hash;
        return 1;
    }
    chat_seen[chat_seen_next++ % CHAT_SEEN] = (typeof(chat_seen[0])){object, hash};
    return 1;
}
/* Reads the chat slot list's backing array; returns the element count (0 if unreadable). */
static int32_t chat_slot_items(void *list, void *const **items) {
    if (!list) return 0;
    void *klass = il2cpp_object_get_class(list);
    if (klass != chat_list_class) {
        chat_list_class = klass;
        chat_items_field = typed_field(klass, "_items", "DecaGames.RotMG.Chat.UI.ChatSlotController[]");
        chat_size_field = typed_field(klass, "_size", "System.Int32");
    }
    if (!chat_items_field || !chat_size_field) return 0;
    void *array = read_reference(list, chat_items_field);
    int32_t size = 0;
    il2cpp_field_get_value(list, chat_size_field, &size);
    if (!array || size <= 0) return 0;
    if ((uint32_t)size > il2cpp_array_length(array)) size = (int32_t)il2cpp_array_length(array);
    *items = (void *const *)((char *)array + 0x20);
    return size;
}
/* A message is a party call when it is new, in party chat, from someone else, and matches
 * chat_is_call. During priming, messages already in the chat are remembered, not reported. */
static void chat_check(void *message, int priming, double epoch) {
    if (!message || il2cpp_object_get_class(message) != chat_message_class) return;
    char sender[64], channel[16], text[sizeof live_data.party_text], key[200];
    read_utf8(read_reference(message, chat_sender_field), sender, sizeof sender);
    read_utf8(read_reference(message, chat_channel_field), channel, sizeof channel);
    read_utf8(read_reference(message, chat_text_field), text, sizeof text);
    if (!sender[0] && !text[0]) return;   /* an unused pooled object */
    snprintf(key, sizeof key, "%s\t%s\t%s", sender, channel, text);
    if (!chat_changed(message, fnv1a(key)) || priming) return;
    if (strcmp(channel, "*Party*") || !chat_is_call(text) || chat_same_name(sender, own_name)) return;
    ++live_data.party_calls;
    live_data.party_call_epoch = epoch;
    int name_length = (int)strcspn(sender, ",");
    if (name_length >= (int)sizeof live_data.party_caller) name_length = (int)sizeof live_data.party_caller - 1;
    snprintf(live_data.party_caller, sizeof live_data.party_caller, "%.*s", name_length, sender);
    memcpy(live_data.party_text, text, sizeof text);
    note("guard_party_call\t%s\n", live_data.party_caller);
}
/* Every 100 ms: reads the chat window's messages. `player` (may be NULL) gives the name of the
 * user's own character, whose messages never count as calls. */
static void poll_chat(uint64_t now, double epoch, void *player) {
    if (!chat_slots_field || now < next_chat_poll) return;
    next_chat_poll = now + 100 * NSEC_PER_MSEC;
    if (player && own_name_field) read_utf8(read_reference(player, own_name_field), own_name, sizeof own_name);
    void *chat = chat_handle ? il2cpp_gchandle_get_target(chat_handle) : NULL;
    if (!chat || il2cpp_object_get_class(chat) != chat_class || !native_alive(chat)) {
        release(&chat_handle);
        live_data.chat_status = CHAT_SEARCHING;
        if (now < next_chat_lookup) return;
        next_chat_lookup = now + 500 * NSEC_PER_MSEC;
        chat = find_object(chat_class);
        if (!chat || il2cpp_object_get_class(chat) != chat_class || !native_alive(chat)) return;
        chat_handle = il2cpp_gchandle_new(chat, 0);
        /* A different chat window: what it already shows is history. The same one found again
         * (after a brief loss) keeps its record, so calls that arrived meanwhile still count. */
        if (chat != chat_object) { chat_object = chat; chat_primed = 0; }
        if (live_data.chat_status != CHAT_READING) note("guard_chat_ready\n");
        live_data.chat_status = CHAT_READING;
    }
    void *const *slots = NULL;
    int32_t count = chat_slot_items(read_reference(chat, chat_slots_field), &slots);
    int priming = !chat_primed;
    chat_primed = 1;
    for (int32_t i = 0; i < count; ++i) {
        if (!slots[i] || il2cpp_object_get_class(slots[i]) != chat_slot_class) continue;
        chat_check(read_reference(slots[i], chat_slot_model_field), priming, epoch);
    }
}
static void disarm(const char *what, const void *exception) {
    char message[128] = "";
    il2cpp_format_exception(exception, message, sizeof message);
    for (char *c = message; *c; ++c) if (*c == '\t' || *c == '\n') *c = ' ';
    note("guard_exception\t%s\t%s\n", what, message);
    /* Switch off only the action that failed, so a potion error never disables the Nexus. */
    if (!strcmp(what, "potion")) potion_off = 1;
    else if (!strcmp(what, "join")) join_off = 1;
    note("guard_disarmed\t%s_exception\n", what);
}
static void *equipment_instance(uint64_t now) {
    void *equipment = equipment_handle ? il2cpp_gchandle_get_target(equipment_handle) : NULL;
    if (equipment && il2cpp_object_get_class(equipment) == equipment_class && native_alive(equipment))
        return equipment;
    release(&equipment_handle);
    if (now < next_equipment_lookup) return NULL;
    next_equipment_lookup = now + 500 * NSEC_PER_MSEC;
    equipment = find_object(equipment_class);
    if (!equipment || il2cpp_object_get_class(equipment) != equipment_class || !native_alive(equipment))
        return NULL;
    equipment_handle = il2cpp_gchandle_new(equipment, 0);
    return equipment;
}
/* Reads each quickslot's stack count and cooldown flag. Il2CppArray elements start at 0x20,
 * after klass, monitor, bounds and length. */
static int read_slots(void *equipment, int *counts, int *cooling) {
    void *array = read_reference(equipment, quickslots_field);
    if (!array) return 0;
    uint32_t n = il2cpp_array_length(array);
    if (n > MAX_QUICKSLOTS) n = MAX_QUICKSLOTS;
    void *const *items = (void *const *)((char *)array + 0x20);
    for (uint32_t i = 0; i < n; ++i) {
        uint8_t flag = 0;
        counts[i] = 0;
        if (items[i] && il2cpp_object_get_class(items[i]) == quickslot_class) {
            il2cpp_field_get_value(items[i], stack_field, &counts[i]);
            il2cpp_field_get_value(items[i], cooldown_field, &flag);
        }
        cooling[i] = flag != 0;
    }
    return (int)n;
}
static int drink(void *equipment, int slot) {
    /* Make sure the game's static constructor has set FirstQuickslotIndex before reading it. */
    il2cpp_runtime_class_init(equipment_class);
    int first_quickslot = 0;
    il2cpp_field_static_get_value(quickslot_base_field, &first_quickslot);
    if (!base_logged) { base_logged = 1; note("guard_quickslot_base\t%d\n", first_quickslot); }
    if (!config.armed || potion_off) return RESULT_DRY;
    int quickslot = first_quickslot + slot;
    void *args[] = {&quickslot}, *exception = NULL;
    il2cpp_runtime_invoke(potion_method, equipment, args, &exception);
    if (exception) { disarm("potion", exception); return RESULT_EXCEPTION; }
    return RESULT_CALLED;
}
/* Logs each quickslot's count and cooldown flag when they change, to measure the game's
 * potion cooldown from real sessions. */
static void log_slot_changes(int n, const int *counts, const int *cooling, double epoch) {
    for (int i = 0; i < n; ++i) {
        if (n == logged_slot_count && counts[i] == logged_stacks[i] && cooling[i] == logged_cooling[i]) continue;
        note("guard_slot\t%d\tstack=%d\tcooldown=%d\tepoch=%.6f\n", i, counts[i], cooling[i], epoch);
        logged_stacks[i] = counts[i]; logged_cooling[i] = cooling[i];
    }
    logged_slot_count = n;
}
/* Applies a settings change sent from Exalt Client Mac (see LiveControl in live_state.h). */
static void check_control(void) {
    if (!live) return;
    LiveControl *control = live_control(live);
    uint32_t seq = atomic_load_explicit(&control->seq, memory_order_acquire);
    if (seq == last_control_seq) return;
    LiveControlData c;
    if (!control_read(control, &c)) return;   /* mid-write: try again next check */
    last_control_seq = seq;
    if (!c.request || c.request == last_control_request) return;
    last_control_request = c.request;
    int ok = c.death >= 0 && c.death <= 1 && guard_apply(&config, &guard, c.armed, c.potion, c.ceiling, c.nexus);
    if (ok) config.death = c.death;
    live_data.control_request = c.request;
    live_data.control_result = ok ? CONTROL_APPLIED : CONTROL_REJECTED;
    live_data.potion = config.potion; live_data.ceiling = config.ceiling; live_data.nexus = config.nexus;
    if (ok) note("guard_config\tarmed=%d\tpotion=%d\tceiling=%d\tnexus=%d\tdeath=%d\tsource=app\trequest=%u\n",
                 config.armed, config.potion, config.ceiling, config.nexus, config.death, c.request);
    else note("guard_config_rejected\tarmed=%d\tpotion=%d\tceiling=%d\tnexus=%d\trequest=%u\n",
              c.armed, c.potion, c.ceiling, c.nexus, c.request);
}
static void finish_join(int result) {
    live_data.join_request = pending_join;
    live_data.join_result = result;
    memcpy(live_data.join_name, pending_join_name, sizeof live_data.join_name);
    note("guard_join\t%s\t%s\n", pending_join_name, result == JOIN_SENT ? "sent" : result == JOIN_ERROR ? "game_error" :
         result == JOIN_UNAVAILABLE ? "unavailable" : "unsupported");
    pending_join = 0;
}
/* Picks up a Join click from the app (see LiveJoin in live_state.h). */
static void check_join(uint64_t now) {
    if (!live) return;
    LiveJoin *join = live_join(live);
    uint32_t seq = atomic_load_explicit(&join->seq, memory_order_acquire);
    if (seq == last_join_seq) return;
    LiveJoinData j;
    if (!join_read(join, &j)) return;
    last_join_seq = seq;
    if (!j.request || j.request == last_join_request) return;
    last_join_request = j.request;
    pending_join = j.request;
    memcpy(pending_join_name, j.name, sizeof pending_join_name);
    pending_join_name[sizeof pending_join_name - 1] = 0;
    for (char *c = pending_join_name; *c; ++c) if (*c == '\t' || *c == '\n') *c = ' ';
    pending_join_deadline = now + JOIN_WAIT_NS;
    if (!join_ok || join_off || !pending_join_name[0]) finish_join(JOIN_UNSUPPORTED);
}
/* Runs a pending Join with the user's character, exactly as the menu button does: the party
 * manager joins the named member, then the character's LMCLHOGGKKG(1000). The game's own checks
 * (party membership, where that member is) apply. */
static void run_join(void *player, uint64_t now) {
#ifdef EXALT_HIT_PROBE
    if (pending_join) finish_join(JOIN_UNSUPPORTED);
    return;
#endif
    if (!pending_join) return;
    void *party = player ? read_reference(player, party_manager_field) : NULL;
    if (!party) { if (now >= pending_join_deadline) finish_join(JOIN_UNAVAILABLE); return; }
    void *name = il2cpp_string_new(pending_join_name);
    void *args[] = {name}, *exception = NULL;
    il2cpp_runtime_invoke(join_method, party, args, &exception);
    if (exception) { disarm("join", exception); finish_join(JOIN_ERROR); return; }
    int32_t wait_ms = 1000;
    void *cooldown_args[] = {&wait_ms};
    il2cpp_runtime_invoke(join_cooldown_method, player, cooldown_args, &exception);
    if (exception) { disarm("join", exception); }   /* the join itself went out */
    finish_join(JOIN_SENT);
}
static void record_event(const Record *r) {
    if (r->result == RESULT_CALLED) { if (r->action == GUARD_POTION) ++live_data.potions_sent; else ++live_data.nexus_sent; }
    else if (r->result == RESULT_DRY) { if (r->action == GUARD_POTION) ++live_data.potions_dry; else ++live_data.nexus_dry; }
    LiveEvent *e = &live_data.events[live_data.event_count % LIVE_EVENTS];
    *e = (LiveEvent){.epoch = r->epoch, .action = r->action, .result = r->result, .slot = r->slot,
                     .hp = r->player_hp, .max_hp = r->player_max};
    ++live_data.event_count;
}
static void run_guard(Record *r, void *player, uint64_t now) {
    if (!guard_ok) return;
    il2cpp_field_get_value(player, max_field, &r->player_max);
    il2cpp_field_get_value(player, player_hp_field, &r->player_hp);
    /* The HUD lags the player HP value on heals by up to one server update, so requiring them
     * to agree on every check could delay an action by ~200 ms. Instead the player value must
     * have matched the HUD once for this player object, which still rules out a wrong field. */
    if (fabsf(r->hp - (float)r->player_hp) <= 1.0f) validated_player = (uintptr_t)player;
    int validated = validated_player == (uintptr_t)player;
    update_map(now);
    void *equipment = equipment_instance(now);
    int counts[MAX_QUICKSLOTS] = {0}, cooling[MAX_QUICKSLOTS] = {0};
    int n = equipment ? read_slots(equipment, counts, cooling) : 0;
    log_slot_changes(n, counts, cooling, r->epoch);
    int slot = guard_pick_slot(counts, n);
    int ready = slot >= 0 && !cooling[slot] && !potion_off;
#ifdef EXALT_CLIENT_FATAL
    if (live_data.death_blocking) { r->action = GUARD_NONE; guard.drinking = 0; }
    else
#endif
    r->action = guard_decide(&guard, &config, (uintptr_t)player, (float)r->player_hp,
                             (float)r->player_max, now, validated, in_nexus, ready);
    if (r->action == GUARD_POTION) { r->slot = slot; r->result = drink(equipment, slot); }
    if (r->action) record_event(r);
    live_data.slot_count = n;
    live_data.next_slot = slot;
    for (int i = 0; i < LIVE_SLOTS; ++i) {
        live_data.stacks[i] = i < n ? counts[i] : 0;
        live_data.cooldown[i] = i < n ? cooling[i] : 0;
    }
    live_data.drinking = guard.drinking;
    live_data.settled = !isnan(guard.max_seen) && now - guard.max_since >= config.settle_ns;
    /* Closest call: lowest HP percent on a trusted, settled reading outside the Nexus. */
    if (validated && live_data.settled && !in_nexus && r->player_hp > 0 && r->player_max > 0 &&
        r->player_hp <= r->player_max &&
        (!live_data.lowest_max_hp ||
         (int64_t)r->player_hp * live_data.lowest_max_hp < (int64_t)live_data.lowest_hp * r->player_max)) {
        live_data.lowest_hp = r->player_hp; live_data.lowest_max_hp = r->player_max;
        live_data.lowest_epoch = r->epoch;
    }
}
static void publish_live(const Record *r, uint64_t now) {
    if (!live) return;
    uint32_t gap_us = (uint32_t)(r->gap_ns / 1000);
    if (now - gap_window_start >= NSEC_PER_SEC) { gap_window_start = now; gap_window_max = 0; }
    if (gap_us > gap_window_max) gap_window_max = gap_us;
    live_data.status = r->status;
    live_data.armed = config.armed; live_data.death = config.death;
    live_data.hp = r->player_hp; live_data.max_hp = r->player_max; live_data.hud_hp = r->hp;
    live_data.map_known = map_ok && !map_unknown_logged;
    live_data.in_nexus = in_nexus;
    live_data.sample_ns = r->monotonic_ns;
    live_data.sample_epoch = r->epoch;
    live_data.ticks = r->sequence;
    live_data.last_gap_us = gap_us;
    live_data.max_gap_us = gap_window_max;
    live_data.work_ns = (uint32_t)r->work_ns;
    live_publish(live, &live_data);
}
static void open_live(const char *folder) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/guard-live.bin", folder) >= (int)sizeof path) return;
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    if (ftruncate(fd, LIVE_FILE_SIZE)) { close(fd); return; }
    void *map = mmap(NULL, LIVE_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return;
    live = map;
    live->magic = 0;  /* invalid until the header is rewritten for this session */
    memset(&live->data, 0, sizeof live->data);
    live->version = LIVE_VERSION;
    live_data.pid = getpid();
    live_data.potion = config.potion; live_data.ceiling = config.ceiling; live_data.nexus = config.nexus;
    live_data.next_slot = -1;
    snprintf(live_data.log_name, sizeof live_data.log_name, "guard-%d.tsv", getpid());
    memset(live_control(live), 0, sizeof(LiveControl));   /* ignore settings left from a past session */
    memset(live_join(live), 0, sizeof(LiveJoin));         /* and Join clicks */
    atomic_store_explicit(&live->seq, 0, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    live->magic = LIVE_MAGIC;
}

static void drain(void *unused) {
    (void)unused;
#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
    hit_probe_drain();
#endif
    int closing = atomic_load_explicit(&finished, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&note_tail, memory_order_relaxed);
    while (tail != atomic_load_explicit(&note_head, memory_order_acquire)) {
        fputs(notes[tail % NOTE_CAPACITY], logfile);
        atomic_store_explicit(&note_tail, ++tail, memory_order_release);
    }
    Record r;
    while (ring_pop(&ring, &r)) {
        fprintf(logfile, "timing\t%llu\t%.6f\t%llu\t%llu\t%llu\t%d\t%.9g\t%.9g\t%.9g\t%.9g\t%d\t%.9g\t%llu\t%llu\t%d\t%d\t%.9g\t%d\t%d\t%d\n",
            r.sequence, r.epoch, r.monotonic_ns, r.gap_ns, r.work_ns, r.status,
            r.hp, r.xyz[0], r.xyz[1], r.xyz[2], r.decreased, r.previous_hp, r.detection_ns, r.dropped,
            r.player_hp, r.player_max, r.bar_aux, r.action, r.result, r.slot);
    }
    if (closing) {
        fputs("status\tcomplete\n", logfile);
        dispatch_source_cancel(writer);
        fclose(logfile); logfile = NULL;
    } else fflush(logfile);
}
static void finish(void) {
    latency_note();
    release(&gui_handle); release(&player_handle); release(&equipment_handle); release(&realm_quests_handle);
    release(&chat_handle);
    dispatch_source_cancel(timer);
    atomic_store_explicit(&finished, 1, memory_order_release);
}
#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
#include "../probe/hit_probe.h"
#endif
static void tick(void *unused) {
    (void)unused;
    uint64_t begin = monotonic_ns();
    if (SESSION_NS && begin - start_ns >= SESSION_NS) { finish(); return; }
    Record r = {.sequence = ++sequence, .monotonic_ns = begin, .slot = -1,
                .epoch = start_epoch + (double)(begin - start_ns) / 1e9,
                .gap_ns = previous_ns ? begin - previous_ns : 0, .status = 1};
    previous_ns = begin;
    int sample_stages = (r.sequence & 63) == 0;
    uint64_t lookup_end = 0, guard_end = 0;
    void *gui = NULL, *player = NULL, *bar = NULL, *own = NULL;
    if (!ready && begin >= next_lookup) {
        ready = prepare(); next_lookup = begin + 500 * NSEC_PER_MSEC;
    }
    if (!ready) goto done;
    check_control();
#ifdef EXALT_HIT_PROBE
    config.armed = 0;
#endif
    check_join(begin);
    r.status = 2;
    if (gui_handle) {
        gui = il2cpp_gchandle_get_target(gui_handle);
        if (!gui || il2cpp_object_get_class(gui) != gui_class || !native_alive(gui)) {
            gui = NULL; release(&gui_handle); release(&player_handle); detector.valid = 0;
        }
    }
    if (!gui && begin >= next_lookup) {
        next_lookup = begin + 500 * NSEC_PER_MSEC;
        gui = find_object(gui_class);
        if (gui && il2cpp_object_get_class(gui) == gui_class && native_alive(gui)) {
            gui_handle = il2cpp_gchandle_new(gui, 0);
            if (!gui_handle) gui = NULL;
        } else gui = NULL;
    }
    if (!gui) goto done;
    r.status = 3;
    player = read_reference(gui, player_field);
    bar = read_reference(gui, bar_field);
    if (!player || il2cpp_object_get_class(player) != player_class ||
        !bar || il2cpp_object_get_class(bar) != bar_class || !native_alive(bar)) goto done;
    own = player;
    if (!player_handle || il2cpp_gchandle_get_target(player_handle) != player) {
        release(&player_handle); detector.valid = 0;
        player_handle = il2cpp_gchandle_new(player, 0);
        if (!player_handle) goto done;
    }
    il2cpp_field_get_value(bar, hp_field, &r.hp);
    if (bar_aux_field) il2cpp_field_get_value(bar, bar_aux_field, &r.bar_aux);
    il2cpp_field_get_value(player, position_field, r.xyz);
    r.status = isfinite(r.hp) && r.hp >= 0 && isfinite(r.xyz[0]) && isfinite(r.xyz[1]) && isfinite(r.xyz[2]) ? 0 : 4;
    if (sample_stages) lookup_end = monotonic_ns();
    if (r.status == 0) run_guard(&r, player, begin);
done:
    if (sample_stages) {
        guard_end = monotonic_ns();
        if (!lookup_end) lookup_end = guard_end;
    }
#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
    hit_probe_tick(own, begin);
#endif
    if (ready) { poll_chat(begin, r.epoch, own); run_join(own, begin); }
    r.previous_hp = detector.valid ? detector.hp : r.hp;
    r.decreased = detect(&detector, (uintptr_t)player, r.hp, begin, r.status == 0);
    r.detection_ns = monotonic_ns() - begin;
    if (r.status != 0 && ready) release(&player_handle);
    r.dropped = drops;
    r.work_ns = monotonic_ns() - begin;
    publish_live(&r, begin);
    uint64_t published = monotonic_ns();
    latency_observe(&latency, r.gap_ns, published - begin, r.status == 0);
    if (sample_stages) {
        ++latency.stage_samples;
        latency_stage_max(&latency.lookup_ns, begin, lookup_end);
        latency_stage_max(&latency.guard_ns, lookup_end, guard_end);
        latency_stage_max(&latency.services_ns, guard_end, begin + r.work_ns);
        latency_stage_max(&latency.publication_ns, begin + r.work_ns, published);
    }
    if (!next_latency_note) next_latency_note = begin + 10 * NSEC_PER_SEC;
    if (begin >= next_latency_note) {
        latency_note(); next_latency_note = begin + 10 * NSEC_PER_SEC;
    }
    /* Log only rows that change something (or one per second), so long sessions stay small. */
    int changed = !last_logged_ns || r.status != last_logged.status || r.hp != last_logged.hp ||
                  r.player_hp != last_logged.player_hp || r.player_max != last_logged.player_max ||
                  r.action || r.decreased || r.dropped != last_logged.dropped ||
                  begin - last_logged_ns >= HEARTBEAT_NS;
    if (!changed) return;
    last_logged = r; last_logged_ns = begin;
    if (!ring_push(&ring, r)) ++drops;
}
__attribute__((constructor)) static void start(void) {
    char path[PATH_MAX]; uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size)) return;
    const char *leaf = strrchr(path, '/'); leaf = leaf ? leaf + 1 : path;
    if (strcmp(leaf, "RotMGExalt")) return;
    char folder[PATH_MAX];
#ifdef PROBE_LOG_DIR
    if (snprintf(folder, sizeof folder, "%s", PROBE_LOG_DIR) >= (int)sizeof folder) return;
#else
    /* Exalt Client Mac names its data folder (Application Support). Without it, logs go to
     * logs/ beside this dylib. */
    const char *data = getenv("EXALT_GUARD_DIR");
    if (data && *data) {
        if (snprintf(folder, sizeof folder, "%s/logs", data) >= (int)sizeof folder) return;
    } else {
        Dl_info self;
        if (!dladdr((const void *)&start, &self) || !self.dli_fname) return;
        const char *slash = strrchr(self.dli_fname, '/');
        if (!slash) return;
        int base = (int)(slash - self.dli_fname);
        if (snprintf(folder, sizeof folder, "%.*s/logs", base, self.dli_fname) >= (int)sizeof folder) return;
    }
    if (mkdir(folder, 0700) && errno != EEXIST) return;
#endif
    int n = snprintf(path, sizeof path, "%s/guard-%d.tsv", folder, getpid());
    if (n < 0 || (size_t)n >= sizeof path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    logfile = fdopen(fd, "w"); if (!logfile) { close(fd); return; }
    int parsed = guard_parse(&config, getenv("EXALT_GUARD"));
#ifdef EXALT_HIT_PROBE
    config.armed = 0;
#endif
    fputs("status\tguard_loaded\t1000Hz\n", logfile);
    if (!parsed) fputs("status\tguard_config_invalid\n", logfile);
    fprintf(logfile, "guard_config\tarmed=%d\tpotion=%d\tceiling=%d\tnexus=%d\tdeath=%d\tquickslots=sequential\n",
            config.armed, config.potion, config.ceiling, config.nexus, config.death);
    fflush(logfile);
    open_live(folder);
    struct timespec epoch; clock_gettime(CLOCK_REALTIME, &epoch);
    start_epoch = epoch.tv_sec + epoch.tv_nsec / 1e9; start_ns = monotonic_ns();
#if defined(EXALT_HIT_PROBE) || defined(EXALT_CLIENT_FATAL)
    hit_probe_open(folder);
#endif
    live_data.session_start_epoch = start_epoch;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_queue_create("local.exalt.guard.writer", DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_event_handler_f(timer, tick);
    dispatch_source_set_event_handler_f(writer, drain);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, PERIOD_NS), PERIOD_NS, 50000);
    dispatch_source_set_timer(writer, dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), 100*NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_resume(writer); dispatch_resume(timer);
}
