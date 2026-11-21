#ifndef LIVE_STATE_H
#define LIVE_STATE_H
/* Live guard state shared through a memory-mapped file between the guard (x86_64, inside the
 * game under Rosetta) and Exalt Client Mac (arm64). Fixed-width fields only, so the layout is
 * identical on both. Two sequence-locked blocks:
 *   - LiveData, written by the guard after every check, read by the app;
 *   - LiveControl, written by the app when the user applies settings, read by the guard;
 *   - LiveJoin, written by the app when the user clicks Join on a party call, read by the guard;
 *   - LiveBags, written by the guard as each bag appears, read by the app for drop alerts (issue #75);
 *   - LivePortals, written by the guard as it links a portal to a kill, read by the app for portal alerts (issue #74).
 * A writer makes `seq` odd while writing and even when done; a reader retries if `seq`
 * changed or was odd. */
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LIVE_MAGIC 0x44475845u  /* "EXGD" */
#define LIVE_VERSION 8u
#define LIVE_SLOTS 8
#define LIVE_EVENTS 16
#define LIVE_FILE_SIZE 8192
#define LIVE_CONTROL_OFFSET 3072
#define LIVE_JOIN_OFFSET 3584
#define LIVE_BAGS_OFFSET 4096
#define LIVE_BAGS 12
#define LIVE_PORTALS_OFFSET 7168   /* added without a version bump: an older reader never maps it */
#define LIVE_PORTALS 8
/* Posted (notify_post) after each bag or portal, so the app wakes at once instead of on its next timer tick. */
#define LIVE_BAG_NOTIFICATION "local.exalt.clientmac.bag"

/* Result of the latest settings change sent from the app. */
enum { CONTROL_NONE = 0, CONTROL_APPLIED = 1, CONTROL_REJECTED = 2 };
/* Whether the guard can read chat: not found yet, reading, or the game's chat fields are missing. */
enum { CHAT_SEARCHING = 0, CHAT_READING = 1, CHAT_UNAVAILABLE = -1 };
/* Result of the latest Join request: sent to the game, the game threw, no party or player to
 * join with (the request expired), or this game build is not the inspected one. */
enum { JOIN_NONE = 0, JOIN_SENT = 1, JOIN_ERROR = -1, JOIN_UNAVAILABLE = -2, JOIN_UNSUPPORTED = -4 };
/* Why the guard ended the game at startup: a check failed, so playing on would mean playing
 * without the protection the user started it for. */
enum { REFUSAL_NONE = 0, REFUSAL_BUILD = 1, REFUSAL_GUARD = 2, REFUSAL_MAP = 3, REFUSAL_CHAT = 4,
       REFUSAL_JOIN = 5, REFUSAL_DEATH = 6, REFUSAL_TIMEOUT = 7 };

typedef struct {
    double epoch;                 /* wall-clock seconds */
    int32_t action, result, slot, hp, max_hp, reserved;
} LiveEvent;

typedef struct {
    int32_t pid, status, armed, potion, ceiling, nexus; /* nexus is a reserved legacy slot, always zero */
    int32_t map_known, in_nexus, drinking, settled;
    int32_t hp, max_hp;
    float hud_hp;
    int32_t slot_count, next_slot;
    int32_t stacks[LIVE_SLOTS];
    int32_t cooldown[LIVE_SLOTS];
    char map[48];
    uint64_t sample_ns;           /* CLOCK_MONOTONIC of the latest check */
    double sample_epoch;
    uint64_t ticks;               /* checks since the guard loaded */
    uint32_t last_gap_us, max_gap_us;  /* gap before the latest check; worst in the last second */
    uint32_t work_ns;             /* guard work in the latest check */
    uint32_t event_count;         /* total events; the newest is events[(event_count - 1) % LIVE_EVENTS] */
    LiveEvent events[LIVE_EVENTS];
    uint32_t control_request;     /* request id of the latest settings change the guard handled */
    int32_t control_result;       /* CONTROL_* for that request */
    /* Session summary, kept by the guard so nothing between screen frames is missed. */
    double session_start_epoch;
    uint32_t potions_sent, nexus_sent;       /* calls the game accepted */
    uint32_t potions_dry, nexus_dry;         /* decisions made in dry run */
    int32_t lowest_hp, lowest_max_hp;        /* closest call outside the Nexus; lowest_max_hp 0 = none yet */
    double lowest_epoch;
    char log_name[64];                       /* this session's log file, in the logs folder */
    /* Party chat calls ("j", "join") from other players; the app alerts when party_calls grows. */
    int32_t chat_status;                     /* CHAT_* below */
    uint32_t party_calls;
    double party_call_epoch;
    char party_caller[32];                   /* sender name, UTF-8 */
    char party_text[96];                     /* message text, UTF-8, cut to fit */
    uint32_t join_request;                   /* the latest Join request the guard handled */
    int32_t join_result;                     /* JOIN_* for it */
    char join_name[32];
    int32_t death, death_status, death_blocking; /* setting, hooks: 0 waiting / 1 ready / -1 refused, escape latch */
    int64_t death_pending, death_predicted;
    int32_t refusal;                         /* REFUSAL_* above; nonzero once the guard ended the game */
    char refusal_detail[60];                 /* the failed check, for the log and the app */
} LiveData;

/* Settings sent by the app. request increases with every change; 0 means none yet. */
typedef struct {
    uint32_t request;
    int32_t armed, potion, ceiling, nexus, death; /* legacy nexus values are discarded */
} LiveControlData;

/* A Join click: the party member to join, by the plain name shown in the game. request
 * increases with every click; 0 means none yet. */
typedef struct {
    uint32_t request;
    char name[32];
} LiveJoinData;

typedef struct {
    _Atomic uint32_t seq;
    uint32_t reserved;
    LiveJoinData data;
} LiveJoin;

/* A bag as its object arrives: its first status holds the contents and their enchantments. */
typedef struct {
    uint64_t ns;                  /* CLOCK_MONOTONIC when the guard saw it */
    double epoch;
    int32_t id, type;
    int32_t items[8];             /* item type per slot, -1 empty */
    char enchants[192];           /* stat 80: one base64url part per slot, comma-separated */
} LiveBag;
/* count: bags since the guard loaded; the newest is bags[(count - 1) % LIVE_BAGS]. */
typedef struct {
    uint32_t count, reserved;
    LiveBag bags[LIVE_BAGS];
} LiveBagsData;
typedef struct {
    _Atomic uint32_t seq;
    uint32_t reserved;
    LiveBagsData data;
} LiveBags;

/* A portal the guard linked to a kill, one tick after it appeared, with the kill's facts; the app decides whether it
 * counts as the kill's drop. */
typedef struct {
    uint64_t ns;                  /* CLOCK_MONOTONIC when the guard linked it */
    double epoch;
    int32_t id, type;             /* the portal object */
    float pos[2];
    int32_t mob;                  /* the kill's object type */
    float mob_pos[2];
    int32_t damage;               /* your damage to the mob */
    int32_t since_hit_ms;         /* from your last hit to its removal */
    int32_t reserved;
} LivePortal;
/* count: portals since the guard loaded; the newest is portals[(count - 1) % LIVE_PORTALS]. */
typedef struct {
    uint32_t count, reserved;
    LivePortal portals[LIVE_PORTALS];
} LivePortalsData;
typedef struct {
    _Atomic uint32_t seq;
    uint32_t reserved;
    LivePortalsData data;
} LivePortals;

typedef struct {
    uint32_t magic, version;
    _Atomic uint32_t seq;
    uint32_t reserved;
    LiveData data;
} LiveState;

typedef struct {
    _Atomic uint32_t seq;
    uint32_t reserved;
    LiveControlData data;
} LiveControl;

_Static_assert(sizeof(LiveState) <= LIVE_CONTROL_OFFSET, "live state must end before the control block");
_Static_assert(LIVE_CONTROL_OFFSET + sizeof(LiveControl) <= LIVE_JOIN_OFFSET, "control block must end before the join block");
_Static_assert(LIVE_JOIN_OFFSET + sizeof(LiveJoin) <= LIVE_BAGS_OFFSET, "join block must end before the bags");
_Static_assert(LIVE_BAGS_OFFSET + sizeof(LiveBags) <= LIVE_PORTALS_OFFSET, "bags block must end before the portals");
_Static_assert(LIVE_PORTALS_OFFSET + sizeof(LivePortals) <= LIVE_FILE_SIZE, "portals block must fit");

static inline void seqlock_write(_Atomic uint32_t *seq, void *dst, const void *src, size_t size) {
    uint32_t value = atomic_load_explicit(seq, memory_order_relaxed);
    atomic_store_explicit(seq, value + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    memcpy(dst, src, size);
    atomic_store_explicit(seq, value + 2, memory_order_release);
}
/* Returns the even sequence number of a consistent copy, or 0 if none could be taken. */
static inline uint32_t seqlock_read(const _Atomic uint32_t *seq, void *dst, const void *src, size_t size) {
    for (int attempt = 0; attempt < 64; ++attempt) {
        uint32_t before = atomic_load_explicit((_Atomic uint32_t *)seq, memory_order_acquire);
        if (before & 1) continue;
        memcpy(dst, src, size);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit((_Atomic uint32_t *)seq, memory_order_relaxed) == before) return before ? before : 2;
    }
    return 0;
}

static inline LiveControl *live_control(void *file) { return (LiveControl *)((char *)file + LIVE_CONTROL_OFFSET); }
static inline LiveJoin *live_join(void *file) { return (LiveJoin *)((char *)file + LIVE_JOIN_OFFSET); }
static inline LiveBags *live_bags(void *file) { return (LiveBags *)((char *)file + LIVE_BAGS_OFFSET); }
static inline LivePortals *live_portals(void *file) { return (LivePortals *)((char *)file + LIVE_PORTALS_OFFSET); }

static inline void live_publish(LiveState *state, const LiveData *data) {
    seqlock_write(&state->seq, &state->data, data, sizeof *data);
}
/* Returns 1 with a consistent copy, 0 if the writer kept it busy or the header is wrong. */
static inline int live_read(const LiveState *state, LiveData *out) {
    if (state->magic != LIVE_MAGIC || state->version != LIVE_VERSION) return 0;
    return seqlock_read(&state->seq, out, (const void *)&state->data, sizeof *out) != 0;
}
static inline void control_write(LiveControl *control, const LiveControlData *data) {
    seqlock_write(&control->seq, &control->data, data, sizeof *data);
}
/* Returns 1 with a consistent copy. */
static inline int control_read(const LiveControl *control, LiveControlData *out) {
    return seqlock_read(&control->seq, out, (const void *)&control->data, sizeof *out) != 0;
}
static inline void join_write(LiveJoin *join, const LiveJoinData *data) {
    seqlock_write(&join->seq, &join->data, data, sizeof *data);
}
static inline int join_read(const LiveJoin *join, LiveJoinData *out) {
    return seqlock_read(&join->seq, out, (const void *)&join->data, sizeof *out) != 0;
}
static inline void bags_write(LiveBags *bags, const LiveBagsData *data) {
    seqlock_write(&bags->seq, &bags->data, data, sizeof *data);
}
static inline int bags_read(const LiveBags *bags, LiveBagsData *out) {
    return seqlock_read(&bags->seq, out, (const void *)&bags->data, sizeof *out) != 0;
}
static inline void portals_write(LivePortals *portals, const LivePortalsData *data) {
    seqlock_write(&portals->seq, &portals->data, data, sizeof *data);
}
static inline int portals_read(const LivePortals *portals, LivePortalsData *out) {
    return seqlock_read(&portals->seq, out, (const void *)&portals->data, sizeof *out) != 0;
}
#endif
