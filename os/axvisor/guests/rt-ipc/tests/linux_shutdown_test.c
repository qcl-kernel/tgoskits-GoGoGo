#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "../common/rt_ipc.h"
#include "../linux/rtipc_client_report.h"
#include "../linux/rtipc_shutdown.h"

#define CLIENT_PATH "/proc/self/cwd/../linux/target/rtipic-client-host"
#define CLOCK_FAIL_CLIENT_PATH "/proc/self/cwd/../linux/target/rtipic-client-clock-fail"
#define CASE_DEADLINE_MS 10000U
#define OUTPUT_CAPACITY 65536U

typedef enum {
    FIN_ACK_SECOND,
    FIN_ACK_NEVER,
} fin_peer_behavior_t;

typedef struct {
    int exit_code;
    unsigned fin_packets;
    uint64_t elapsed_ms;
    char output[OUTPUT_CAPACITY];
    size_t output_len;
} client_result_t;

static unsigned clock_call_count;
static unsigned clock_fail_call;

int __real_clock_gettime(clockid_t clock_id, struct timespec *time);

int __wrap_clock_gettime(clockid_t clock_id, struct timespec *time)
{
    if (clock_fail_call != 0) {
        clock_call_count++;
        if (clock_call_count == clock_fail_call) {
            errno = EIO;
            return -1;
        }
    }
    return __real_clock_gettime(clock_id, time);
}

static uint64_t monotonic_ms(void)
{
    struct timespec time;

    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0)
        return 0;
    return (uint64_t)time.tv_sec * 1000U +
           (uint64_t)time.tv_nsec / 1000000U;
}

static int send_packet(int socket_fd, const struct sockaddr_in *peer,
                       socklen_t peer_length, rtipc_msg_type_t type,
                       uint32_t sequence, uint64_t session_id,
                       const uint8_t *payload,
                       size_t payload_length)
{
    uint8_t packet[RTIPC_MAX_PACKET];
    rtipc_header_t header = {0};

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = type;
    header.seq_num = sequence;
    header.session_id = session_id;
    size_t packet_length = rtipc_build_packet(
        &header, payload, payload_length, packet, sizeof(packet));
    if (packet_length == 0)
        return -1;
    ssize_t sent = sendto(socket_fd, packet, packet_length, 0,
                          (const struct sockaddr *)peer, peer_length);
    return sent == (ssize_t)packet_length ? 0 : -1;
}

static int open_udp_pair(int *client_fd, int *server_fd,
                         struct sockaddr_in *server,
                         struct sockaddr_in *client)
{
    *client_fd = socket(AF_INET, SOCK_DGRAM, 0);
    *server_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (*client_fd < 0 || *server_fd < 0)
        return -1;

    struct sockaddr_in bind_address = {0};
    bind_address.sin_family = AF_INET;
    bind_address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(*client_fd, (const struct sockaddr *)&bind_address,
             sizeof(bind_address)) != 0 ||
        bind(*server_fd, (const struct sockaddr *)&bind_address,
             sizeof(bind_address)) != 0)
        return -1;

    socklen_t address_length = sizeof(*server);
    if (getsockname(*server_fd, (struct sockaddr *)server,
                    &address_length) != 0)
        return -1;
    address_length = sizeof(*client);
    return getsockname(*client_fd, (struct sockaddr *)client,
                       &address_length);
}

static void initialize_shutdown_connection(rtipc_connection_t *connection)
{
    rtipc_config_t config;

    rtipc_config_default(&config);
    config.rto_ms = 1;
    config.max_retries = 0;
    rtipc_connection_init(connection, &config);
    connection->state = RTIPC_STATE_CONNECTED;
}

static int shutdown_clock_failures_are_io_errors(void)
{
    static const struct {
        unsigned failure_call;
        bool queue_ack;
        const char *name;
    } cases[] = {
        {1, false, "start"},
        {3, false, "tick"},
        {3, true, "receive"},
    };

    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        int client_fd = -1;
        int server_fd = -1;
        struct sockaddr_in server = {0};
        struct sockaddr_in client = {0};
        rtipc_connection_t connection;

        if (open_udp_pair(&client_fd, &server_fd, &server, &client) != 0) {
            if (client_fd >= 0)
                close(client_fd);
            if (server_fd >= 0)
                close(server_fd);
            return -1;
        }
        initialize_shutdown_connection(&connection);

        if (cases[index].queue_ack) {
            if (send_packet(server_fd, &client, sizeof(client), RTIPC_MSG_ACK,
                            connection.control_seq, connection.session_id,
                            NULL, 0) != 0) {
                close(client_fd);
                close(server_fd);
                return -1;
            }
        }

        clock_call_count = 0;
        clock_fail_call = cases[index].failure_call;
        rtipc_client_shutdown_result_t result = rtipc_client_shutdown(
            client_fd, &server, &connection);
        clock_fail_call = 0;
        close(client_fd);
        close(server_fd);

        if (result != RTIPC_CLIENT_SHUTDOWN_IO_ERROR) {
            fprintf(stderr,
                    "clock failure at %s returned=%d calls=%u state=%d\n",
                    cases[index].name, result, clock_call_count,
                    connection.state);
            return -1;
        }
    }
    return 0;
}

static int invalid_result_storage_is_rejected(void)
{
    uint64_t samples[] = {9, 2, 5};

    if (rtipc_client_prepare_rtt_samples(NULL, 1, 0) == 0 ||
        rtipc_client_prepare_rtt_samples(samples, 2, 3) == 0 ||
        rtipc_client_prepare_rtt_samples(samples, 3, 3) != 0 ||
        samples[0] != 2 || samples[1] != 5 || samples[2] != 9) {
        fprintf(stderr, "RTT result storage validation failed\n");
        return -1;
    }
    return 0;
}

static int service_packet(int socket_fd, fin_peer_behavior_t behavior,
                          unsigned *fin_packets)
{
    uint8_t packet[RTIPC_MAX_PACKET];
    struct sockaddr_in client;
    socklen_t client_length = sizeof(client);
    ssize_t received = recvfrom(socket_fd, packet, sizeof(packet), 0,
                                (struct sockaddr *)&client, &client_length);
    if (received < 0)
        return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -1;

    rtipc_header_t header;
    if (rtipc_header_parse(packet, (size_t)received, &header) != 0)
        return -1;
    if ((size_t)received !=
            (size_t)RTIPC_HEADER_SIZE + (size_t)header.payload_len ||
        !rtipc_verify_packet(&header, packet + RTIPC_HEADER_SIZE,
                             header.payload_len))
        return -1;

    switch (header.msg_type) {
    case RTIPC_MSG_SYN:
        return send_packet(socket_fd, &client, client_length,
                           RTIPC_MSG_SYNACK, header.seq_num, header.session_id,
                           NULL, 0);
    case RTIPC_MSG_CTRL_CMD:
        if (send_packet(socket_fd, &client, client_length, RTIPC_MSG_ACK,
                        header.seq_num, header.session_id, NULL, 0) != 0)
            return -1;
        return send_packet(socket_fd, &client, client_length,
                           RTIPC_MSG_STATUS_REP, header.seq_num,
                           header.session_id,
                           packet + RTIPC_HEADER_SIZE, header.payload_len);
    case RTIPC_MSG_HEARTBEAT:
        return send_packet(socket_fd, &client, client_length,
                           RTIPC_MSG_HEARTBEAT_ACK, header.seq_num,
                           header.session_id, NULL, 0);
    case RTIPC_MSG_FIN:
        (*fin_packets)++;
        if (behavior == FIN_ACK_SECOND && *fin_packets >= 2) {
            return send_packet(socket_fd, &client, client_length,
                               RTIPC_MSG_ACK, header.seq_num,
                               header.session_id, NULL, 0);
        }
        return 0;
    default:
        return 0;
    }
}

static void read_child_output(int output_fd, client_result_t *result)
{
    while (result->output_len + 1 < sizeof(result->output)) {
        ssize_t count = read(output_fd,
                             result->output + result->output_len,
                             sizeof(result->output) - result->output_len - 1);
        if (count > 0) {
            result->output_len += (size_t)count;
            result->output[result->output_len] = '\0';
            continue;
        }
        if (count < 0 && errno == EINTR)
            continue;
        break;
    }
}

static int run_client_case(fin_peer_behavior_t behavior,
                           const char *client_path,
                           const char *clock_failure_call,
                           client_result_t *result)
{
    int server_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (server_fd < 0)
        return -1;

    struct sockaddr_in server = {0};
    server.sin_family = AF_INET;
    server.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server_fd, (const struct sockaddr *)&server, sizeof(server)) != 0) {
        close(server_fd);
        return -1;
    }
    socklen_t server_length = sizeof(server);
    if (getsockname(server_fd, (struct sockaddr *)&server,
                    &server_length) != 0) {
        close(server_fd);
        return -1;
    }

    int output_pipe[2];
    if (pipe(output_pipe) != 0) {
        close(server_fd);
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        close(output_pipe[0]);
        close(output_pipe[1]);
        close(server_fd);
        return -1;
    }
    if (child == 0) {
        char port[16];
        snprintf(port, sizeof(port), "%u", ntohs(server.sin_port));
        close(output_pipe[0]);
        close(server_fd);
        if (dup2(output_pipe[1], STDOUT_FILENO) < 0 ||
            dup2(output_pipe[1], STDERR_FILENO) < 0)
            _exit(126);
        close(output_pipe[1]);
        if (clock_failure_call != NULL &&
            setenv("RTIPC_FAIL_CLOCK_CALL", clock_failure_call, 1) != 0)
            _exit(125);
        execl(client_path, client_path, "--host", "127.0.0.1", "--port",
              port, "--count", "1", (char *)NULL);
        _exit(127);
    }

    close(output_pipe[1]);
    int flags = fcntl(output_pipe[0], F_GETFL, 0);
    if (flags >= 0)
        (void)fcntl(output_pipe[0], F_SETFL, flags | O_NONBLOCK);

    memset(result, 0, sizeof(*result));
    uint64_t started_ms = monotonic_ms();
    uint64_t deadline_ms = started_ms + CASE_DEADLINE_MS;
    int status = 0;
    bool child_done = false;

    while (!child_done && monotonic_ms() < deadline_ms) {
        fd_set read_fds;
        struct timeval wait = {0, 20000};
        FD_ZERO(&read_fds);
        FD_SET(server_fd, &read_fds);
        FD_SET(output_pipe[0], &read_fds);
        int max_fd = server_fd > output_pipe[0] ? server_fd : output_pipe[0];
        int ready = select(max_fd + 1, &read_fds, NULL, NULL, &wait);
        if (ready < 0 && errno != EINTR) {
            kill(child, SIGKILL);
            (void)waitpid(child, &status, 0);
            close(output_pipe[0]);
            close(server_fd);
            return -1;
        }
        if (ready > 0 && FD_ISSET(server_fd, &read_fds) &&
            service_packet(server_fd, behavior, &result->fin_packets) != 0) {
            kill(child, SIGKILL);
            (void)waitpid(child, &status, 0);
            close(output_pipe[0]);
            close(server_fd);
            return -1;
        }
        if (ready > 0 && FD_ISSET(output_pipe[0], &read_fds))
            read_child_output(output_pipe[0], result);

        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child)
            child_done = true;
        else if (waited < 0) {
            close(output_pipe[0]);
            close(server_fd);
            return -1;
        }
    }

    if (!child_done) {
        kill(child, SIGKILL);
        (void)waitpid(child, &status, 0);
        close(output_pipe[0]);
        close(server_fd);
        return -1;
    }
    read_child_output(output_pipe[0], result);
    result->elapsed_ms = monotonic_ms() - started_ms;
    result->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    close(output_pipe[0]);
    close(server_fd);
    return 0;
}

static int lost_first_fin_is_retransmitted(void)
{
    client_result_t result;

    if (run_client_case(FIN_ACK_SECOND, CLIENT_PATH, NULL, &result) != 0)
        return -1;
    if (result.exit_code != 0 || result.fin_packets < 2 ||
        strstr(result.output, "ALL TESTS COMPLETE") == NULL) {
        fprintf(stderr,
                "lost FIN did not recover: exit=%d fins=%u elapsed=%llums success=%d\n%s",
                result.exit_code, result.fin_packets,
                (unsigned long long)result.elapsed_ms,
                strstr(result.output, "ALL TESTS COMPLETE") != NULL,
                result.output);
        return -1;
    }
    return 0;
}

static int fin_retry_exhaustion_is_failure(void)
{
    client_result_t result;

    if (run_client_case(FIN_ACK_NEVER, CLIENT_PATH, NULL, &result) != 0)
        return -1;
    if (result.exit_code == 0 || result.fin_packets < 2 ||
        strstr(result.output, "ALL TESTS COMPLETE") != NULL ||
        result.elapsed_ms >= CASE_DEADLINE_MS) {
        fprintf(stderr,
                "FIN exhaustion reported success: exit=%d fins=%u elapsed=%llums success=%d\n%s",
                result.exit_code, result.fin_packets,
                (unsigned long long)result.elapsed_ms,
                strstr(result.output, "ALL TESTS COMPLETE") != NULL,
                result.output);
        return -1;
    }
    return 0;
}

static int main_client_clock_failure_is_fatal(void)
{
    unsigned tested_failures = 0;

    for (unsigned call = 1; call <= 128; call++) {
        client_result_t result;
        char failure_call[16];
        snprintf(failure_call, sizeof(failure_call), "%u", call);

        if (run_client_case(FIN_ACK_SECOND, CLOCK_FAIL_CLIENT_PATH,
                            failure_call, &result) != 0)
            return -1;
        bool completed = strstr(result.output, "ALL TESTS COMPLETE") != NULL;
        if (result.exit_code == 0) {
            if (!completed || tested_failures == 0) {
                fprintf(stderr,
                        "clock failure sweep reached invalid sentinel: call=%u tested=%u success=%d\n%s",
                        call, tested_failures, completed, result.output);
                return -1;
            }
            return 0;
        }
        if (completed) {
            fprintf(stderr,
                    "clock failure call=%u exited=%d but printed success\n%s",
                    call, result.exit_code, result.output);
            return -1;
        }
        tested_failures++;
    }

    fprintf(stderr, "clock failure sweep did not reach success sentinel\n");
    return -1;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "lost_first_fin") == 0)
        return lost_first_fin_is_retransmitted() == 0 ? 0 : 1;
    if (argc == 2 && strcmp(argv[1], "fin_exhaustion") == 0)
        return fin_retry_exhaustion_is_failure() == 0 ? 0 : 1;
    if (argc == 2 && strcmp(argv[1], "clock_error") == 0)
        return shutdown_clock_failures_are_io_errors() == 0 ? 0 : 1;
    if (argc == 2 && strcmp(argv[1], "result_storage") == 0)
        return invalid_result_storage_is_rejected() == 0 ? 0 : 1;
    if (argc == 2 && strcmp(argv[1], "main_clock_error") == 0)
        return main_client_clock_failure_is_fatal() == 0 ? 0 : 1;
    if (argc != 1)
        return 2;
    if (lost_first_fin_is_retransmitted() != 0)
        return 1;
    if (fin_retry_exhaustion_is_failure() != 0)
        return 1;
    if (shutdown_clock_failures_are_io_errors() != 0)
        return 1;
    if (invalid_result_storage_is_rejected() != 0)
        return 1;
    if (main_client_clock_failure_is_fatal() != 0)
        return 1;
    puts("PASS: Linux client reliable FIN shutdown");
    return 0;
}
