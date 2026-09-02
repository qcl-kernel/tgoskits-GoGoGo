#include "rtipc_time.h"

#include <string.h>

void rtipc_tick_extender_init(rtipc_tick_extender_t *clock)
{
    memset(clock, 0, sizeof(*clock));
}

uint64_t rtipc_tick_extender_update(rtipc_tick_extender_t *clock,
                                    uint32_t milliseconds)
{
    if (clock->initialized && milliseconds < clock->previous)
        clock->epoch += UINT64_C(1) << 32;
    clock->previous = milliseconds;
    clock->initialized = true;
    return clock->epoch | milliseconds;
}
