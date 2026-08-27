#ifndef RTIPC_ECHO_RESPONDER_H
#define RTIPC_ECHO_RESPONDER_H

#include <stddef.h>
#include <stdint.h>

#include "rt_ipc.h"

typedef int (*rtipc_echo_send_fn)(const uint8_t *data, size_t len,
                                  void *context);

typedef struct {
    uint32_t connected_events;
    uint32_t disconnected_events;
    uint32_t delivered_messages;
    uint32_t response_errors;
    uint32_t send_errors;
} rtipc_echo_result_t;

rtipc_echo_result_t rtipc_echo_process_actions(
    rtipc_connection_t *connection, uint64_t now_ms,
    rtipc_echo_send_fn send_packet, void *send_context);

#endif
