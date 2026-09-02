#define _GNU_SOURCE

#include "rtipc_client.h"
#include "deadline.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static uint64_t to_ms(uint64_t nanoseconds)
{
    return nanoseconds / UINT64_C(1000000);
}

uint64_t task3_monotonic_raw_ns(void)
{
    struct timespec value;

    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)value.tv_nsec;
}

int task3_client_validate_ipv4(const char *peer_ipv4)
{
    struct in_addr address;

    return peer_ipv4 != NULL && inet_pton(AF_INET, peer_ipv4, &address) == 1
               ? 0
               : -1;
}

static uint64_t make_session_id_seed(const task3_client_t *client)
{
    uint64_t seed = task3_monotonic_raw_ns();

    seed ^= (uint64_t)(uint32_t)getpid() << 32;
    seed ^= (uint64_t)(uintptr_t)client;
    return seed != 0 ? seed : UINT64_C(1);
}

static int send_datagram(void *context, const uint8_t *bytes, size_t length)
{
    task3_client_t *client = context;
    ssize_t sent;

    if (length >= RTIPC_HEADER_SIZE && bytes[1] == RTIPC_MSG_CTRL_CMD) {
        client->ctrl_attempts++;
        if (client->drop_tx_seq != 0 &&
            client->ctrl_attempts == client->drop_tx_seq) {
            client->injected_drops++;
            return 0;
        }
    }
    sent = sendto(client->socket_fd, bytes, length, 0,
                  (const struct sockaddr *)&client->peer, sizeof(client->peer));
    if (sent < 0) {
        return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -1;
    }
    return (size_t)sent == length ? 0 : -1;
}

static int deliver_message(void *context, uint8_t message_type,
                           const uint8_t *payload, size_t length,
                           uint64_t now_ms)
{
    task3_client_t *client = context;

    (void)now_ms;
    if (message_type == RTIPC_MSG_STATUS_REP) {
        if (task3_decode_status(payload, length, &client->received_status) !=
            TASK3_CODEC_OK) {
            return -1;
        }
        if (client->waiting &&
            client->received_status.frame_id == client->waiting_frame_id) {
            client->received_ns = task3_monotonic_raw_ns();
            if (client->received_ns == 0) {
                return -1;
            }
            client->have_status = 1;
        }
        return 0;
    }
    if (message_type == RTIPC_MSG_ERROR_NOTIFY) {
        if (task3_decode_error(payload, length, &client->received_error) !=
            TASK3_CODEC_OK) {
            return -1;
        }
        if (client->waiting &&
            client->received_error.frame_id == client->waiting_frame_id) {
            client->received_ns = task3_monotonic_raw_ns();
            if (client->received_ns == 0) {
                return -1;
            }
            client->have_error = 1;
        }
        return 0;
    }
    return -1;
}

int task3_client_open(task3_client_t *client, const char *peer_ipv4,
                      uint16_t peer_port, uint64_t drop_tx_seq)
{
    int flags;

    if (client == NULL || peer_port == 0 ||
        task3_client_validate_ipv4(peer_ipv4) != 0) {
        return -1;
    }
    memset(client, 0, sizeof(*client));
    client->socket_fd = -1;
    client->peer.sin_family = AF_INET;
    client->peer.sin_port = htons(peer_port);
    if (inet_pton(AF_INET, peer_ipv4, &client->peer.sin_addr) != 1) {
        return -1;
    }
    client->socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (client->socket_fd < 0) {
        return -1;
    }
    flags = fcntl(client->socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        task3_client_close(client);
        return -1;
    }
    client->drop_tx_seq = drop_tx_seq;
    task3_session_init(&client->session, TASK3_SESSION_CLIENT,
                       make_session_id_seed(client), send_datagram,
                       deliver_message, client);
    return 0;
}

static int service_once(task3_client_t *client, int wait_ms)
{
    struct pollfd descriptor = {
        .fd = client->socket_fd,
        .events = POLLIN,
    };
    uint8_t bytes[RTIPC_MAX_PACKET];
    int polled;
    uint64_t now_ns;

    polled = poll(&descriptor, 1, wait_ms);
    if (polled < 0 && errno != EINTR) {
        return -1;
    }
    if (polled > 0 && (descriptor.revents & POLLIN) != 0) {
        struct sockaddr_in source;
        socklen_t source_length = sizeof(source);
        ssize_t received = recvfrom(client->socket_fd, bytes, sizeof(bytes),
                                    MSG_TRUNC,
                                    (struct sockaddr *)&source, &source_length);
        if (received > 0 && received <= (ssize_t)sizeof(bytes) &&
            source_length == sizeof(source) &&
            source.sin_addr.s_addr == client->peer.sin_addr.s_addr &&
            source.sin_port == client->peer.sin_port) {
            now_ns = task3_monotonic_raw_ns();
            if (now_ns == 0 ||
                task3_session_on_datagram(&client->session, bytes,
                                          (size_t)received, to_ms(now_ns)) != 0) {
                return -1;
            }
        }
    }
    now_ns = task3_monotonic_raw_ns();
    return now_ns == 0
               ? -1
               : task3_session_tick(&client->session, to_ms(now_ns));
}

int task3_client_connect(task3_client_t *client, uint32_t timeout_ms)
{
    uint64_t started;
    uint64_t now;

    if (client == NULL || client->socket_fd < 0) {
        return -1;
    }
    started = task3_monotonic_raw_ns();
    if (started == 0 ||
        task3_session_connect(&client->session, to_ms(started)) != 0) {
        return -1;
    }
    for (;;) {
        if (task3_session_is_connected(&client->session)) {
            return 0;
        }
        now = task3_monotonic_raw_ns();
        if (now == 0 || now - started >= (uint64_t)timeout_ms * UINT64_C(1000000)) {
            return -1;
        }
        if (service_once(client, 10) != 0) {
            return -1;
        }
    }
}

int task3_client_transact(task3_client_t *client, task3_control_t *control,
                          task3_client_reply_t *reply)
{
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];
    uint64_t started;
    uint64_t timeout_deadline;
    uint64_t final_deadline;
    uint64_t retries_before;
    int recovery_started = 0;

    if (client == NULL || control == NULL || reply == NULL ||
        !task3_session_is_connected(&client->session)) {
        return -1;
    }
    memset(reply, 0, sizeof(*reply));
    client->have_status = 0;
    client->have_error = 0;
    client->waiting = 1;
    client->waiting_frame_id = control->frame_id;
    started = task3_monotonic_raw_ns();
    if (started == 0) {
        client->waiting = 0;
        return -1;
    }
    control->tx_monotonic_ns = started;
    if (task3_encode_control(control, wire) != TASK3_CODEC_OK) {
        client->waiting = 0;
        return -1;
    }
    retries_before = client->session.counters.transport_retries;
    if (task3_session_submit_control(&client->session, wire, sizeof(wire),
                                     control->frame_id, to_ms(started)) != 0) {
        client->waiting = 0;
        return -1;
    }
    timeout_deadline = started +
                       TASK3_CLIENT_APPLICATION_TIMEOUT_MS * UINT64_C(1000000);
    final_deadline = started +
                     (TASK3_CLIENT_APPLICATION_TIMEOUT_MS +
                      TASK3_CLIENT_RECOVERY_TIMEOUT_MS) *
                         UINT64_C(1000000);
    for (;;) {
        uint64_t now = task3_monotonic_raw_ns();
        uint64_t active_deadline =
            recovery_started ? final_deadline : timeout_deadline;
        task3_deadline_action_t deadline_action;

        if (client->have_status &&
            task3_deadline_received_in_time(client->received_ns,
                                            active_deadline)) {
            if (client->received_status.frame_id != control->frame_id ||
                client->received_status.echoed_tx_monotonic_ns != started ||
                client->received_ns < started) {
                client->waiting = 0;
                return -1;
            }
            reply->status = client->received_status;
            reply->round_trip_us = (client->received_ns - started) / 1000;
            reply->transport_retries =
                client->session.counters.transport_retries - retries_before >
                        UINT32_MAX
                    ? UINT32_MAX
                    : (uint32_t)(client->session.counters.transport_retries -
                                 retries_before);
            reply->recovered = recovery_started;
            client->waiting = 0;
            return 0;
        }
        if (client->have_error &&
            task3_deadline_received_in_time(client->received_ns,
                                            active_deadline)) {
            reply->error = client->received_error;
            reply->application_error = 1;
            client->waiting = 0;
            return -2;
        }
        if (now == 0) {
            client->waiting = 0;
            return -1;
        }
        deadline_action = task3_deadline_action(
            now, timeout_deadline, final_deadline, recovery_started);
        if (deadline_action == TASK3_DEADLINE_EXPIRED) {
            client->waiting = 0;
            return -1;
        }
        if (deadline_action == TASK3_DEADLINE_START_RECOVERY) {
            client->application_timeouts++;
            recovery_started = 1;
            client->have_status = 0;
            client->have_error = 0;
            task3_session_force_disconnect(&client->session, to_ms(now));
            active_deadline = final_deadline;
        }
        if (service_once(client,
                         task3_deadline_poll_ms(now, active_deadline, 10)) !=
            0) {
            client->waiting = 0;
            return -1;
        }
    }
}

static int wait_for_application_error(task3_client_t *client,
                                      const uint8_t *payload, size_t length,
                                      uint32_t frame_id)
{
    uint64_t started = task3_monotonic_raw_ns();
    uint64_t deadline;

    if (started == 0) {
        return -1;
    }
    deadline = started + TASK3_CLIENT_APPLICATION_TIMEOUT_MS * UINT64_C(1000000);
    client->waiting = 1;
    client->waiting_frame_id = frame_id;
    client->have_error = 0;
    client->have_status = 0;
    if (task3_session_send(&client->session, RTIPC_MSG_CTRL_CMD, payload, length,
                           to_ms(started)) != 0) {
        client->waiting = 0;
        return -1;
    }
    for (;;) {
        uint64_t now = task3_monotonic_raw_ns();

        if (client->have_error && client->received_ns < deadline) {
            client->waiting = 0;
            return client->received_error.category ==
                           TASK3_ERROR_CATEGORY_PROTOCOL
                       ? 0
                       : -1;
        }
        if (now == 0 || now >= deadline ||
            service_once(client, task3_deadline_poll_ms(now, deadline, 10)) !=
                0) {
            client->waiting = 0;
            return -1;
        }
    }
}

static int send_corrupt_crc(task3_client_t *client, const uint8_t *payload,
                            size_t length)
{
    rtipc_header_t header = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = RTIPC_MSG_CTRL_CMD,
        .seq_num = client->session.connection.send_seq,
        .error_code = RTIPC_ERR_OK,
    };
    uint8_t packet[RTIPC_MAX_PACKET];
    size_t packet_length =
        rtipc_build_packet(&header, payload, length, packet, sizeof(packet));
    ssize_t sent;
    uint64_t started;

    if (packet_length != RTIPC_HEADER_SIZE + length || length == 0) {
        return -1;
    }
    packet[packet_length - 1] ^= UINT8_C(0x01);
    sent = sendto(client->socket_fd, packet, packet_length, 0,
                  (const struct sockaddr *)&client->peer, sizeof(client->peer));
    if (sent != (ssize_t)packet_length) {
        return -1;
    }
    started = task3_monotonic_raw_ns();
    while (started != 0) {
        uint64_t now = task3_monotonic_raw_ns();

        if (now == 0) {
            return -1;
        }
        if (now - started >= UINT64_C(100000000)) {
            return 0;
        }
        if (service_once(client, 10) != 0) {
            return -1;
        }
    }
    return -1;
}

int task3_client_run_malformed_probe(task3_client_t *client,
                                     int16_t *actuator_before,
                                     int16_t *actuator_after,
                                     uint32_t *rejected)
{
    task3_control_t reset;
    task3_client_reply_t reply;
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];
    uint32_t rejected_count = 0;

    if (client == NULL || actuator_before == NULL || actuator_after == NULL ||
        rejected == NULL || !task3_session_is_connected(&client->session)) {
        return -1;
    }
    memset(&reset, 0, sizeof(reset));
    reset.command = TASK3_CMD_RESET;
    reset.mode = TASK3_MODE_FIXED;
    reset.klass = TASK3_CLASS_CENTER;
    if (task3_client_transact(client, &reset, &reply) != 0) {
        return -1;
    }
    *actuator_before = reply.status.actuator_q15;
    reset.tx_monotonic_ns = task3_monotonic_raw_ns();
    if (reset.tx_monotonic_ns == 0 ||
        task3_encode_control(&reset, wire) != TASK3_CODEC_OK) {
        return -1;
    }
    wire[0] = TASK3_SCHEMA_VERSION + 1;
    if (wait_for_application_error(client, wire, sizeof(wire), reset.frame_id) !=
        0) {
        return -1;
    }
    rejected_count++;
    wire[0] = TASK3_SCHEMA_VERSION;
    if (wait_for_application_error(client, wire, sizeof(wire) - 1,
                                   reset.frame_id) != 0) {
        return -1;
    }
    rejected_count++;
    if (send_corrupt_crc(client, wire, sizeof(wire)) != 0 ||
        task3_client_transact(client, &reset, &reply) != 0) {
        return -1;
    }
    *actuator_after = reply.status.actuator_q15;
    *rejected = rejected_count + 1;
    return 0;
}

int task3_client_send_stop(task3_client_t *client, task3_mode_t mode,
                           uint32_t frame_id)
{
    task3_control_t control;
    task3_client_reply_t reply;

    if (client == NULL || !task3_session_is_connected(&client->session)) {
        return -1;
    }
    memset(&control, 0, sizeof(control));
    control.command = TASK3_CMD_STOP;
    control.mode = mode;
    control.klass = TASK3_CLASS_CENTER;
    control.frame_id = frame_id;
    return task3_client_transact(client, &control, &reply) == 0 &&
                   reply.status.status == TASK3_STATUS_STOPPED
               ? 0
               : -1;
}

void task3_client_close(task3_client_t *client)
{
    if (client != NULL && client->socket_fd >= 0) {
        close(client->socket_fd);
        client->socket_fd = -1;
    }
}
