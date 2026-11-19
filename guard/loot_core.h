/* Drop-rate capture (issue #38): fixed events, the tables the hooks use, and the log line format.
 * Pure C, no il2cpp, so it is tested on its own. The hooks push events on the game's main thread;
 * the guard's writer thread pops them and writes loot-<pid>.tsv, which the app imports. */
#ifndef LOOT_CORE_H
#define LOOT_CORE_H
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define LOOT_FORMAT 4   /* 4: player_stat lines may carry text (stat 80, your gear's enchantments) */
enum { LOOT_KILL = 1, LOOT_BAG, LOOT_BAG_STAT, LOOT_MAP, LOOT_MAP_INFO, LOOT_PLAYER_STAT, LOOT_DROP };
/* Who dealt a hit. The first three are you; "other" is anyone else, from a Damage message. A kill
 * is the server removing a mob someone hit, so every kill is "removed". */
enum { LOOT_PROJECTILE, LOOT_PROJECTILE_ALT, LOOT_ABILITY, LOOT_YOURS, LOOT_OTHER = LOOT_YOURS, LOOT_UNKNOWN, LOOT_REMOVED };
static const char *const loot_source_names[] = {"projectile", "projectile_alt", "ability", "other", "unknown", "removed"};
/* Who dealt a hit into the damage method, from where it was called (an offset in the game) and, for a
 * Damage message, the shooter the server named. A pet is its own object, so its hits are "other". */
static inline int loot_source(uintptr_t caller, uintptr_t projectile, uintptr_t projectile_alt, uintptr_t message,
                              int32_t shooter, int32_t self) {
    if (caller == projectile) return LOOT_PROJECTILE;
    if (caller == projectile_alt) return LOOT_PROJECTILE_ALT;
    if (caller == message) return self && shooter == self ? LOOT_ABILITY : LOOT_OTHER;
    return LOOT_UNKNOWN;
}

typedef struct {
    uint64_t ns;
    int32_t id;
    uint32_t map;           /* map generation: object ids are only unique within one */
    uint16_t type;
    uint8_t kind, source;
    float pos[3];
    int32_t v[8];           /* kill: your damage by source, max HP, ms since the last hit, others' damage; bag: items;
                               stat: type, value; drop: the bag's kill (object id, 0 for none);
                               map info: your class, then raw ints; the text holds its strings, tab-separated */
    char text[256];         /* stat 80 (enchants per slot) runs past 100 characters */
} LootEvent;

/* Single producer (game main thread), single consumer (writer thread). */
#define LOOT_RING 4096
typedef struct {
    LootEvent events[LOOT_RING];
    _Atomic uint64_t head, tail, lost;
} LootRing;
static inline int loot_push(LootRing *r, const LootEvent *e) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    if (head - atomic_load_explicit(&r->tail, memory_order_acquire) == LOOT_RING) {
        atomic_fetch_add_explicit(&r->lost, 1, memory_order_relaxed);
        return 0;
    }
    r->events[head % LOOT_RING] = *e;
    atomic_store_explicit(&r->head, head + 1, memory_order_release);
    return 1;
}
static inline int loot_pop(LootRing *r, LootEvent *e) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&r->head, memory_order_acquire)) return 0;
    *e = r->events[tail % LOOT_RING];
    atomic_store_explicit(&r->tail, tail + 1, memory_order_release);
    return 1;
}

/* Mobs someone hit, as RealmHound keeps them: your hits and every Damage message the server sends
 * with damage. Direct-mapped by object id: the server hands out ids in order, so a slot is reused
 * only when a much newer hit mob lands on it (counted as an eviction). */
#define LOOT_HITS 4096
typedef struct { int32_t id, damage[LOOT_YOURS], others, max; uint64_t last_ns; } LootHit;
typedef struct { LootHit slot[LOOT_HITS]; uint64_t evictions; } LootHits;
static inline void loot_hits_clear(LootHits *t) { memset(t->slot, 0, sizeof t->slot); }
/* Returns the mob's entry, or NULL when the hit does not count: an unknown caller, or someone
 * else's hit without damage. */
static inline LootHit *loot_hit_add(LootHits *t, int32_t id, int source, int32_t damage, uint64_t ns) {
    if (!id || source < 0 || source > LOOT_OTHER || (source == LOOT_OTHER && damage <= 0)) return NULL;
    LootHit *h = &t->slot[(uint32_t)id % LOOT_HITS];
    if (h->id != id) {
        if (h->id) ++t->evictions;
        *h = (LootHit){.id = id};
    }
    if (damage > 0) *(source == LOOT_OTHER ? &h->others : &h->damage[source]) += damage;
    h->last_ns = ns;
    return h;
}
/* The server removed the object: hand back its hits, if it had any, and forget them, so a mob that
 * left view and comes back needs new hits to count. */
static inline int loot_hit_take(LootHits *t, int32_t id, LootHit *out) {
    LootHit *h = &t->slot[(uint32_t)id % LOOT_HITS];
    if (!id || h->id != id) return 0;
    *out = *h;
    *h = (LootHit){0};
    return 1;
}

/* Each object's type and last server position, from its arrival and every status after. Never
 * cleared: every id that can be hit was written when its object arrived. */
#define LOOT_TYPES 16384
typedef struct { int32_t id; uint16_t type; float pos[2]; } LootType;
static inline void loot_type_set(LootType *t, int32_t id, uint16_t type, const float pos[2]) {
    t[(uint32_t)id % LOOT_TYPES] = (LootType){id, type, {pos[0], pos[1]}};
}
static inline LootType *loot_type_find(LootType *t, int32_t id) {
    LootType *e = &t[(uint32_t)id % LOOT_TYPES];
    return id && e->id == id ? e : NULL;
}
static inline uint16_t loot_type_get(LootType *t, int32_t id) { LootType *e = loot_type_find(t, id); return e ? e->type : 0; }

/* Bags already seen on this map: the server sends a bag again each time it comes back into view.
 * shortcut: direct-mapped, so a bag 4096 ids after another on the same map can push it out and a
 * later resend of the older one counts again; a set per map if a run ever shows that. */
#define LOOT_SEEN 4096
typedef struct { int32_t id; uint32_t map; } LootSeen;
static inline int loot_bag_first(LootSeen *s, int32_t id, uint32_t map) {
    LootSeen *e = &s[(uint32_t)id % LOOT_SEEN];
    if (e->id == id && e->map == map) return 0;
    *e = (LootSeen){id, map};
    return 1;
}

/* Which kill each bag came from, as RealmHound decides it: bags wait one tick, then each goes to the
 * nearest (server position, no limit) of the hit mobs removed since the last tick, because the
 * server sends a bag one update before it removes the mob that dropped it. */
#define LOOT_PENDING 256
typedef struct { int32_t id; float pos[2]; } LootSpot;
typedef struct { LootSpot bags[2][LOOT_PENDING], killed[LOOT_PENDING]; int bag_count[2], killed_count, toggle; uint64_t overflow; } LootTicks;
static inline void loot_ticks_clear(LootTicks *t) { t->bag_count[0] = t->bag_count[1] = t->killed_count = 0; }
static inline void loot_spot_add(LootSpot *list, int *count, uint64_t *overflow, int32_t id, const float pos[2]) {
    if (*count == LOOT_PENDING) { ++*overflow; return; }
    list[(*count)++] = (LootSpot){id, {pos[0], pos[1]}};
}
static inline void loot_tick_bag(LootTicks *t, int32_t id, const float pos[2]) {
    loot_spot_add(t->bags[t->toggle], &t->bag_count[t->toggle], &t->overflow, id, pos);
}
static inline void loot_tick_killed(LootTicks *t, int32_t id, const float pos[2]) {
    loot_spot_add(t->killed, &t->killed_count, &t->overflow, id, pos);
}
/* A new tick: the bags of the tick before last, each with its kill's id (0 for none). */
static inline int loot_tick_end(LootTicks *t, LootSpot *bags, int32_t *killers) {
    t->toggle ^= 1;
    int n = t->bag_count[t->toggle];
    for (int i = 0; i < n; ++i) {
        LootSpot b = bags[i] = t->bags[t->toggle][i];
        float best = 0;
        killers[i] = 0;
        for (int k = 0; k < t->killed_count; ++k) {
            float dx = t->killed[k].pos[0] - b.pos[0], dy = t->killed[k].pos[1] - b.pos[1], d = dx * dx + dy * dy;
            if (!killers[i] || d < best) { killers[i] = t->killed[k].id; best = d; }
        }
    }
    t->bag_count[t->toggle] = t->killed_count = 0;
    return n;
}

/* Loot bag object types, as in the app's DropBag (RealmHound's ids; 17xx are boosted bags). */
static inline int loot_is_bag(uint16_t type) {
    switch (type) {
    case 1280: case 1286: case 1287: case 1288: case 1289: case 1291: case 1292: case 1294: case 1295: case 1296:
    case 1708: case 1709: case 1710: case 1722: case 1723: case 1724: case 1725: case 1726: case 1727: case 1728:
        return 1;
    default: return 0;
    }
}
/* Your own stats are kept when they change, for the loot factors among them. Not HP, MP or
 * experience (1, 4, 6), which change all fight long, and never text stats (your name). */
static inline int loot_player_stat_kept(int stat) { return stat >= 0 && stat < 256 && stat != 1 && stat != 4 && stat != 6; }
/* Container slots 0-7 are stat types 8-15; anything else on a bag is kept raw. */
static inline int loot_item_slot(int stat) { return stat >= 8 && stat <= 15 ? stat - 8 : -1; }
/* Your stat 80 has one comma-separated part per inventory slot; the first four are your equipment, the
 * only slots whose enchantments count (issue #58). Cuts the text after them. */
static inline void loot_gear_parts(char *text) {
    int parts = 0;
    for (char *c = text; *c; ++c) if (*c == ',' && ++parts == 4) { *c = 0; return; }
}

/* One TSV line per event; the app's importer parses these columns. */
static inline int loot_format(const LootEvent *e, double epoch, char *out, size_t size) {
    const int32_t *v = e->v;
    switch (e->kind) {
    case LOOT_KILL:
        return snprintf(out, size, "kill\t%.3f\t%u\t%d\t%u\t%.2f\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n",
                        epoch, e->map, e->id, e->type, e->pos[0], e->pos[1], e->pos[2], v[0], v[1], v[2], v[3],
                        loot_source_names[e->source <= LOOT_REMOVED ? e->source : LOOT_UNKNOWN], v[4], v[5]);
    case LOOT_BAG:
        return snprintf(out, size, "bag\t%.3f\t%u\t%d\t%u\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
                        epoch, e->map, e->id, e->type, e->pos[0], e->pos[1], v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    case LOOT_BAG_STAT:
        return snprintf(out, size, "bag_stat\t%.3f\t%u\t%d\t%d\t%d\t%s\n", epoch, e->map, e->id, v[0], v[1], e->text);
    case LOOT_MAP:
        return snprintf(out, size, "map\t%.3f\t%u\t%s\n", epoch, e->map, e->text);
    case LOOT_MAP_INFO:
        return snprintf(out, size, "map_info\t%.3f\t%u\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
                        epoch, e->map, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], e->text);
    case LOOT_PLAYER_STAT:
        if (e->text[0]) return snprintf(out, size, "player_stat\t%.3f\t%u\t%d\t%d\t%s\n", epoch, e->map, v[0], v[1], e->text);
        return snprintf(out, size, "player_stat\t%.3f\t%u\t%d\t%d\n", epoch, e->map, v[0], v[1]);
    case LOOT_DROP:
        return snprintf(out, size, "drop\t%.3f\t%u\t%d\t%d\n", epoch, e->map, e->id, v[0]);
    default: return 0;
    }
}
#endif
