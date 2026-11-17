/* Drop-rate capture (issue #38): fixed events, the tables the hooks use, and the log line format.
 * Pure C, no il2cpp, so it is tested on its own. The hooks push events on the game's main thread;
 * the guard's writer thread pops them and writes loot-<pid>.tsv, which the app imports. */
#ifndef LOOT_CORE_H
#define LOOT_CORE_H
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define LOOT_FORMAT 1
enum { LOOT_KILL = 1, LOOT_BAG, LOOT_BAG_STAT, LOOT_MAP };
/* Who dealt a hit. The first three are you; only they put a mob in the damage table. */
enum { LOOT_PROJECTILE, LOOT_PROJECTILE_ALT, LOOT_ABILITY, LOOT_YOURS, LOOT_OTHER = LOOT_YOURS, LOOT_UNKNOWN };
static const char *const loot_source_names[] = {"projectile", "projectile_alt", "ability", "other", "unknown"};

typedef struct {
    uint64_t ns;
    int32_t id;
    uint32_t map;           /* map generation: object ids are only unique within one */
    uint16_t type;
    uint8_t kind, source;
    float pos[3];
    int32_t v[8];           /* kill: damage by source, max HP; bag: items; stat: type, value */
    char text[64];
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

/* Your damage per mob. Direct-mapped by object id: the server hands out ids in order, so a slot
 * is reused only when a much newer mob you also hit lands on it (counted as an eviction). */
#define LOOT_HITS 4096
typedef struct { int32_t id, killed, damage[LOOT_YOURS]; } LootHit;
typedef struct { LootHit slot[LOOT_HITS]; uint64_t evictions; } LootHits;
static inline void loot_hits_clear(LootHits *t) { memset(t->slot, 0, sizeof t->slot); }
static inline void loot_hit_add(LootHits *t, int32_t id, int source, int32_t damage) {
    if (!id || source < 0 || source >= LOOT_YOURS) return;
    LootHit *h = &t->slot[(uint32_t)id % LOOT_HITS];
    if (h->id != id) {
        if (h->id && !h->killed) ++t->evictions;
        *h = (LootHit){.id = id};
    }
    if (!h->killed && damage > 0) h->damage[source] += damage;
}
/* A kill counts once, and only for a mob you hit: the second report of a death (local and
 * server) finds it already killed. */
static inline int loot_hit_kill(LootHits *t, int32_t id, int32_t damage[LOOT_YOURS]) {
    LootHit *h = &t->slot[(uint32_t)id % LOOT_HITS];
    if (!id || h->id != id || h->killed) return 0;
    h->killed = 1;
    memcpy(damage, h->damage, sizeof h->damage);
    return 1;
}

/* Object type by id, from each new object the server sends. Never cleared: every id that can be
 * hit was written when its object arrived. */
#define LOOT_TYPES 16384
typedef struct { int32_t id; uint16_t type; } LootType;
static inline void loot_type_set(LootType *t, int32_t id, uint16_t type) { t[(uint32_t)id % LOOT_TYPES] = (LootType){id, type}; }
static inline uint16_t loot_type_get(const LootType *t, int32_t id) {
    const LootType *e = &t[(uint32_t)id % LOOT_TYPES];
    return e->id == id ? e->type : 0;
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
/* Container slots 0-7 are stat types 8-15; anything else on a bag is kept raw. */
static inline int loot_item_slot(int stat) { return stat >= 8 && stat <= 15 ? stat - 8 : -1; }

/* One TSV line per event; the app's importer parses these columns. */
static inline int loot_format(const LootEvent *e, double epoch, char *out, size_t size) {
    const int32_t *v = e->v;
    switch (e->kind) {
    case LOOT_KILL:
        return snprintf(out, size, "kill\t%.3f\t%u\t%d\t%u\t%.2f\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%s\n",
                        epoch, e->map, e->id, e->type, e->pos[0], e->pos[1], e->pos[2], v[0], v[1], v[2], v[3],
                        loot_source_names[e->source <= LOOT_UNKNOWN ? e->source : LOOT_UNKNOWN]);
    case LOOT_BAG:
        return snprintf(out, size, "bag\t%.3f\t%u\t%d\t%u\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
                        epoch, e->map, e->id, e->type, e->pos[0], e->pos[1], v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    case LOOT_BAG_STAT:
        return snprintf(out, size, "bag_stat\t%.3f\t%u\t%d\t%d\t%d\t%s\n", epoch, e->map, e->id, v[0], v[1], e->text);
    case LOOT_MAP:
        return snprintf(out, size, "map\t%.3f\t%u\t%s\n", epoch, e->map, e->text);
    default: return 0;
    }
}
#endif
