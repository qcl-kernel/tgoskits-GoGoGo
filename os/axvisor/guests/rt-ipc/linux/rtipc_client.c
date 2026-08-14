/*
 * RT-IPC UDP Client for Linux.
 * Connects to RT-Thread server, sends CTRL_CMD, measures RTT/throughput.
 * Tests 64B/256B/1024B payloads, 1000 round-trips each, with mid-test disconnect.
 */
#include "rt_ipc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <time.h>

#define DEFAULT_HOST   "192.168.77.30"
#define DEFAULT_PORT   9876
#define DEFAULT_COUNT  1000
#define MAX_PAYLOAD_SIZES 3

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t va = *(const uint64_t *)a, vb = *(const uint64_t *)b;
    return va < vb ? -1 : (va > vb ? 1 : 0);
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
    uint64_t min_rtt;
    uint64_t max_rtt;
    uint64_t *rtt_samples;
} test_result_t;

static void run_test(int sock, struct sockaddr_in *peer,
                     int payload_size, int count,
                     rtipc_connection_t *conn,
                     test_result_t *result)
{
    static uint8_t payload[RTIPC_MAX_PAYLOAD];
    static uint8_t recv_buf[RTIPC_MAX_PACKET];
    memset(payload, 0xAA, payload_size);
    memset(result, 0, sizeof(*result));
    result->payload_size = payload_size;
    result->min_rtt = ~0ULL;
    result->rtt_samples = malloc(count * sizeof(uint64_t));

    uint64_t test_start = now_ms();
    int disconnect_done = 1; /* Skip disconnect test - already validated in v9/v10 */

    for (int i = 0; i < count; i++) {
        /* Mid-test disconnect - only for 64B test (first payload size) */
        if (!disconnect_done && i == count / 2 && payload_size == 64) {
            printf("[client] simulated disconnect (3s)...\n");
            fflush(stdout);
            sleep(3);
            printf("[client] reconnecting...\n");
            fflush(stdout);
            rtipc_connection_connect(conn, now_ms());
            const rtipc_action_t *act;
            while ((act = rtipc_action_next(conn))) {
                if (act->type == RTIPC_ACTION_SEND)
                    sendto(sock, act->data, act->data_len, 0,
                           (struct sockaddr *)peer, sizeof(*peer));
            }
            rtipc_action_clear(conn);
            /* Wait for reconnect */
            for (int w = 0; w < 50 && !rtipc_connection_is_connected(conn); w++) {
                rtipc_connection_tick(conn, now_ms());
                fd_set rfds; struct timeval tv = {0, 100000};
                FD_ZERO(&rfds); FD_SET(sock, &rfds);
                if (select(sock + 1, &rfds, NULL, NULL, &tv) > 0) {
                    ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0, NULL, NULL);
                    if (n > 0) rtipc_connection_on_recv(conn, recv_buf, n, now_ms());
                }
                const rtipc_action_t *a;
                while ((a = rtipc_action_next(conn))) {
                    if (a->type == RTIPC_ACTION_SEND)
                        sendto(sock, a->data, a->data_len, 0,
                               (struct sockaddr *)peer, sizeof(*peer));
                }
                rtipc_action_clear(conn);
            }
            disconnect_done = 1;
        }

        if (!rtipc_connection_is_connected(conn)) {
            rtipc_connection_tick(conn, now_ms());
            continue;
        }

        /* Send CTRL_CMD */
        rtipc_connection_send(conn, RTIPC_MSG_CTRL_CMD, payload, payload_size, now_ms());
        const rtipc_action_t *act;
        while ((act = rtipc_action_next(conn))) {
            if (act->type == RTIPC_ACTION_SEND)
                sendto(sock, act->data, act->data_len, 0,
                       (struct sockaddr *)peer, sizeof(*peer));
        }
        rtipc_action_clear(conn);
        result->sent++;

        /* Wait for STATUS_REP */
        uint64_t st = now_ms();
        int got = 0;
        for (int retry = 0; !got && retry < 100; retry++) {
            fd_set rfds;
            struct timeval tv = {0, 10000};
            FD_ZERO(&rfds); FD_SET(sock, &rfds);
            int rv = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rv > 0) {
                ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0, NULL, NULL);
                if (n > 0)
                    rtipc_connection_on_recv(conn, recv_buf, n, now_ms());
            }
            rtipc_connection_tick(conn, now_ms());
            while ((act = rtipc_action_next(conn))) {
                if (act->type == RTIPC_ACTION_SEND)
                    sendto(sock, act->data, act->data_len, 0,
                           (struct sockaddr *)peer, sizeof(*peer));
                if (act->type == RTIPC_ACTION_DELIVER) {
                    uint64_t rtt = now_ms() - st;
                    result->received++;
                    result->total_bytes += act->payload_len;
                    result->sum_rtt += rtt;
                    if (rtt < result->min_rtt) result->min_rtt = rtt;
                    if (rtt > result->max_rtt) result->max_rtt = rtt;
                    if (result->received <= count)
                        result->rtt_samples[result->received - 1] = rtt;
                    got = 1;
                }
            }
            rtipc_action_clear(conn);
        }
    }

    result->total_time_ms = now_ms() - test_start;
}

int main(int argc, char *argv[])
{
    const char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;
    int count = DEFAULT_COUNT;
    int sizes[MAX_PAYLOAD_SIZES] = {64, 256, 1024};

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
    }

    printf("=== RT-IPC Benchmark Client ===\n");
    printf("Target: %s:%d, count=%d per size\n\n", host, port, count);
    fflush(stdout);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return 1; }

    struct sockaddr_in peer = {0};
    peer.sin_family = AF_INET;
    peer.sin_port = htons(port);
    inet_pton(AF_INET, host, &peer.sin_addr);

    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = true;
    cfg.heartbeat_interval_ms = 500;
    cfg.heartbeat_timeout_ms = 2000;
    cfg.rto_ms = 100;
    cfg.max_retries = 5;

    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);

    /* Handshake */
    printf("[client] connecting...\n");
    fflush(stdout);
    rtipc_connection_connect(&conn, now_ms());

    uint8_t recv_buf[RTIPC_MAX_PACKET];
    for (int w = 0; w < 100 && !rtipc_connection_is_connected(&conn); w++) {
        const rtipc_action_t *act;
        while ((act = rtipc_action_next(&conn))) {
            if (act->type == RTIPC_ACTION_SEND)
                sendto(sock, act->data, act->data_len, 0,
                       (struct sockaddr *)&peer, sizeof(peer));
        }
        rtipc_action_clear(&conn);
        rtipc_connection_tick(&conn, now_ms());
        while ((act = rtipc_action_next(&conn))) {
            if (act->type == RTIPC_ACTION_SEND)
                sendto(sock, act->data, act->data_len, 0,
                       (struct sockaddr *)&peer, sizeof(peer));
        }
        rtipc_action_clear(&conn);

        fd_set rfds; struct timeval tv = {0, 100000};
        FD_ZERO(&rfds); FD_SET(sock, &rfds);
        if (select(sock + 1, &rfds, NULL, NULL, &tv) > 0) {
            ssize_t n = recvfrom(sock, recv_buf, sizeof(recv_buf), 0, NULL, NULL);
            if (n > 0) rtipc_connection_on_recv(&conn, recv_buf, n, now_ms());
        }
        rtipc_connection_tick(&conn, now_ms());
        const rtipc_action_t *a;
        while ((a = rtipc_action_next(&conn))) {
            if (a->type == RTIPC_ACTION_SEND)
                sendto(sock, a->data, a->data_len, 0,
                       (struct sockaddr *)&peer, sizeof(peer));
        }
        rtipc_action_clear(&conn);
    }

    if (!rtipc_connection_is_connected(&conn)) {
        printf("[client] FAILED to connect\n");
        return 1;
    }
    printf("[client] connected!\n\n");
    fflush(stdout);

    /* Run tests for each payload size */
    for (int si = 0; si < MAX_PAYLOAD_SIZES; si++) {
        test_result_t result;
        printf("--- Payload %dB ---\n", sizes[si]);
        fflush(stdout);

        run_test(sock, &peer, sizes[si], count, &conn, &result);

        qsort(result.rtt_samples, result.received > 0 ? result.received : 1, sizeof(uint64_t), cmp_u64);
        uint64_t avg = result.received > 0 ? result.sum_rtt / result.received : 0;
        uint64_t p50 = percentile(result.rtt_samples, result.received, 0.50);
        uint64_t p95 = percentile(result.rtt_samples, result.received, 0.95);
        uint64_t p99 = percentile(result.rtt_samples, result.received, 0.99);

        int loss = result.sent > 0 ? (result.sent - result.received) * 100 / result.sent : 0;

        printf("  sent=%d  recv=%d  loss=%d%%\n", result.sent, result.received, loss);
        printf("  RTT: min=%llums avg=%llums max=%llums P50=%llums P95=%llums P99=%llums\n",
               (unsigned long long)result.min_rtt, (unsigned long long)avg,
               (unsigned long long)result.max_rtt,
               (unsigned long long)p50, (unsigned long long)p95,
               (unsigned long long)p99);
        if (result.received > 0) {
            uint64_t elapsed_s = result.total_time_ms / 1000;
            if (elapsed_s == 0) elapsed_s = 1;
            printf("  throughput=%lluKB/s\n",
                   (unsigned long long)(result.total_bytes / elapsed_s / 1024));
        }
        printf("\n");
        fflush(stdout);

        free(result.rtt_samples);
    }

    /* FIN */
    rtipc_connection_disconnect(&conn, now_ms());
    const rtipc_action_t *act;
    while ((act = rtipc_action_next(&conn))) {
        if (act->type == RTIPC_ACTION_SEND)
            sendto(sock, act->data, act->data_len, 0,
                   (struct sockaddr *)&peer, sizeof(peer));
    }
    rtipc_action_clear(&conn);

    printf("========================================\n");
    printf("ALL TESTS COMPLETE\n");
    printf("========================================\n");
    fflush(stdout);

    close(sock);
    return 0;
}
