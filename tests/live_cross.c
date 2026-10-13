/* Cross-process, cross-architecture check: `live_cross write FILE` (built x86_64, runs under
 * Rosetta) publishes into a mapped file while `live_cross read FILE` (arm64) verifies every read. */
#include "../guard/live_state.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    assert(argc == 3);
    int writing = !strcmp(argv[1], "write");
    int fd = open(argv[2], writing ? O_RDWR | O_CREAT : O_RDONLY, 0600);
    assert(fd >= 0);
    if (writing) assert(!ftruncate(fd, LIVE_FILE_SIZE));
    LiveState *state = mmap(NULL, LIVE_FILE_SIZE, writing ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, 0);
    assert(state != MAP_FAILED);
    if (writing) {
        state->magic = LIVE_MAGIC; state->version = LIVE_VERSION;
        LiveData d = {0};
        double end = now() + 1.5;  /* overlap with the reader for 1.5 s, then mark done */
        for (int32_t i = 1; now() < end; ++i) {
            d.hp = d.max_hp = i; d.ticks = (uint64_t)i;
            for (int s = 0; s < LIVE_SLOTS; ++s) d.stacks[s] = i;
            live_publish(state, &d);
        }
        d.status = 1;
        live_publish(state, &d);
        return 0;
    }
    unsigned reads = 0, changes = 0; int32_t last = 0;
    for (;;) {
        LiveData d;
        if (!live_read(state, &d)) continue;
        assert(d.max_hp == d.hp && d.ticks == (uint64_t)d.hp && d.hp >= last);
        for (int s = 0; s < LIVE_SLOTS; ++s) assert(d.stacks[s] == d.hp);
        if (d.hp != last) ++changes;
        last = d.hp; ++reads;
        if (d.status == 1) break;
    }
    assert(changes > 1000);
    printf("cross-architecture: %u reads, %u distinct records seen, all consistent\n", reads, changes);
}
