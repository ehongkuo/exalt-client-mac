/* Bridging header for Exalt Guard.app: the shared live-state layout, its reader and the
 * settings channel. */
#include "../live_state.h"
#include <signal.h>

/* `map` is a mapping of the live file; LiveState itself stays opaque to Swift. */
static inline int guard_live_copy(const void *map, LiveData *out) {
    return live_read((const LiveState *)map, out);
}
static inline void guard_control_send(void *map, const LiveControlData *data) {
    control_write(live_control(map), data);
}
static inline int guard_control_peek(void *map, LiveControlData *out) {
    return control_read(live_control(map), out);
}
static inline int guard_process_alive(int32_t pid) {
    return pid > 0 && kill(pid, 0) == 0;
}
