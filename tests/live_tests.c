/* Sequence-lock test: a writer publishes records whose fields all carry the same number;
 * a concurrent reader must never see a mix of two records. */
#include "../guard/live_state.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static LiveState state = {.magic = LIVE_MAGIC, .version = LIVE_VERSION};
static _Atomic int done;
static unsigned char file[LIVE_FILE_SIZE];
static _Atomic int control_done;

/* The app side: sends settings changes whose four values all equal the request id. */
static void *app(void *unused) {
    (void)unused;
    LiveControl *control = live_control(file);
    for (uint32_t i = 1; i <= 1000000; ++i) {
        LiveControlData d = {.request = i, .armed = (int32_t)i, .potion = (int32_t)i, .ceiling = (int32_t)i, .nexus = (int32_t)i, .death = (int32_t)i};
        control_write(control, &d);
    }
    atomic_store(&control_done, 1);
    return NULL;
}

static void *writer(void *unused) {
    (void)unused;
    LiveData d = {0};
    for (int32_t i = 1; i <= 2000000; ++i) {
        d.hp = d.max_hp = d.status = d.death = d.death_status = d.death_blocking = i;
        d.death_pending = i; d.death_predicted = -(int64_t)i;
        d.ticks = (uint64_t)i;
        for (int s = 0; s < LIVE_SLOTS; ++s) d.stacks[s] = d.cooldown[s] = i;
        d.events[LIVE_EVENTS - 1].hp = i;
        live_publish(&state, &d);
    }
    atomic_store(&done, 1);
    return NULL;
}

int main(void) {
    LiveData empty;
    LiveState wrong = {.magic = 1, .version = LIVE_VERSION};
    assert(!live_read(&wrong, &empty));
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, writer, NULL));
    unsigned reads = 0, last = 0;
    while (!atomic_load(&done)) {
        LiveData d;
        if (!live_read(&state, &d)) continue;
        ++reads;
        int32_t v = d.hp;
        assert(d.death == v && d.death_status == v && d.death_blocking == v && d.death_pending == v && d.death_predicted == -(int64_t)v);
        assert(d.max_hp == v && d.status == v && d.ticks == (uint64_t)v && d.events[LIVE_EVENTS - 1].hp == v);
        for (int s = 0; s < LIVE_SLOTS; ++s) assert(d.stacks[s] == v && d.cooldown[s] == v);
        assert((unsigned)v >= last);   /* never goes backwards */
        last = (unsigned)v;
    }
    assert(!pthread_join(thread, NULL));
    /* Control block: the guard side never sees a half-written settings change. */
    LiveControlData none;
    assert(control_read(live_control(file), &none) && none.request == 0);
    assert(!pthread_create(&thread, NULL, app, NULL));
    unsigned control_reads = 0; uint32_t last_request = 0;
    while (!atomic_load(&control_done)) {
        LiveControlData c;
        if (!control_read(live_control(file), &c)) continue;
        assert(c.armed == (int32_t)c.request && c.potion == (int32_t)c.request &&
               c.ceiling == (int32_t)c.request && c.nexus == (int32_t)c.request && c.death == (int32_t)c.request);
        assert(c.request >= last_request);
        last_request = c.request; ++control_reads;
    }
    assert(!pthread_join(thread, NULL));
    printf("Control block: %u consistent concurrent reads\n", control_reads);
    LiveData final;
    assert(live_read(&state, &final) && final.hp == 2000000);
    printf("Live state tests passed (%u consistent concurrent reads)\n", reads);
}
