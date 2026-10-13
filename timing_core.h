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
typedef struct { uintptr_t identity; float hp; uint64_t time; int valid; } Detector;
static inline int detect(Detector *d, uintptr_t identity, float hp, uint64_t now, int valid) {
    valid = valid && identity && isfinite(hp) && hp >= 0;
    int decreased = valid && d->valid && d->identity == identity && now > d->time &&
                    now - d->time <= 250000000 && hp < d->hp;
    *d = (Detector){identity, hp, now, valid};
    return decreased;
}
#endif
