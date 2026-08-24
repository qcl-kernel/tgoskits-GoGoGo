#ifndef RTIPC_FAULT_H
#define RTIPC_FAULT_H

#include "rt_ipc.h"

typedef enum {
    RTIPC_FAULT_PROFILE_NONE = 0,
    RTIPC_FAULT_PROFILE_RELIABILITY,
} rtipc_fault_profile_t;

typedef enum {
    RTIPC_FAULT_ACTION_PASS = 0,
    RTIPC_FAULT_ACTION_DROP,
    RTIPC_FAULT_ACTION_DUPLICATE,
    RTIPC_FAULT_ACTION_HOLD,
    RTIPC_FAULT_ACTION_RELEASE_REVERSED,
} rtipc_fault_action_t;

typedef struct {
    rtipc_fault_profile_t profile;
    bool drop_done;
    bool duplicate_done;
    bool reorder_done;
    bool reorder_held;
    uint32_t held_sequence;
    uint8_t held_packet[RTIPC_MAX_PACKET];
    size_t held_length;
} rtipc_fault_context_t;

int rtipc_fault_profile_parse(const char *text,
                              rtipc_fault_profile_t *profile);
const char *rtipc_fault_profile_name(rtipc_fault_profile_t profile);
bool rtipc_fault_should_force_disconnect(rtipc_fault_profile_t profile,
                                         int payload_size,
                                         int request_index,
                                         int request_count);
void rtipc_fault_init(rtipc_fault_context_t *context,
                      rtipc_fault_profile_t profile);
rtipc_fault_action_t rtipc_fault_on_tx(rtipc_fault_context_t *context,
                                       int payload_size,
                                       const uint8_t *packet,
                                       size_t length);
rtipc_fault_action_t rtipc_fault_on_rx(rtipc_fault_context_t *context,
                                       int payload_size,
                                       const uint8_t *packet,
                                       size_t length);
int rtipc_fault_take_held(rtipc_fault_context_t *context,
                          uint8_t *packet,
                          size_t capacity,
                          size_t *length);

#endif
