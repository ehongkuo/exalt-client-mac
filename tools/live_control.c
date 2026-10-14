/* Sends a settings change or a Join click to a running guard, exactly as the app does.
 * Usage: live_control FILE REQUEST ARMED POTION CEILING NEXUS
 *        live_control FILE join REQUEST NAME */
#include "../guard/live_state.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int join = argc == 5 && !strcmp(argv[2], "join");
    if (argc != 7 && argc != 8 && !join) { fprintf(stderr, "usage: live_control FILE REQUEST ARMED POTION CEILING NEXUS | FILE join REQUEST NAME\n"); return 2; }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    void *file = mmap(NULL, LIVE_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (file == MAP_FAILED) { perror("mmap"); return 1; }
    if (join) {
        LiveJoinData j = {.request = (uint32_t)strtoul(argv[3], NULL, 10)};
        snprintf(j.name, sizeof j.name, "%s", argv[4]);
        join_write(live_join(file), &j);
        return 0;
    }
    LiveControlData d = {.request = (uint32_t)strtoul(argv[2], NULL, 10), .armed = atoi(argv[3]),
                         .potion = atoi(argv[4]), .ceiling = atoi(argv[5]), .nexus = atoi(argv[6]), .death = argc == 8 ? atoi(argv[7]) : 0};
    control_write(live_control(file), &d);
    return 0;
}
