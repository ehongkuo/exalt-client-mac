#ifndef TIMING_CORE_H
#define TIMING_CORE_H
/* Guard copy of exalt-timing/timing_core.h: Record adds guard columns. */
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#define RING_CAPACITY 4096

typedef struct {
    uint64_t sequence, monotonic_ns, gap_ns, work_ns, detection_ns, dropped;
    double epoch;
    float hp, xyz[3], previous_hp;
    int status, decreased;
    int player_hp, player_max, action, result, slot;
    float bar_aux;
} Record;
typedef struct { Record entries[RING_CAPACITY]; _Atomic uint64_t head, tail; } SampleRing;
static inline int ring_push(SampleRing *q, Record value) {
    uint64_t head = atomic_load_explicit(&q->head, memory_order_relaxed);
    if (head - atomic_load_explicit(&q->tail, memory_order_acquire) == RING_CAPACITY) return 0;
    q->entries[head % RING_CAPACITY] = value;
    atomic_store_explicit(&q->head, head + 1, memory_order_release);
    return 1;
}
static inline int ring_pop(SampleRing *q, Record *value) {
    uint64_t tail = atomic_load_explicit(&q->tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&q->head, memory_order_acquire)) return 0;
    *value = q->entries[tail % RING_CAPACITY];
    atomic_store_explicit(&q->tail, tail + 1, memory_order_release);
    return 1;
}
/* Main-thread cumulative counters; no per-check storage or cross-thread access.
 * Stage maxima are sampled, so they cannot explain every observed stall. */
typedef struct {
    uint64_t checks, valid_checks, gaps_20ms, gaps_100ms, valid_gaps_100ms;
    uint64_t max_gap_ns, max_valid_gap_ns, max_work_ns, stage_samples;
    uint64_t lookup_ns, guard_ns, services_ns, publication_ns;
} LatencyStats;
static inline void latency_observe(LatencyStats *s, uint64_t gap, uint64_t work, int valid) {
    ++s->checks;
    if (gap > s->max_gap_ns) s->max_gap_ns = gap;
    if (work > s->max_work_ns) s->max_work_ns = work;
    if (gap >= 20000000ULL) ++s->gaps_20ms;
    if (gap >= 100000000ULL) ++s->gaps_100ms;
    if (valid) {
        ++s->valid_checks;
        if (gap > s->max_valid_gap_ns) s->max_valid_gap_ns = gap;
        if (gap >= 100000000ULL) ++s->valid_gaps_100ms;
    }
}
static inline void latency_stage_max(uint64_t *maximum, uint64_t begin, uint64_t end) {
    if (end >= begin && end - begin > *maximum) *maximum = end - begin;
}
typedef struct { uintptr_t identity; float hp; uint64_t time; int valid; } Detector;
static inline int detect(Detector *d, uintptr_t identity, float hp, uint64_t now, int valid) {
    valid = valid && identity && isfinite(hp) && hp >= 0;
    int decreased = valid && d->valid && d->identity == identity && now > d->time &&
                    now - d->time <= 250000000 && hp < d->hp;
    *d = (Detector){identity, hp, now, valid};
    return decreased;
}
#endif
