#ifndef LIVE_STATE_H
#define LIVE_STATE_H
/* Live guard state shared through a memory-mapped file between the guard (x86_64, inside the
 * game under Rosetta) and Exalt Client Mac (arm64). Fixed-width fields only, so the layout is
 * identical on both. Two sequence-locked blocks:
 *   - LiveData, written by the guard after every check, read by the app;
 *   - LiveControl, written by the app when the user applies settings, read by the guard;
 *   - LiveJoin, written by the app when the user clicks Join on a party call, read by the guard.
 * A writer makes `seq` odd while writing and even when done; a reader retries if `seq`
 * changed or was odd. */
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LIVE_MAGIC 0x44475845u  /* "EXGD" */
#define LIVE_VERSION 6u
#define LIVE_SLOTS 8
#define LIVE_EVENTS 16
#define LIVE_FILE_SIZE 4096
#define LIVE_CONTROL_OFFSET 3072
#define LIVE_JOIN_OFFSET 3584

/* Result of the latest settings change sent from the app. */
enum { CONTROL_NONE = 0, CONTROL_APPLIED = 1, CONTROL_REJECTED = 2 };
/* Whether the guard can read chat: not found yet, reading, or the game's chat fields are missing. */
enum { CHAT_SEARCHING = 0, CHAT_READING = 1, CHAT_UNAVAILABLE = -1 };
/* Result of the latest Join request: sent to the game, the game threw, no party or player to
 * join with (the request expired), or this game build is not the inspected one. */
enum { JOIN_NONE = 0, JOIN_SENT = 1, JOIN_ERROR = -1, JOIN_UNAVAILABLE = -2, JOIN_UNSUPPORTED = -4 };

typedef struct {
    double epoch;                 /* wall-clock seconds */
    int32_t action, result, slot, hp, max_hp, reserved;
} LiveEvent;

typedef struct {
    int32_t pid, status, armed, potion, ceiling, nexus;
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
} LiveData;

/* Settings sent by the app. request increases with every change; 0 means none yet. */
typedef struct {
    uint32_t request;
    int32_t armed, potion, ceiling, nexus, death;
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
_Static_assert(LIVE_JOIN_OFFSET + sizeof(LiveJoin) <= LIVE_FILE_SIZE, "join block must fit");

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
#endif
