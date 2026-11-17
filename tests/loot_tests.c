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
    int32_t dealt[LOOT_YOURS];
    loot_hit_add(&t, 7, LOOT_OTHER, 500);             /* someone else's hit never tracks a mob */
    assert(!loot_hit_kill(&t, 7, dealt));
    loot_hit_add(&t, 7, LOOT_PROJECTILE, 100);
    loot_hit_add(&t, 7, LOOT_ABILITY, 40);
    loot_hit_add(&t, 7, LOOT_PROJECTILE, 60);
    assert(loot_hit_kill(&t, 7, dealt));
    assert(dealt[LOOT_PROJECTILE] == 160 && dealt[LOOT_PROJECTILE_ALT] == 0 && dealt[LOOT_ABILITY] == 40);
    assert(!loot_hit_kill(&t, 7, dealt));             /* local and server both report the death */
    loot_hit_add(&t, 7, LOOT_PROJECTILE, 10);         /* a shot landing on the corpse */
    assert(!loot_hit_kill(&t, 7, dealt));
    loot_hit_add(&t, 9, LOOT_PROJECTILE, 1);
    loot_hit_add(&t, 9 + LOOT_HITS, LOOT_PROJECTILE, 1);   /* a much newer mob on the same slot */
    assert(t.evictions == 1 && !loot_hit_kill(&t, 9, dealt) && loot_hit_kill(&t, 9 + LOOT_HITS, dealt));
    loot_hit_add(&t, 11, LOOT_PROJECTILE, 1);
    loot_hits_clear(&t);                              /* new map */
    assert(!loot_hit_kill(&t, 11, dealt));
}

static void test_types(void) {
    static LootType t[LOOT_TYPES];
    loot_type_set(t, 42, 0x0d13);
    assert(loot_type_get(t, 42) == 0x0d13 && loot_type_get(t, 43) == 0);
    loot_type_set(t, 42 + LOOT_TYPES, 5);
    assert(loot_type_get(t, 42) == 0 && loot_type_get(t, 42 + LOOT_TYPES) == 5);
    assert(loot_is_bag(1292) && loot_is_bag(1728) && !loot_is_bag(1293) && !loot_is_bag(0));
    assert(loot_item_slot(8) == 0 && loot_item_slot(15) == 7 && loot_item_slot(7) == -1 && loot_item_slot(16) == -1);
}

static void test_format(void) {
    char line[256];
    LootEvent kill = {.id = 1001, .map = 3, .type = 3340, .kind = LOOT_KILL, .source = LOOT_ABILITY,
                      .pos = {12.5f, 0, 30.25f}, .v = {900, 0, 120, 4000}};
    loot_format(&kill, 1763300000.1234, line, sizeof line);
    assert(!strcmp(line, "kill\t1763300000.123\t3\t1001\t3340\t12.50\t0.00\t30.25\t900\t0\t120\t4000\tability\n"));
    LootEvent bag = {.id = 1002, .map = 3, .type = 1295, .kind = LOOT_BAG, .pos = {12.5f, 30.25f},
                     .v = {2856, 2856, -1, -1, -1, -1, -1, -1}};
    loot_format(&bag, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "bag\t1763300000.500\t3\t1002\t1295\t12.50\t30.25\t2856\t2856\t-1\t-1\t-1\t-1\t-1\t-1\n"));
    LootEvent stat = {.id = 1002, .map = 3, .kind = LOOT_BAG_STAT, .v = {80, 0}};
    strcpy(stat.text, "AQID");
    loot_format(&stat, 1763300000.5, line, sizeof line);
    assert(!strcmp(line, "bag_stat\t1763300000.500\t3\t1002\t80\t0\tAQID\n"));
    LootEvent map = {.map = 4, .kind = LOOT_MAP};
    strcpy(map.text, "Lost Halls");
    loot_format(&map, 1763300001, line, sizeof line);
    assert(!strcmp(line, "map\t1763300001.000\t4\tLost Halls\n"));
    LootEvent odd = {.kind = LOOT_KILL, .source = 200};
    loot_format(&odd, 0, line, sizeof line);
    assert(strstr(line, "\tunknown\n"));
}

int main(void) {
    test_ring();
    test_hits();
    test_types();
    test_format();
    puts("Loot capture tests passed");
}
