/* Prints a guard live-state file as key=value lines (tests and troubleshooting). */
#include "live_state.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: live_dump FILE\n"); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    const LiveState *state = mmap(NULL, LIVE_FILE_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    LiveData d;
    if (state == MAP_FAILED || !live_read(state, &d)) { fprintf(stderr, "no live state\n"); return 1; }
    printf("pid=%d\nstatus=%d\narmed=%d\npotion=%d\nceiling=%d\nnexus=%d\n", d.pid, d.status, d.armed, d.potion, d.ceiling, d.nexus);
    printf("map=%s\nmap_known=%d\nin_nexus=%d\ndrinking=%d\nsettled=%d\n", d.map, d.map_known, d.in_nexus, d.drinking, d.settled);
    printf("hp=%d\nmax_hp=%d\nhud_hp=%g\nslot_count=%d\nnext_slot=%d\n", d.hp, d.max_hp, d.hud_hp, d.slot_count, d.next_slot);
    for (int i = 0; i < d.slot_count && i < LIVE_SLOTS; ++i) printf("slot%d=%d/%d\n", i, d.stacks[i], d.cooldown[i]);
    printf("ticks=%llu\nsample_epoch=%.6f\nlast_gap_us=%u\nmax_gap_us=%u\nwork_ns=%u\nevent_count=%u\n",
           (unsigned long long)d.ticks, d.sample_epoch, d.last_gap_us, d.max_gap_us, d.work_ns, d.event_count);
    printf("control_request=%u\ncontrol_result=%d\n", d.control_request, d.control_result);
    printf("potions_sent=%u\nnexus_sent=%u\npotions_dry=%u\nnexus_dry=%u\n", d.potions_sent, d.nexus_sent, d.potions_dry, d.nexus_dry);
    printf("lowest_hp=%d\nlowest_max_hp=%d\nlowest_epoch=%.6f\nsession_start_epoch=%.6f\nlog_name=%s\n",
           d.lowest_hp, d.lowest_max_hp, d.lowest_epoch, d.session_start_epoch, d.log_name);
    unsigned n = d.event_count < LIVE_EVENTS ? d.event_count : LIVE_EVENTS;
    for (unsigned k = 0; k < n; ++k) {
        const LiveEvent *e = &d.events[(d.event_count - n + k) % LIVE_EVENTS];
        printf("event=%.6f,%d,%d,%d,%d,%d\n", e->epoch, e->action, e->result, e->slot, e->hp, e->max_hp);
    }
    return 0;
}
