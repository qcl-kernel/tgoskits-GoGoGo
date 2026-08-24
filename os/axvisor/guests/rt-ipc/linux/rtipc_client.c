/*
 * RT-IPC UDP Client for Linux.
 * Connects to RT-Thread server, sends CTRL_CMD, measures RTT/throughput.
 * Tests 64B/256B/1024B payloads, 1000 round-trips each, with mid-test disconnect.
 */
#include "rt_ipc.h"
#include "rtipc_client_report.h"
#include "rtipc_fault.h"
#include "rtipc_shutdown.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <time.h>
#include <errno.h>

#define DEFAULT_HOST   "192.168.77.30"
#define DEFAULT_PORT   9876
#define DEFAULT_COUNT  1000
#define MAX_PAYLOAD_SIZES 3
#define REQUEST_TIMEOUT_MARGIN_MS 1000
#define MAX_SELECT_WAIT_MS 20
#define HANDSHAKE_TIMEOUT_MS 60000

static int now_ms(uint64_t *current_ms) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        fprintf(stderr, "RTIPC_FAILURE reason=clock_error\n");
        return -1;
    }
    *current_ms = (uint64_t)ts.tv_sec * 1000U +
                  (uint64_t)ts.tv_nsec / 1000000U;
    return 0;
}

static uint64_t mix_u64(uint64_t value)
{
    value += UINT64_C(0x9e3779b97f4a7c15);
    value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
    return value ^ (value >> 31);
}

static int generate_session_seed(uint64_t *seed)
{
    struct timespec monotonic;
    struct timespec realtime;

    if (clock_gettime(CLOCK_MONOTONIC_RAW, &monotonic) != 0 ||
        clock_gettime(CLOCK_REALTIME, &realtime) != 0) {
        fprintf(stderr, "RTIPC_FAILURE reason=session_seed_error\n");
        return -1;
    }

    /* The seed only needs uniqueness for protocol sessions, not entropy.  A
     * blocking getrandom() would make boot-time smoke tests depend on Linux
     * CRNG initialization, which can be delayed indefinitely under QEMU. */
    uint64_t monotonic_ns = (uint64_t)monotonic.tv_sec * UINT64_C(1000000000) +
                            (uint64_t)monotonic.tv_nsec;
    uint64_t realtime_ns = (uint64_t)realtime.tv_sec * UINT64_C(1000000000) +
                           (uint64_t)realtime.tv_nsec;
    *seed = mix_u64(monotonic_ns ^ mix_u64(realtime_ns) ^
                    mix_u64((uint64_t)getpid()));
    return 0;
}

static uint64_t percentile(uint64_t *sorted, int n, double p) {
    if (n == 0) return 0;
    int idx = (int)(p * (n - 1));
    return sorted[idx];
}

typedef struct {
    int payload_size;
    int sent;
    int received;
    uint64_t total_bytes;
    uint64_t sum_rtt;
    uint64_t total_time_ms;
    uint64_t reconnects;
    uint64_t request_timeouts;
    uint64_t protocol_errors;
    uint64_t min_rtt;
    uint64_t max_rtt;
    uint64_t *rtt_samples;
} test_result_t;

static int send_datagram(int sock, const struct sockaddr_in *peer,
                         const uint8_t *data, size_t len)
{
    ssize_t sent = sendto(sock, data, len, 0,
                          (const struct sockaddr *)peer, sizeof(*peer));
    return sent == (ssize_t)len ? 0 : -1;
}

static uint32_t packet_sequence(const uint8_t *data, size_t len)
{
    rtipc_header_t header;

    return rtipc_header_parse(data, len, &header) == 0
               ? header.seq_num
               : 0;
}

static int send_with_faults(int sock, const struct sockaddr_in *peer,
                            rtipc_fault_context_t *faults,
                            int payload_size,
                            const rtipc_action_t *action)
{
    rtipc_fault_action_t fault_action = rtipc_fault_on_tx(
        faults, payload_size, action->data, action->data_len);

    if (fault_action == RTIPC_FAULT_ACTION_DROP) {
        printf("[client] fault injection: drop tx payload=%d seq=%u\n",
               payload_size,
               packet_sequence(action->data, action->data_len));
        fflush(stdout);
        return 0;
    }
    return send_datagram(sock, peer, action->data, action->data_len);
}

static int receive_with_faults(rtipc_connection_t *conn,
                               rtipc_fault_context_t *faults,
                               int payload_size,
                               const uint8_t *data,
                               size_t len,
                               uint64_t received_at_ms)
{
    static uint8_t held[RTIPC_MAX_PACKET];
    size_t held_len = 0;
    rtipc_fault_action_t action = rtipc_fault_on_rx(
        faults, payload_size, data, len);

    switch (action) {
    case RTIPC_FAULT_ACTION_DUPLICATE:
        printf("[client] fault injection: duplicate rx payload=%d seq=%u\n",
               payload_size, packet_sequence(data, len));
        fflush(stdout);
        rtipc_connection_on_recv(conn, data, len, received_at_ms);
        rtipc_connection_on_recv(conn, data, len, received_at_ms);
        return 0;
    case RTIPC_FAULT_ACTION_HOLD:
        return 0;
    case RTIPC_FAULT_ACTION_RELEASE_REVERSED:
        if (rtipc_fault_take_held(faults, held, sizeof(held), &held_len) != 0)
            return -1;
        printf("[client] fault injection: reorder rx payload=%d "
               "first_seq=%u second_seq=%u\n",
               payload_size, packet_sequence(held, held_len),
               packet_sequence(data, len));
        fflush(stdout);
        rtipc_connection_on_recv(conn, data, len, received_at_ms);
        rtipc_connection_on_recv(conn, held, held_len, received_at_ms);
        return 0;
    case RTIPC_FAULT_ACTION_DROP:
        return 0;
    case RTIPC_FAULT_ACTION_PASS:
    default:
        rtipc_connection_on_recv(conn, data, len, received_at_ms);
        return 0;
    }
}

static void report_progress(int payload_size, int index, test_result_t *result,
                            rtipc_connection_t *conn, uint64_t stall_ms)
{
    rtipc_stats_t stats = rtipc_connection_stats(conn);
    printf("[progress] size=%d idx=%d sent=%d recv=%d state=%d "
           "tx=%u rx=%u retrans=%u timeouts=%u dup=%u reorder=%u errors=%u "
           "acks=%u stall=%llums\n",
           payload_size, index, result->sent, result->received,
           (int)conn->state, stats.tx_packets, stats.rx_packets,
           stats.retransmissions, stats.timeouts, stats.rx_duplicates,
           stats.rx_out_of_order, stats.rx_errors, stats.acks_received,
           (unsigned long long)stall_ms);
    fflush(stdout);
}

static int drain_reconnect_actions(int sock, const struct sockaddr_in *peer,
                                   rtipc_connection_t *conn)
{
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(conn))) {
        if (action->type == RTIPC_ACTION_SEND &&
            send_datagram(sock, peer, action->data, action->data_len) != 0) {
            rtipc_action_clear(conn);
            return -1;
        }
    }
    rtipc_action_clear(conn);
    return 0;
}

static int force_disconnect_and_reconnect(int sock,
                                          const struct sockaddr_in *peer,
                                          rtipc_connection_t *conn,
                                          int request_index,
                                          test_result_t *result)
{
    static uint8_t recv_buf[RTIPC_MAX_PACKET];
    uint64_t started_ms;
    if (now_ms(&started_ms) != 0)
        return -1;
    printf("[client] fault injection: force disconnect at request=%d\n",
           request_index);
    fflush(stdout);

    rtipc_connection_force_disconnect(conn, started_ms);
    unsigned attempts = conn->reconnect_attempts;
    if (conn->state != RTIPC_STATE_RECONNECTING ||
        drain_reconnect_actions(sock, peer, conn) != 0)
        return -1;

    uint64_t deadline = started_ms + conn->config.reconnect_max_delay_ms +
                        conn->config.connect_timeout_ms + 1000;
    while (!rtipc_connection_is_connected(conn)) {
        uint64_t current_ms;
        if (now_ms(&current_ms) != 0)
            return -1;
        if (current_ms >= deadline)
            break;
        rtipc_connection_tick(conn, current_ms);
        if (drain_reconnect_actions(sock, peer, conn) != 0)
            return -1;

        fd_set rfds;
        struct timeval tv = {0, MAX_SELECT_WAIT_MS * 1000};
        FD_ZERO(&rfds);
        FD_SET(sock, &rfds);
        int ready = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (ready < 0 && errno != EINTR)
            return -1;
        if (ready > 0) {
            ssize_t received = recvfrom(sock, recv_buf, sizeof(recv_buf),
                                        0, NULL, NULL);
            if (received > 0) {
                uint64_t received_ms;
                if (now_ms(&received_ms) != 0)
                    return -1;
                rtipc_connection_on_recv(conn, recv_buf,
                                         (size_t)received, received_ms);
            }
        }
        if (drain_reconnect_actions(sock, peer, conn) != 0)
            return -1;
    }

    if (!rtipc_connection_is_connected(conn))
        return -1;

    uint64_t recovered_ms;
    if (now_ms(&recovered_ms) != 0)
        return -1;
    uint64_t recovery_ms = recovered_ms - started_ms;
    if (recovery_ms == 0)
        recovery_ms = 1;
    result->reconnects++;
    printf("[client] reconnect complete recovery_ms=%llu attempts=%u\n",
           (unsigned long long)recovery_ms, attempts);
    fflush(stdout);
    return 0;
}

static int run_reorder_pair(int sock, const struct sockaddr_in *peer,
                            int payload_size, rtipc_connection_t *conn,
                            rtipc_fault_context_t *faults,
                            test_result_t *result)
{
    uint8_t payloads[2][RTIPC_MAX_PAYLOAD];
    uint8_t recv_buf[RTIPC_MAX_PACKET];
    uint64_t started_ms;
    uint64_t deadline;
    int delivered = 0;

    if (now_ms(&started_ms) != 0)
        return -1;

    memset(payloads[0], 0xA0, (size_t)payload_size);
    memset(payloads[1], 0xA1, (size_t)payload_size);
    for (int index = 0; index < 2; index++) {
        uint64_t sent_ms;
        if (now_ms(&sent_ms) != 0)
            return -1;
        if (rtipc_connection_send(conn, RTIPC_MSG_CTRL_CMD,
                                  payloads[index], (size_t)payload_size,
                                  sent_ms) != 0) {
            result->protocol_errors++;
            return -1;
        }
        const rtipc_action_t *action;
        while ((action = rtipc_action_next(conn))) {
            if (action->type == RTIPC_ACTION_SEND &&
                send_with_faults(sock, peer, faults, payload_size,
                                 action) != 0) {
                rtipc_action_clear(conn);
                return -1;
            }
        }
        rtipc_action_clear(conn);
        result->sent++;
    }

    deadline = started_ms +
               conn->config.rto_ms * (conn->config.max_retries + 1) +
               REQUEST_TIMEOUT_MARGIN_MS;
    while (delivered < 2) {
        uint64_t current_ms;
        if (now_ms(&current_ms) != 0)
            return -1;
        if (current_ms >= deadline)
            break;
        fd_set rfds;
        struct timeval tv = {0, MAX_SELECT_WAIT_MS * 1000};
        FD_ZERO(&rfds);
        FD_SET(sock, &rfds);
        int ready = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (ready < 0 && errno != EINTR) {
            result->protocol_errors++;
            return -1;
        }
        if (ready > 0) {
            ssize_t received = recvfrom(sock, recv_buf, sizeof(recv_buf),
                                        0, NULL, NULL);
            if (received > 0) {
                uint64_t received_ms;
                if (now_ms(&received_ms) != 0)
                    return -1;
                if (receive_with_faults(conn, faults, payload_size, recv_buf,
                                        (size_t)received, received_ms) != 0) {
                    result->protocol_errors++;
                    return -1;
                }
            }
        }

        const rtipc_action_t *action;
        while ((action = rtipc_action_next(conn))) {
            if (action->type == RTIPC_ACTION_SEND &&
                send_with_faults(sock, peer, faults, payload_size,
                                 action) != 0) {
                rtipc_action_clear(conn);
                return -1;
            }
            if (action->type == RTIPC_ACTION_DELIVER) {
                if (delivered >= 2 ||
                    action->msg_type != RTIPC_MSG_STATUS_REP ||
                    action->payload_len != (size_t)payload_size ||
                    memcmp(action->payload, payloads[delivered],
                           (size_t)payload_size) != 0) {
                    result->protocol_errors++;
                    continue;
                }
                uint64_t delivered_ms;
                if (now_ms(&delivered_ms) != 0) {
                    rtipc_action_clear(conn);
                    return -1;
                }
                uint64_t rtt = delivered_ms - started_ms;
                result->received++;
                result->total_bytes += action->payload_len;
                result->sum_rtt += rtt;
                if (rtt < result->min_rtt) result->min_rtt = rtt;
                if (rtt > result->max_rtt) result->max_rtt = rtt;
                result->rtt_samples[result->received - 1] = rtt;
                delivered++;
            }
            if (action->type == RTIPC_ACTION_DISCONNECTED) {
                result->protocol_errors++;
                rtipc_action_clear(conn);
                return -1;
            }
        }
        rtipc_action_clear(conn);

        uint64_t tick_ms;
        if (now_ms(&tick_ms) != 0)
            return -1;
        rtipc_connection_tick(conn, tick_ms);
        while ((action = rtipc_action_next(conn))) {
            if (action->type == RTIPC_ACTION_SEND &&
                send_with_faults(sock, peer, faults, payload_size,
                                 action) != 0) {
                rtipc_action_clear(conn);
                return -1;
            }
            if (action->type == RTIPC_ACTION_DISCONNECTED) {
                result->protocol_errors++;
                rtipc_action_clear(conn);
                return -1;
            }
        }
        rtipc_action_clear(conn);
    }

    if (delivered != 2) {
        result->request_timeouts++;
        return -1;
    }
    return 0;
}

static int run_test(int sock, struct sockaddr_in *peer,
                    int payload_size, int count,
                    rtipc_connection_t *conn,
                    rtipc_fault_context_t *faults,
                    test_result_t *result)
{
    static uint8_t payload[RTIPC_MAX_PAYLOAD];
    static uint8_t recv_buf[RTIPC_MAX_PACKET];
    memset(payload, 0xAA, payload_size);
    memset(result, 0, sizeof(*result));
    result->payload_size = payload_size;
    result->min_rtt = ~0ULL;
    result->rtt_samples = malloc(count * sizeof(uint64_t));
    if (result->rtt_samples == NULL)
        return -1;

    uint64_t test_start;
    if (now_ms(&test_start) != 0)
        return -1;
    uint64_t last_progress = test_start;
    uint64_t last_receive = test_start;
    int start_index = 0;

    if (faults->profile == RTIPC_FAULT_PROFILE_RELIABILITY &&
        payload_size == 1024) {
        if (run_reorder_pair(sock, peer, payload_size, conn, faults,
                             result) != 0) {
            return -1;
        }
        start_index = 2;
        if (now_ms(&last_receive) != 0)
            return -1;
    }

    for (int i = start_index; i < count; i++) {
        /* Inject one connection failure between requests. */
        if (rtipc_fault_should_force_disconnect(
                faults->profile, payload_size, i, count)) {
            if (force_disconnect_and_reconnect(sock, peer, conn, i, result) != 0) {
                result->protocol_errors++;
                return -1;
            }
        }

        if (!rtipc_connection_is_connected(conn)) {
            result->protocol_errors++;
            return -1;
        }

        /* Send CTRL_CMD */
        uint64_t sent_ms;
        if (now_ms(&sent_ms) != 0)
            return -1;
        int send_rc = rtipc_connection_send(conn, RTIPC_MSG_CTRL_CMD,
                                            payload, payload_size, sent_ms);
        if (send_rc != 0) {
            result->protocol_errors++;
            return -1;
        }
        const rtipc_action_t *act;
        while ((act = rtipc_action_next(conn))) {
            if (act->type == RTIPC_ACTION_SEND &&
                send_with_faults(sock, peer, faults, payload_size,
                                 act) != 0) {
                rtipc_action_clear(conn);
                return -1;
            }
        }
        rtipc_action_clear(conn);
        result->sent++;

        /* Wait for STATUS_REP */
        uint64_t st;
        if (now_ms(&st) != 0)
            return -1;
        uint64_t request_timeout_ms =
            conn->config.rto_ms * (conn->config.max_retries + 1) +
            REQUEST_TIMEOUT_MARGIN_MS;
        uint64_t deadline = st + request_timeout_ms;
        int got = 0;
        while (!got) {
            uint64_t current_ms;
            if (now_ms(&current_ms) != 0)
                return -1;
            if (current_ms >= deadline)
                break;
            uint64_t remaining_ms = deadline - current_ms;
            uint64_t wait_ms = remaining_ms < MAX_SELECT_WAIT_MS
                                   ? remaining_ms
                                   : MAX_SELECT_WAIT_MS;
            fd_set rfds;
            struct timeval tv = {
                .tv_sec = (time_t)(wait_ms / 1000),
                .tv_usec = (suseconds_t)((wait_ms % 1000) * 1000),
            };
            FD_ZERO(&rfds); FD_SET(sock, &rfds);
            int rv = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rv < 0 && errno != EINTR) {
                result->protocol_errors++;
                return -1;
            }
            if (rv > 0) {
                ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0, NULL, NULL);
                if (n > 0) {
                    uint64_t received_ms;
                    if (now_ms(&received_ms) != 0)
                        return -1;
                    if (receive_with_faults(conn, faults, payload_size,
                                            recv_buf, (size_t)n,
                                            received_ms) != 0) {
                        result->protocol_errors++;
                        return -1;
                    }
                }
            }
            while ((act = rtipc_action_next(conn))) {
                if (act->type == RTIPC_ACTION_SEND &&
                send_with_faults(sock, peer, faults, payload_size,
                                     act) != 0) {
                    rtipc_action_clear(conn);
                    return -1;
                }
                if (act->type == RTIPC_ACTION_DELIVER) {
                    if (act->msg_type != RTIPC_MSG_STATUS_REP ||
                        act->payload_len != (size_t)payload_size ||
                        memcmp(act->payload, payload, payload_size) != 0) {
                        result->protocol_errors++;
                        continue;
                    }
                    uint64_t delivered_ms;
                    if (now_ms(&delivered_ms) != 0) {
                        rtipc_action_clear(conn);
                        return -1;
                    }
                    uint64_t rtt = delivered_ms - st;
                    result->received++;
                    last_receive = delivered_ms;
                    result->total_bytes += act->payload_len;
                    result->sum_rtt += rtt;
                    if (rtt < result->min_rtt) result->min_rtt = rtt;
                    if (rtt > result->max_rtt) result->max_rtt = rtt;
                    if (result->received <= count)
                        result->rtt_samples[result->received - 1] = rtt;
                    got = 1;
                }
                if (act->type == RTIPC_ACTION_DISCONNECTED) {
                    result->protocol_errors++;
                    rtipc_action_clear(conn);
                    return -1;
                }
            }
            rtipc_action_clear(conn);
            /* Now poll timeouts/retransmits and drain newly queued work. */
            uint64_t tick_ms;
            if (now_ms(&tick_ms) != 0)
                return -1;
            rtipc_connection_tick(conn, tick_ms);
            while ((act = rtipc_action_next(conn))) {
                if (act->type == RTIPC_ACTION_SEND &&
                    send_with_faults(sock, peer, faults, payload_size,
                                     act) != 0) {
                    rtipc_action_clear(conn);
                    return -1;
                }
                if (act->type == RTIPC_ACTION_DISCONNECTED) {
                    result->protocol_errors++;
                    rtipc_action_clear(conn);
                    return -1;
                }
            }
            rtipc_action_clear(conn);

            uint64_t progress_now;
            if (now_ms(&progress_now) != 0)
                return -1;
            if (progress_now - last_progress >= 5000)
            {
                report_progress(payload_size, i, result, conn,
                                progress_now - last_receive);
                last_progress = progress_now;
            }
        }

        if (!got) {
            result->request_timeouts++;
            return -1;
        }

        uint64_t request_now;
        if (now_ms(&request_now) != 0)
            return -1;
        if (request_now - last_progress >= 5000)
        {
            report_progress(payload_size, i, result, conn,
                            request_now - last_receive);
            last_progress = request_now;
        }
    }

    uint64_t completed_ms;
    if (now_ms(&completed_ms) != 0)
        return -1;
    result->total_time_ms = completed_ms - test_start;
    return 0;
}

int main(int argc, char *argv[])
{
    const char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;
    int count = DEFAULT_COUNT;
    rtipc_fault_profile_t fault_profile = RTIPC_FAULT_PROFILE_NONE;
    int sizes[MAX_PAYLOAD_SIZES] = {64, 256, 1024};

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fault-profile") && i + 1 < argc) {
            if (rtipc_fault_profile_parse(argv[++i], &fault_profile) != 0) {
                fprintf(stderr, "invalid --fault-profile: %s\n", argv[i]);
                return 2;
            }
        }
    }

    if (count <= 0 ||
        (fault_profile == RTIPC_FAULT_PROFILE_RELIABILITY && count < 2)) {
        fprintf(stderr, "count must be positive and at least 2 for reliability faults\n");
        return 2;
    }

    printf("=== RT-IPC Benchmark Client ===\n");
    printf("Target: %s:%d, count=%d per size\n\n", host, port, count);
    printf("[client] fault profile: %s\n",
           rtipc_fault_profile_name(fault_profile));
    fflush(stdout);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return 1; }

    struct sockaddr_in peer = {0};
    peer.sin_family = AF_INET;
    peer.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &peer.sin_addr) != 1) {
        fprintf(stderr, "invalid server address: %s\n", host);
        close(sock);
        return 2;
    }
    if (connect(sock, (struct sockaddr *)&peer, sizeof(peer)) != 0) {
        perror("connect");
        close(sock);
        return 1;
    }

    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = true;
    cfg.heartbeat_interval_ms = 1000;
    cfg.heartbeat_timeout_ms = 10000;
    cfg.max_retries = 5;
    cfg.reconnect_initial_delay_ms = 100;
    cfg.reconnect_max_delay_ms = 1000;
    if (generate_session_seed(&cfg.session_id_seed) != 0) {
        close(sock);
        return 1;
    }

    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    rtipc_fault_context_t faults;
    rtipc_fault_init(&faults, fault_profile);

    /* Handshake */
    printf("[client] connecting...\n");
    fflush(stdout);
    uint64_t connect_ms;
    if (now_ms(&connect_ms) != 0) {
        close(sock);
        return 1;
    }
    uint64_t handshake_deadline_ms = connect_ms + HANDSHAKE_TIMEOUT_MS;
    rtipc_connection_connect(&conn, connect_ms);

    uint8_t recv_buf[RTIPC_MAX_PACKET];
    while (!rtipc_connection_is_connected(&conn)) {
        const rtipc_action_t *act;
        uint64_t current_ms;
        if (now_ms(&current_ms) != 0) {
            close(sock);
            return 1;
        }
        if (current_ms >= handshake_deadline_ms)
            break;

        while ((act = rtipc_action_next(&conn))) {
            if (act->type == RTIPC_ACTION_SEND &&
                send_datagram(sock, &peer, act->data, act->data_len) != 0) {
                perror("send handshake");
                rtipc_action_clear(&conn);
                close(sock);
                return 1;
            }
        }
        rtipc_action_clear(&conn);
        uint64_t tick_ms;
        if (now_ms(&tick_ms) != 0) {
            close(sock);
            return 1;
        }
        rtipc_connection_tick(&conn, tick_ms);
        while ((act = rtipc_action_next(&conn))) {
            if (act->type == RTIPC_ACTION_SEND &&
                send_datagram(sock, &peer, act->data, act->data_len) != 0) {
                perror("resend handshake");
                rtipc_action_clear(&conn);
                close(sock);
                return 1;
            }
        }
        rtipc_action_clear(&conn);

        if (now_ms(&current_ms) != 0) {
            close(sock);
            return 1;
        }
        if (current_ms >= handshake_deadline_ms)
            break;
        uint64_t remaining_ms = handshake_deadline_ms - current_ms;
        uint64_t wait_ms = remaining_ms < 100 ? remaining_ms : 100;
        fd_set rfds;
        struct timeval tv = {
            .tv_sec = (time_t)(wait_ms / 1000),
            .tv_usec = (suseconds_t)((wait_ms % 1000) * 1000),
        };
        FD_ZERO(&rfds); FD_SET(sock, &rfds);
        int ready = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (ready < 0 && errno != EINTR) {
            perror("select handshake");
            close(sock);
            return 1;
        }
        if (ready > 0) {
            ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0, NULL, NULL);
            if (n > 0) {
                uint64_t received_ms;
                if (now_ms(&received_ms) != 0) {
                    close(sock);
                    return 1;
                }
                rtipc_connection_on_recv(&conn, recv_buf, n, received_ms);
            }
        }
        if (now_ms(&tick_ms) != 0) {
            close(sock);
            return 1;
        }
        rtipc_connection_tick(&conn, tick_ms);
        const rtipc_action_t *a;
        while ((a = rtipc_action_next(&conn))) {
            if (a->type == RTIPC_ACTION_SEND)
                sendto(sock, a->data, a->data_len, 0,
                       (struct sockaddr *)&peer, sizeof(peer));
        }
        rtipc_action_clear(&conn);
    }

    if (!rtipc_connection_is_connected(&conn)) {
        printf("RTIPC_FAILURE reason=connect_timeout timeout_ms=%d\n",
               HANDSHAKE_TIMEOUT_MS);
        printf("[client] FAILED to connect\n");
        return 1;
    }
    printf("[client] connected!\n\n");
    fflush(stdout);

    int all_tests_passed = 1;

    /* Run tests for each payload size */
    for (int si = 0; si < MAX_PAYLOAD_SIZES; si++) {
        test_result_t result;
        rtipc_stats_t stats_before = rtipc_connection_stats(&conn);
        printf("--- Payload %dB ---\n", sizes[si]);
        fflush(stdout);

        int test_rc = run_test(sock, &peer, sizes[si], count, &conn, &faults,
                               &result);
        rtipc_stats_t stats_after = rtipc_connection_stats(&conn);

        if (result.received < 0 ||
            rtipc_client_prepare_rtt_samples(
                result.rtt_samples, (size_t)count,
                (size_t)result.received) != 0) {
            fprintf(stderr,
                    "[client] invalid RTT result storage for payload=%d\n",
                    sizes[si]);
            if (result.rtt_samples != NULL)
                free(result.rtt_samples);
            all_tests_passed = 0;
            break;
        }
        uint64_t avg = result.received > 0 ? result.sum_rtt / result.received : 0;
        uint64_t p50 = percentile(result.rtt_samples, result.received, 0.50);
        uint64_t p95 = percentile(result.rtt_samples, result.received, 0.95);
        uint64_t p99 = percentile(result.rtt_samples, result.received, 0.99);
        uint64_t p999 = percentile(result.rtt_samples, result.received, 0.999);
        uint64_t min_rtt = result.received > 0 ? result.min_rtt : 0;

        int loss = result.sent > 0 ? (result.sent - result.received) * 100 / result.sent : 0;

        printf("  sent=%d  recv=%d  loss=%d%%\n", result.sent, result.received, loss);
        printf("  RTT: min=%llums avg=%llums max=%llums P50=%llums P95=%llums P99=%llums P99.9=%llums\n",
               (unsigned long long)min_rtt, (unsigned long long)avg,
               (unsigned long long)result.max_rtt,
               (unsigned long long)p50, (unsigned long long)p95,
               (unsigned long long)p99, (unsigned long long)p999);
        if (result.received > 0 && result.total_time_ms > 0) {
            double throughput = (double)result.total_bytes * 1000.0 /
                                (double)result.total_time_ms / 1024.0;
            printf("  throughput=%.2fKiB/s\n", throughput);
        }
        printf("  request_timeouts=%llu protocol_errors=%llu reconnects=%llu\n",
               (unsigned long long)result.request_timeouts,
               (unsigned long long)result.protocol_errors,
               (unsigned long long)result.reconnects);
        printf("  transport: retrans=%u timeouts=%u dup=%u reorder=%u errors=%u\n",
               stats_after.retransmissions - stats_before.retransmissions,
               stats_after.timeouts - stats_before.timeouts,
               stats_after.rx_duplicates - stats_before.rx_duplicates,
               stats_after.rx_out_of_order - stats_before.rx_out_of_order,
               stats_after.rx_errors - stats_before.rx_errors);
        printf("\n");
        fflush(stdout);

        if (result.rtt_samples != NULL)
            free(result.rtt_samples);

        if (test_rc != 0 || result.sent != count || result.received != count ||
            result.request_timeouts != 0 || result.protocol_errors != 0) {
            all_tests_passed = 0;
            break;
        }
    }

    if (!all_tests_passed) {
        printf("========================================\n");
        printf("TESTS FAILED\n");
        printf("========================================\n");
        fflush(stdout);
        close(sock);
        return 1;
    }

    if (fault_profile == RTIPC_FAULT_PROFILE_RELIABILITY) {
        int fault_complete = faults.drop_done && faults.duplicate_done &&
                             faults.reorder_done && !faults.reorder_held;
        printf("[client] fault profile complete: drop=%d duplicate=%d reorder=%d\n",
               faults.drop_done ? 1 : 0,
               faults.duplicate_done ? 1 : 0,
               faults.reorder_done && !faults.reorder_held ? 1 : 0);
        fflush(stdout);
        if (!fault_complete) {
            close(sock);
            return 1;
        }
    }

    rtipc_client_shutdown_result_t shutdown_result =
        rtipc_client_shutdown(sock, &peer, &conn);
    if (shutdown_result != RTIPC_CLIENT_SHUTDOWN_OK) {
        fprintf(stderr, "[client] graceful shutdown failed: %d\n",
                shutdown_result);
        close(sock);
        return 1;
    }

    printf("========================================\n");
    printf("ALL TESTS COMPLETE\n");
    printf("========================================\n");
    fflush(stdout);

    close(sock);
    return 0;
}
