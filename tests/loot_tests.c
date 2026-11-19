#include "../guard/loot_core.h"
#include <assert.h>
#include <stdlib.h>

static void test_ring(void) {
    static LootRing r;
    LootEvent e = {.kind = LOOT_KILL}, out;
    for (int i = 0; i < LOOT_RING; ++i) { e.id = i; assert(loot_push(&r, &e)); }
    assert(!loot_push(&r, &e) && r.lost == 1);   /* full: counted, not overwritten */
    assert(loot_pop(&r, &out) && out.id == 0);
    assert(loot_push(&r, &e));
    int n = 1;
    while (loot_pop(&r, &out)) ++n;
    assert(n == LOOT_RING + 1);
}

static void test_hits(void) {
    static LootHits t;
    LootHit h;
    assert(!loot_hit_add(&t, 7, LOOT_OTHER, 0, 1));    /* a Damage message without damage */
    assert(!loot_hit_add(&t, 7, LOOT_UNKNOWN, 50, 1) && !loot_hit_take(&t, 7, &h));
    loot_hit_add(&t, 7, LOOT_PROJECTILE, 100, 1);
    loot_hit_add(&t, 7, LOOT_ABILITY, 40, 2);
    loot_hit_add(&t, 7, LOOT_OTHER, 500, 3);          /* another player's hit */
    assert(loot_hit_add(&t, 7, LOOT_PROJECTILE, 60, 4)->last_ns == 4);
    assert(loot_hit_take(&t, 7, &h) && h.damage[LOOT_PROJECTILE] == 160 && h.damage[LOOT_PROJECTILE_ALT] == 0 &&
           h.damage[LOOT_ABILITY] == 40 && h.others == 500 && h.last_ns == 4);
    assert(!loot_hit_take(&t, 7, &h));                 /* removed: it needs new hits to count again */
    assert(loot_hit_add(&t, 8, LOOT_OTHER, 5, 5) && loot_hit_take(&t, 8, &h) && h.others == 5);   /* hit only by others */
    loot_hit_add(&t, 9, LOOT_PROJECTILE, 1, 5);
    loot_hit_add(&t, 9 + LOOT_HITS, LOOT_PROJECTILE, 1, 5);   /* a much newer mob on the same slot */
    assert(t.evictions == 1 && !loot_hit_take(&t, 9, &h) && loot_hit_take(&t, 9 + LOOT_HITS, &h));
    loot_hit_add(&t, 11, LOOT_PROJECTILE, 1, 6);
    loot_hits_clear(&t);                              /* new map */
    assert(!loot_hit_take(&t, 11, &h));
}

static void test_seen(void) {
    static LootSeen s[LOOT_SEEN];
    assert(loot_bag_first(s, 500, 1) && !loot_bag_first(s, 500, 1));   /* sent again on coming back into view */
    assert(loot_bag_first(s, 500, 2));                                 /* the same id on a new map */
    assert(loot_bag_first(s, 501, 2) && !loot_bag_first(s, 500, 2));
}

static void test_ticks(void) {
    static LootTicks t;
    LootSpot bags[LOOT_PENDING];
    int32_t killers[LOOT_PENDING];
    const float near[2] = {10, 10}, far[2] = {40, 40}, bag[2] = {10.5f, 10};
    loot_tick_bag(&t, 100, bag);
    loot_tick_killed(&t, 1, near);                     /* removed in the bag's own update: not its kill */
    assert(loot_tick_end(&t, bags, killers) == 0);
    loot_tick_killed(&t, 2, far);
    loot_tick_killed(&t, 3, near);                     /* removed one update after the bag */
    loot_tick_bag(&t, 101, far);
    assert(loot_tick_end(&t, bags, killers) == 1 && bags[0].id == 100 && killers[0] == 3);
    assert(loot_tick_end(&t, bags, killers) == 1 && bags[0].id == 101 && killers[0] == 0);   /* no kill: unknown */
    loot_tick_bag(&t, 102, bag);
    loot_tick_killed(&t, 4, far);
    loot_ticks_clear(&t);                              /* new map */
    assert(loot_tick_end(&t, bags, killers) == 0 && loot_tick_end(&t, bags, killers) == 0);
    for (int i = 0; i <= LOOT_PENDING; ++i) loot_tick_bag(&t, i + 1, bag);
    assert(t.overflow == 1);
}

static void test_source(void) {
    enum { HIT = 0x100, ALT = 0x200, MESSAGE = 0x300 };
    assert(loot_source(HIT, HIT, ALT, MESSAGE, 0, 5) == LOOT_PROJECTILE);
    assert(loot_source(ALT, HIT, ALT, MESSAGE, 0, 5) == LOOT_PROJECTILE_ALT);
    assert(loot_source(MESSAGE, HIT, ALT, MESSAGE, 5, 5) == LOOT_ABILITY);     /* the server says you shot */
    assert(loot_source(MESSAGE, HIT, ALT, MESSAGE, 6, 5) == LOOT_OTHER);       /* another player, or your pet */
    assert(loot_source(MESSAGE, HIT, ALT, MESSAGE, 0, 0) == LOOT_OTHER);       /* your id not known yet */
    assert(loot_source(0x999, HIT, ALT, MESSAGE, 5, 5) == LOOT_UNKNOWN);
}

static void test_types(void) {
    static LootType t[LOOT_TYPES];
    const float pos[2] = {3, 4};
    loot_type_set(t, 42, 0x0d13, pos);
    assert(loot_type_get(t, 42) == 0x0d13 && loot_type_get(t, 43) == 0 && loot_type_find(t, 42)->pos[1] == 4);
    loot_type_set(t, 42 + LOOT_TYPES, 5, pos);
    assert(loot_type_get(t, 42) == 0 && loot_type_get(t, 42 + LOOT_TYPES) == 5 && !loot_type_find(t, 0));
    assert(loot_is_bag(1292) && loot_is_bag(1728) && !loot_is_bag(1293) && !loot_is_bag(0));
    assert(loot_player_stat_kept(0) && !loot_player_stat_kept(1) && !loot_player_stat_kept(4) && !loot_player_stat_kept(6) &&
           loot_player_stat_kept(255) && !loot_player_stat_kept(256));
    assert(loot_item_slot(8) == 0 && loot_item_slot(15) == 7 && loot_item_slot(7) == -1 && loot_item_slot(16) == -1);
}

static void test_format(void) {
    char line[512];
    LootEvent kill = {.id = 1001, .map = 3, .type = 3340, .kind = LOOT_KILL, .source = LOOT_REMOVED,
                      .pos = {12.5f, 30.25f}, .v = {900, 0, 120, 4000, 240, 75}};
    loot_format(&kill, 1763300000.1234, line, sizeof line);
    assert(!strcmp(line, "kill\t1763300000.123\t3\t1001\t3340\t12.50\t30.25\t0.00\t900\t0\t120\t4000\tremoved\t240\t75\n"));
    LootEvent drop = {.id = 1002, .map = 3, .kind = LOOT_DROP, .v = {1001}};
    loot_format(&drop, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "drop\t1763300000.500\t3\t1002\t1001\n"));
    LootEvent bag = {.id = 1002, .map = 3, .type = 1295, .kind = LOOT_BAG, .pos = {12.5f, 30.25f},
                     .v = {2856, 2856, -1, -1, -1, -1, -1, -1}};
    loot_format(&bag, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "bag\t1763300000.500\t3\t1002\t1295\t12.50\t30.25\t2856\t2856\t-1\t-1\t-1\t-1\t-1\t-1\n"));
    LootEvent stat = {.id = 1002, .map = 3, .kind = LOOT_BAG_STAT, .v = {80, 0}};
    strcpy(stat.text, "AQID");
    loot_format(&stat, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "bag_stat\t1763300000.500\t3\t1002\t80\t0\tAQID\n"));
    memset(stat.text, 'A', sizeof stat.text - 1);       /* enchants for 8 slots: kept whole */
    stat.text[sizeof stat.text - 1] = 0;
    assert(loot_format(&stat, 1763300000.5, line, sizeof line) < (int)sizeof line && strstr(line, stat.text));
    LootEvent map = {.map = 4, .kind = LOOT_MAP};
    strcpy(map.text, "Lost Halls");
    loot_format(&map, 1763300001, line, sizeof line);
    assert(!strcmp(line, "map\t1763300001.000\t4\tLost Halls\n"));
    LootEvent info = {.map = 4, .kind = LOOT_MAP_INFO, .v = {782, 123456, 0, 1, 2, 3, 4, 5}};
    strcpy(info.text, "Zephyr\tDRAINED_3;|A\t");
    loot_format(&info, 1763300001, line, sizeof line);
    assert(!strcmp(line, "map_info\t1763300001.000\t4\t782\t123456\t0\t1\t2\t3\t4\t5\tZephyr\tDRAINED_3;|A\t\n"));
    LootEvent player = {.map = 4, .kind = LOOT_PLAYER_STAT, .v = {39, 2500}};
    loot_format(&player, 1763300001, line, sizeof line);
    assert(!strcmp(line, "player_stat\t1763300001.000\t4\t39\t2500\n"));
    LootEvent gear = {.map = 4, .kind = LOOT_PLAYER_STAT, .v = {80, 0}};
    strcpy(gear.text, "AAIB,AAIC,,AAID,AAIE,AAIF");
    loot_gear_parts(gear.text);
    assert(!strcmp(gear.text, "AAIB,AAIC,,AAID"));
    loot_format(&gear, 1763300001, line, sizeof line);
    assert(!strcmp(line, "player_stat\t1763300001.000\t4\t80\t0\tAAIB,AAIC,,AAID\n"));
    strcpy(gear.text, "AAIB");
    loot_gear_parts(gear.text);
    assert(!strcmp(gear.text, "AAIB"));
    LootEvent portal = {.id = 1003, .map = 3, .type = 1795, .kind = LOOT_PORTAL, .pos = {12.5f, 30.25f}};
    loot_format(&portal, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "portal\t1763300000.500\t3\t1003\t1795\t12.50\t30.25\n"));
    LootEvent odd = {.kind = LOOT_KILL, .source = 200};
    loot_format(&odd, 0, line, sizeof line);
    assert(strstr(line, "\tunknown\t0\t0\n"));
}

static void test_portals(void) {
    static LootPortals p;
    assert(loot_portals_parse(&p, "1795,1796,1795,x,0,70000,65535") == 3);   /* repeats, junk and out-of-range skipped */
    assert(loot_is_portal(&p, 1795) && loot_is_portal(&p, 1796) && loot_is_portal(&p, 65535));
    assert(!loot_is_portal(&p, 1797) && !loot_is_portal(&p, 0) && !loot_is_portal(&p, 1295));
    assert(loot_portals_parse(&p, NULL) == 0 && !loot_is_portal(&p, 1795));   /* no catalog: no portals */
}

int main(void) {
    test_portals();
    test_ring();
    test_hits();
    test_seen();
    test_ticks();
    test_source();
    test_types();
    test_format();
    puts("Loot capture tests passed");
}
