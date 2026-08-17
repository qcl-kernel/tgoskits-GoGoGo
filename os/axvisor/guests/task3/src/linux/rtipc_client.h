#ifndef TASK3_RTIPC_CLIENT_H
#define TASK3_RTIPC_CLIENT_H

#include "session.h"
#include "task3_protocol.h"

#include <netinet/in.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    TASK3_SERVER_PORT = 9876,
    TASK3_CLIENT_APPLICATION_TIMEOUT_MS = 500,
    TASK3_CLIENT_RECOVERY_TIMEOUT_MS = 30000,
};

typedef struct {
    task3_status_t status;
    task3_error_t error;
    uint64_t round_trip_us;
    uint32_t transport_retries;
    int recovered;
    int application_error;
} task3_client_reply_t;

typedef struct {
    int socket_fd;
    struct sockaddr_in peer;
    task3_session_t session;
    task3_status_t received_status;
    task3_error_t received_error;
    uint64_t received_ns;
    uint64_t ctrl_attempts;
    uint64_t drop_tx_seq;
    uint64_t injected_drops;
    uint64_t application_timeouts;
    uint32_t waiting_frame_id;
    int waiting;
    int have_status;
    int have_error;
} task3_client_t;

uint64_t task3_monotonic_raw_ns(void);
int task3_client_validate_ipv4(const char *peer_ipv4);
int task3_client_open(task3_client_t *client, const char *peer_ipv4,
                      uint16_t peer_port, uint64_t drop_tx_seq);
int task3_client_connect(task3_client_t *client, uint32_t timeout_ms);
int task3_client_transact(task3_client_t *client, task3_control_t *control,
                          task3_client_reply_t *reply);
int task3_client_run_malformed_probe(task3_client_t *client,
                                     int16_t *actuator_before,
                                     int16_t *actuator_after,
                                     uint32_t *rejected);
int task3_client_send_stop(task3_client_t *client, task3_mode_t mode,
                           uint32_t frame_id);
void task3_client_close(task3_client_t *client);

#ifdef __cplusplus
}
#endif

#endif
