#define _POSIX_C_SOURCE 200809L

#include "rtipc_shutdown.h"

#include <errno.h>
#include <stdint.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>

#define SHUTDOWN_MAX_WAIT_MS 20U
#define SHUTDOWN_DEADLINE_MARGIN_MS 100U

static int monotonic_ms(uint64_t *now_ms)
{
    struct timespec time;

    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0)
        return -1;
    *now_ms = (uint64_t)time.tv_sec * 1000U +
              (uint64_t)time.tv_nsec / 1000000U;
    return 0;
}

static uint64_t shutdown_deadline(const rtipc_connection_t *connection,
                                  uint64_t started_ms)
{
    uint64_t interval_ms = connection->config.rto_ms;
    if (interval_ms == 0)
        interval_ms = 1;
    uint64_t attempts = (uint64_t)connection->config.max_retries + 1U;
    uint64_t budget_ms;

    if (attempts > (UINT64_MAX - SHUTDOWN_DEADLINE_MARGIN_MS) /
                       interval_ms)
        budget_ms = UINT64_MAX;
    else
        budget_ms = attempts * interval_ms + SHUTDOWN_DEADLINE_MARGIN_MS;
    if (budget_ms > UINT64_MAX - started_ms)
        return UINT64_MAX;
    return started_ms + budget_ms;
}

static rtipc_client_shutdown_result_t drain_shutdown_actions(
    int socket_fd, const struct sockaddr_in *peer,
    rtipc_connection_t *connection)
{
    const rtipc_action_t *action;

    while ((action = rtipc_action_next(connection)) != NULL) {
        if (action->type != RTIPC_ACTION_SEND)
            continue;
        ssize_t sent = sendto(socket_fd, action->data, action->data_len, 0,
                              (const struct sockaddr *)peer, sizeof(*peer));
        if (sent != (ssize_t)action->data_len) {
            rtipc_action_clear(connection);
            return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
        }
    }
    rtipc_action_clear(connection);
    return RTIPC_CLIENT_SHUTDOWN_OK;
}

static bool same_peer(const struct sockaddr_in *expected,
                      const struct sockaddr_in *received)
{
    return received->sin_family == expected->sin_family &&
           received->sin_port == expected->sin_port &&
           received->sin_addr.s_addr == expected->sin_addr.s_addr;
}

rtipc_client_shutdown_result_t rtipc_client_shutdown(
    int socket_fd, const struct sockaddr_in *peer,
    rtipc_connection_t *connection)
{
    if (socket_fd < 0 || peer == NULL || connection == NULL ||
        connection->state != RTIPC_STATE_CONNECTED)
        return RTIPC_CLIENT_SHUTDOWN_INVALID;

    uint64_t started_ms;
    if (monotonic_ms(&started_ms) != 0)
        return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
    uint64_t deadline_ms = shutdown_deadline(connection, started_ms);
    uint32_t timeouts_before = connection->stats.timeouts;
    uint8_t packet[RTIPC_MAX_PACKET];

    rtipc_connection_disconnect(connection, started_ms);
    while (true) {
        rtipc_client_shutdown_result_t drain_result =
            drain_shutdown_actions(socket_fd, peer, connection);
        if (drain_result != RTIPC_CLIENT_SHUTDOWN_OK)
            return drain_result;
        if (connection->state == RTIPC_STATE_CLOSED) {
            return connection->stats.timeouts == timeouts_before
                       ? RTIPC_CLIENT_SHUTDOWN_OK
                       : RTIPC_CLIENT_SHUTDOWN_TIMEOUT;
        }

        uint64_t current_ms;
        if (monotonic_ms(&current_ms) != 0)
            return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
        if (current_ms >= deadline_ms)
            return RTIPC_CLIENT_SHUTDOWN_TIMEOUT;
        uint64_t remaining_ms = deadline_ms - current_ms;
        uint64_t wait_ms = remaining_ms < SHUTDOWN_MAX_WAIT_MS
                               ? remaining_ms
                               : SHUTDOWN_MAX_WAIT_MS;
        struct timeval wait = {
            .tv_sec = (time_t)(wait_ms / 1000U),
            .tv_usec = (suseconds_t)((wait_ms % 1000U) * 1000U),
        };
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(socket_fd, &read_fds);
        int ready = select(socket_fd + 1, &read_fds, NULL, NULL, &wait);
        if (ready < 0 && errno != EINTR)
            return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
        if (ready > 0) {
            struct sockaddr_in source;
            socklen_t source_length = sizeof(source);
            ssize_t received = recvfrom(socket_fd, packet, sizeof(packet), 0,
                                        (struct sockaddr *)&source,
                                        &source_length);
            if (received < 0 && errno != EINTR)
                return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
            if (received > 0 && same_peer(peer, &source)) {
                uint64_t received_ms;
                if (monotonic_ms(&received_ms) != 0)
                    return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
                rtipc_connection_on_recv(connection, packet,
                                         (size_t)received, received_ms);
            }
        }
        uint64_t tick_ms;
        if (monotonic_ms(&tick_ms) != 0)
            return RTIPC_CLIENT_SHUTDOWN_IO_ERROR;
        rtipc_connection_tick(connection, tick_ms);
    }
}
