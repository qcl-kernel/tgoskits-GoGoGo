#ifndef TASK3_SESSION_H
#define TASK3_SESSION_H

#include "rt_ipc.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TASK3_SESSION_CLIENT = 1,
    TASK3_SESSION_SERVER = 2,
} task3_session_role_t;

typedef int (*task3_session_send_fn)(void *context, const uint8_t *bytes,
                                     size_t length);
typedef int (*task3_session_deliver_fn)(void *context, uint8_t message_type,
                                        const uint8_t *payload, size_t length,
                                        uint64_t now_ms);

typedef struct {
    uint64_t datagrams_sent;
    uint64_t transport_retries;
    uint64_t connects;
    uint64_t reconnects;
    uint64_t disconnects;
    uint64_t send_errors;
    uint64_t delivery_errors;
} task3_session_counters_t;

typedef struct {
    rtipc_connection_t connection;
    task3_session_role_t role;
    task3_session_send_fn send_datagram;
    task3_session_deliver_fn deliver_message;
    void *callback_context;
    task3_session_counters_t counters;
    uint8_t outstanding_control[RTIPC_MAX_PAYLOAD];
    size_t outstanding_length;
    uint32_t outstanding_frame_id;
    bool outstanding;
    bool connected_once;
} task3_session_t;

void task3_session_init(task3_session_t *session, task3_session_role_t role,
                        uint64_t session_id_seed,
                        task3_session_send_fn send_datagram,
                        task3_session_deliver_fn deliver_message,
                        void *callback_context);
int task3_session_connect(task3_session_t *session, uint64_t now_ms);
int task3_session_on_datagram(task3_session_t *session, const uint8_t *bytes,
                              size_t length, uint64_t now_ms);
int task3_session_tick(task3_session_t *session, uint64_t now_ms);
int task3_session_send(task3_session_t *session, rtipc_msg_type_t message_type,
                       const uint8_t *payload, size_t length, uint64_t now_ms);
int task3_session_submit_control(task3_session_t *session, const uint8_t *payload,
                                 size_t length, uint32_t frame_id,
                                 uint64_t now_ms);
void task3_session_force_disconnect(task3_session_t *session, uint64_t now_ms);
bool task3_session_is_connected(const task3_session_t *session);
bool task3_session_has_outstanding(const task3_session_t *session);

#ifdef __cplusplus
}
#endif

#endif
