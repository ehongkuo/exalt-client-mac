/* Synthetic live-state writer for UI checks: a scripted beach fight with drinks and a Nexus.
 * Usage: ui_fixture FILE SECONDS. Never touches the game. */
#include "../guard/live_state.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static uint64_t mono(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec; }
static double wall(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int fd = open(argv[1], O_RDWR | O_CREAT, 0600);
    if (fd < 0 || ftruncate(fd, LIVE_FILE_SIZE)) return 1;
    LiveState *s = mmap(NULL, LIVE_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    s->magic = LIVE_MAGIC; s->version = LIVE_VERSION;
    LiveData d = {.pid = getpid(), .armed = 1, .potion = 50, .ceiling = 80, .nexus = 25,
                  .map_known = 1, .settled = 1, .max_hp = 235, .slot_count = 3,
                  .chat_status = CHAT_READING};
    int death_view = getenv("GUARD_UI_DEATH") != NULL;
    if (death_view) { d.death = 1; d.death_status = 1; }
    snprintf(d.map, sizeof d.map, "Realm of the Mad God");
    d.session_start_epoch = wall() - 754;  /* pretend the session started 12.5 minutes ago */
    snprintf(d.log_name, sizeof d.log_name, "guard-%d.tsv", getpid());
    int stacks[3] = {1, 4, 2};
    uint64_t start = mono(), previous = start, window = start;
    double seconds = atof(argv[2]);
    int phase = -1;
    while (mono() - start < (uint64_t)(seconds * 1e9)) {
        uint64_t now = mono();
        double t = (now - start) / 1e9;
        int p = (int)(t / 1.5) % 6;  /* cycle: full, hit, drink, drink, low (Nexus), Nexus map */
        if (p != phase) {
            phase = p;
            int hp[] = {235, 113, 160, 200, 40, 235};
            d.hp = hp[p]; d.hud_hp = (float)d.hp;
            if (p != 5 && (!d.lowest_max_hp || d.hp * d.lowest_max_hp < d.lowest_hp * d.max_hp)) {
                d.lowest_hp = d.hp; d.lowest_max_hp = d.max_hp; d.lowest_epoch = wall();
            }
            d.in_nexus = p == 5; snprintf(d.map, sizeof d.map, p == 5 ? "Nexus" : "Realm of the Mad God");
            d.drinking = p == 1 || p == 2 || p == 3;
            if (p == 3) {   /* a party call each cycle */
                ++d.party_calls; d.party_call_epoch = wall();
                snprintf(d.party_caller, sizeof d.party_caller, "Lyra");
                snprintf(d.party_text, sizeof d.party_text, "j cit");
            }
            int action = p == 1 || p == 2 ? 1 : p == 4 ? (death_view ? 3 : 2) : 0;
            if (action) {
                int slot = stacks[0] ? 0 : stacks[1] ? 1 : 2;
                if (action == 1) { --stacks[slot]; ++d.potions_sent; } else ++d.nexus_sent;
                d.events[d.event_count % LIVE_EVENTS] = (LiveEvent){.epoch = wall(), .action = action, .result = 1,
                    .slot = action == 1 ? slot : -1, .hp = d.hp, .max_hp = d.max_hp};
                ++d.event_count;
            }
        }
        for (int i = 0; i < 3; ++i) { d.stacks[i] = stacks[i]; d.cooldown[i] = (phase == 1 || phase == 2) && i == (stacks[0] ? 0 : 1); }
        d.next_slot = stacks[0] ? 0 : stacks[1] ? 1 : stacks[2] ? 2 : -1;
        uint32_t gap = (uint32_t)((now - previous) / 1000); previous = now;
        if (now - window > 1000000000ULL) { window = now; d.max_gap_us = 0; }
        if (gap > d.max_gap_us) d.max_gap_us = gap;
        d.last_gap_us = gap; d.work_ns = 3100; d.ticks++; d.sample_ns = now; d.sample_epoch = wall();
        live_publish(s, &d);
        usleep(1000);
    }
    return 0;
}
