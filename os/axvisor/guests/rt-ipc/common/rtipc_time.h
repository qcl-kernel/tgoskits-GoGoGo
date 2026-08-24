#ifndef RTIPC_TIME_H
#define RTIPC_TIME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint64_t epoch;
    uint32_t previous;
    bool initialized;
} rtipc_tick_extender_t;

void rtipc_tick_extender_init(rtipc_tick_extender_t *clock);
uint64_t rtipc_tick_extender_update(rtipc_tick_extender_t *clock,
                                    uint32_t milliseconds);

#endif
