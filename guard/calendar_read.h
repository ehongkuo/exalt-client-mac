/* The game's events calendar (issue #85): its dungeon events, read from the client, not the network. The client
 * downloads the calendar from DECA's web server when you log in (signed in, over HTTPS), so it is in no game
 * message. ApplicationManager (a singleton) keeps the calendar manager, which keeps each dungeon event wrapped in
 * a list. The events' own fields have readable names (DecaGames.RotMG.Data.Fame.DungeonEventData); the path to
 * them has obfuscated names, checked by type as the other reads are. Every 10 s the guard reads the list and,
 * when it changed, rewrites calendar-<started>-<pid>.tsv beside its log. A missing name turns this read off and is
 * noted; it never stops the game. Included by loot_capture.h. */

enum { CALENDAR_EVENTS = 64 };
static void *calendar_app_class, *calendar_manager_field, *calendar_list_field, *calendar_wrapped_field;
static void *calendar_text_fields[5], *calendar_float_fields[2], *calendar_date_fields[2], *calendar_display_field;
static ListFields calendar_list;
static void *calendar_app_handle;
static int calendar_ok;
static uint64_t calendar_next, calendar_hash;
static char calendar_path[PATH_MAX];

static void calendar_prepare(const void *game) {
    calendar_app_class = il2cpp_class_from_name(game, "DecaGames.RotMG.Managers", "ApplicationManager");
    void *manager = il2cpp_class_from_name(game, "", "PNIECGLNNCC");
    void *wrapper = il2cpp_class_from_name(game, "", "OCCMHHNKGBA");   /* wraps one DungeonEventData */
    void *event = il2cpp_class_from_name(game, "DecaGames.RotMG.Data.Fame", "DungeonEventData");
    if (!calendar_app_class || !manager || !wrapper || !event) { note("calendar_unavailable\tclasses_missing\n"); return; }
    calendar_manager_field = typed_field(calendar_app_class, "<DMFFGOGBNEG>k__BackingField", "PNIECGLNNCC");
    calendar_list_field = typed_field(manager, "KEKJHNCBAJL", "System.Collections.Generic.List<OCCMHHNKGBA>");
    calendar_wrapped_field = typed_field(wrapper, "EDFJHDFMGED", "DecaGames.RotMG.Data.Fame.DungeonEventData");
    static const char *const texts[] = {"dungeon", "startTime", "endTime", "questObject", "description"};
    int ok = calendar_manager_field && calendar_list_field && calendar_wrapped_field;
    for (int i = 0; ok && i < 5; ++i) ok = (calendar_text_fields[i] = typed_field(event, texts[i], "System.String")) != NULL;
    ok = ok && (calendar_float_fields[0] = typed_field(event, "lootDropMul", "System.Single")) &&
         (calendar_float_fields[1] = typed_field(event, "xpMul", "System.Single")) &&
         (calendar_date_fields[0] = typed_field(event, "startDate", "System.DateTime")) &&
         (calendar_date_fields[1] = typed_field(event, "endDate", "System.DateTime")) &&
         (calendar_display_field = typed_field(event, "display", "System.Boolean"));
    calendar_ok = ok;
    if (!ok) note("calendar_unavailable\tfields_missing\n");
}

static void calendar_open(const char *folder) {
    if (snprintf(calendar_path, sizeof calendar_path, "%s/calendar-%.0f-%d.tsv", folder, start_epoch, getpid()) >= (int)sizeof calendar_path)
        calendar_path[0] = 0;
}

/* One line per event: its start and end as the calendar's text and as DateTime data (ticks with the kind in the top
 * two bits), the dungeon, the quest object (its chest), the loot and XP multipliers, whether it shows, and its text. */
static size_t calendar_line(char *out, size_t size, void *event) {
    char text[5][160];
    for (int i = 0; i < 5; ++i) read_utf8(read_reference(event, calendar_text_fields[i]), text[i], sizeof text[i]);
    float loot = 0, xp = 0; uint64_t start = 0, end = 0; uint8_t display = 0;
    il2cpp_field_get_value(event, calendar_float_fields[0], &loot);
    il2cpp_field_get_value(event, calendar_float_fields[1], &xp);
    il2cpp_field_get_value(event, calendar_date_fields[0], &start);
    il2cpp_field_get_value(event, calendar_date_fields[1], &end);
    il2cpp_field_get_value(event, calendar_display_field, &display);
    int n = snprintf(out, size, "dungeon_event\t%s\t%s\t%llu\t%llu\t%s\t%s\t%.4g\t%.4g\t%d\t%s\n", text[1], text[2],
                     (unsigned long long)start, (unsigned long long)end, text[0], text[3], loot, xp, display, text[4]);
    return n > 0 && (size_t)n < size ? (size_t)n : 0;
}

/* Main thread, from the 1 ms timer: a lookup every 10 s, a file write only when the events changed. */
static void calendar_tick(uint64_t now) {
    if (!calendar_ok || !calendar_path[0] || now < calendar_next) return;
    calendar_next = now + 10 * NSEC_PER_SEC;
    void *app = calendar_app_handle ? il2cpp_gchandle_get_target(calendar_app_handle) : NULL;
    if (!app || il2cpp_object_get_class(app) != calendar_app_class || !native_alive(app)) {
        release(&calendar_app_handle);
        app = find_object(calendar_app_class);
        if (!app || il2cpp_object_get_class(app) != calendar_app_class || !native_alive(app)) return;
        calendar_app_handle = il2cpp_gchandle_new(app, 0);
    }
    void *manager = read_reference(app, calendar_manager_field), *list = manager ? read_reference(manager, calendar_list_field) : NULL;
    void *const *items = NULL;
    int32_t count = list ? list_items(list, "OCCMHHNKGBA[]", &calendar_list, &items) : 0;
    if (count <= 0) return;   /* not downloaded yet */
    static char body[CALENDAR_EVENTS * 600];
    size_t used = 0;
    for (int32_t i = 0; i < count && i < CALENDAR_EVENTS; ++i) {
        void *event = items[i] ? read_reference(items[i], calendar_wrapped_field) : NULL;
        if (event) used += calendar_line(body + used, sizeof body - used, event);
    }
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < used; ++i) hash = (hash ^ (unsigned char)body[i]) * 1099511628211ULL;
    if (!used || hash == calendar_hash) return;
    calendar_hash = hash;
    char temporary[PATH_MAX + 8];
    snprintf(temporary, sizeof temporary, "%s.new", calendar_path);
    FILE *f = fopen(temporary, "w");
    if (!f) return;
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    fprintf(f, "calendar_read\t%.3f\t%d\n", t.tv_sec + t.tv_nsec / 1e9, count);
    fwrite(body, 1, used, f);
    if (fclose(f) == 0 && rename(temporary, calendar_path) == 0) note("calendar_read\tevents=%d\n", count);
}
