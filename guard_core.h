#ifndef GUARD_CORE_H
#define GUARD_CORE_H
/* Pure decision logic for the HP guard: no game or runtime calls here. */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int armed;             /* 0 = dry run: decide and log, never call the game */
    int potion, nexus;     /* thresholds in percent of max HP; 0 disables */
    int ceiling;           /* once drinking, keep going until HP is over this percent; 0 = stop above potion */
    uint64_t min_interval_ns;  /* never two potions closer than this */
    uint64_t heal_timeout_ns;  /* after a potion, wait this long for the heal to show before another */
    uint64_t settle_ns;    /* max HP must be unchanged this long before acting */
} GuardConfig;

typedef enum { GUARD_NONE, GUARD_POTION, GUARD_NEXUS } GuardAction;

typedef struct {
    uintptr_t identity;
    uint64_t last_potion, max_since;
    float max_seen, last_potion_hp;  /* HP when the last potion was drunk */
    int potion_used, nexus_sent, drinking, heal_pending;
} GuardState;

static inline void guard_defaults(GuardConfig *c) {
    *c = (GuardConfig){.armed = 0, .potion = 50, .nexus = 25, .ceiling = 0, .min_interval_ns = 250000000ULL,
                        .heal_timeout_ns = 1000000000ULL,
                        .settle_ns = 500000000ULL};
}

static inline int guard_number(const char *text, size_t length, int low, int high, int *out) {
    if (!length || length > 3) return 0;
    int value = 0;
    for (size_t i = 0; i < length; ++i) {
        if (text[i] < '0' || text[i] > '9') return 0;
        value = value * 10 + (text[i] - '0');
    }
    if (value < low || value > high) return 0;
    *out = value;
    return 1;
}

/* The rules for the user-facing settings, shared by startup settings and live changes. */
static inline int guard_valid(int armed, int potion, int ceiling, int nexus) {
    if (armed < 0 || armed > 1 || potion < 0 || potion > 100 || nexus < 0 || nexus > 100 ||
        ceiling < 0 || ceiling > 100) return 0;
    if (potion && nexus && nexus >= potion) return 0;
    if (ceiling && (!potion || ceiling <= potion)) return 0;
    return 1;
}

/* Parses "armed=1,potion=50,nexus=25". On any error the config is reset
 * to defaults (dry run) and 0 is returned. */
static inline int guard_parse(GuardConfig *c, const char *text) {
    guard_defaults(c);
    if (!text) return 1;
    GuardConfig parsed = *c;
    while (*text) {
        const char *end = strchr(text, ','), *equals = strchr(text, '=');
        size_t length = end ? (size_t)(end - text) : strlen(text);
        if (!equals || (size_t)(equals - text) >= length) goto invalid;
        size_t key = (size_t)(equals - text);
        const char *value = equals + 1;
        size_t value_length = length - key - 1;
        int ok = 0;
        if (key == 5 && !strncmp(text, "armed", 5)) ok = guard_number(value, value_length, 0, 1, &parsed.armed);
        else if (key == 6 && !strncmp(text, "potion", 6)) ok = guard_number(value, value_length, 0, 100, &parsed.potion);
        else if (key == 5 && !strncmp(text, "nexus", 5)) ok = guard_number(value, value_length, 0, 100, &parsed.nexus);
        else if (key == 7 && !strncmp(text, "ceiling", 7)) ok = guard_number(value, value_length, 0, 100, &parsed.ceiling);
        if (!ok) goto invalid;
        text += length + (end ? 1 : 0);
    }
    if (!guard_valid(parsed.armed, parsed.potion, parsed.ceiling, parsed.nexus)) goto invalid;
    *c = parsed;
    return 1;
invalid:
    guard_defaults(c);
    return 0;
}

/* Quickslots are used in order: the first with potions left, so the first slot is
 * emptied before the second is touched. Returns -1 when every slot is empty. */
static inline int guard_pick_slot(const int *counts, int n) {
    for (int i = 0; i < n; ++i)
        if (counts[i] > 0) return i;
    return -1;
}

/* Applies settings changed while the guard runs. Returns 0 and changes nothing if invalid.
 * A threshold change ends any drinking run; the next crossing of the new trigger starts one. */
static inline int guard_apply(GuardConfig *c, GuardState *s, int armed, int potion, int ceiling, int nexus) {
    if (!guard_valid(armed, potion, ceiling, nexus)) return 0;
    c->armed = armed; c->potion = potion; c->ceiling = ceiling; c->nexus = nexus;
    s->drinking = 0;
    return 1;
}

/* in_nexus: the current map is known to be the Nexus, where the guard never acts.
 * potion_ready: a quickslot has potions and its cooldown flag is clear.
 * A new player object, or a change in max HP (new map, equipment swap), starts a settle
 * period: brand-new player objects briefly carry stale HP and a placeholder max HP.
 * Drinking starts when HP is at or below `potion` and continues, as fast as the game allows,
 * until HP is over `ceiling` (or over `potion` when no ceiling is set).
 * Pacing: HP only updates when the server reports it (about every 200 ms), and the game has no
 * client-side potion cooldown, so after each potion the guard waits until HP rises above the
 * drink-time HP (the heal has shown) or heal_timeout passes, and never drinks twice within
 * min_interval. Without this it drinks again on stale HP and empties the quickslots. */
static inline GuardAction guard_decide(GuardState *s, const GuardConfig *c, uintptr_t identity,
                                       float hp, float max, uint64_t now, int valid, int in_nexus,
                                       int potion_ready) {
    if (identity != s->identity) *s = (GuardState){.identity = identity, .max_seen = NAN};
    if (!valid || !identity || !isfinite(hp) || !isfinite(max) || hp <= 0 || max <= 0 || hp > max)
        return GUARD_NONE;
    if (!(max == s->max_seen)) { s->max_seen = max; s->max_since = now; }
    if (in_nexus) { s->drinking = 0; return GUARD_NONE; }
    if (now - s->max_since < c->settle_ns || s->nexus_sent) return GUARD_NONE;
    float percent = hp * 100.0f / max;
    if (c->nexus && percent <= (float)c->nexus) {
        s->nexus_sent = 1;
        s->drinking = 0;
        return GUARD_NEXUS;
    }
    if (c->potion && percent <= (float)c->potion && !s->drinking) {
        s->drinking = 1;
        s->heal_pending = 0;   /* a new run does not wait on the previous run's potion */
    }
    if (s->drinking && percent > (float)(c->ceiling ? c->ceiling : c->potion)) s->drinking = 0;
    if (!s->drinking || !potion_ready) return GUARD_NONE;
    uint64_t since = now - s->last_potion;
    if (s->potion_used && since < c->min_interval_ns) return GUARD_NONE;
    if (s->heal_pending && !(hp > s->last_potion_hp) && since < c->heal_timeout_ns) return GUARD_NONE;
    s->potion_used = 1;
    s->heal_pending = 1;
    s->last_potion = now;
    s->last_potion_hp = hp;
    return GUARD_POTION;
    return GUARD_NONE;
}
#endif
