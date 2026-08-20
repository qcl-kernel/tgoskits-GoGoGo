#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define RTBENCH_NET_MAGIC UINT32_C(0x5254424e)
#define RTBENCH_NET_READY UINT32_C(0xffffffff)
#define RTBENCH_NET_PROBE_READY UINT32_C(0xfffffffe)

static void usage(const char *program)
{
    fprintf(stderr,
            "usage: %s --listen PORT --target IPV4 --port PORT --count N "
            "[--interval-us N]\n",
            program);
}

static int parse_uint(const char *text, unsigned long *value)
{
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 10);

    if (end == text || *end != '\0') {
        return -1;
    }
    *value = parsed;
    return 0;
}

static int wait_for_trigger(int socket_fd,
                            const struct sockaddr_in *target_address)
{
    uint32_t trigger[2];
    ssize_t received;

    for (;;) {
        do {
            received = recv(socket_fd, trigger, sizeof(trigger), 0);
        } while (received < 0 && errno == EINTR);
        if (received == (ssize_t)sizeof(trigger) &&
            ntohl(trigger[0]) == RTBENCH_NET_MAGIC) {
            return 0;
        }
        if (received < 0 &&
            (errno == EAGAIN || errno == EWOULDBLOCK ||
             errno == ETIMEDOUT)) {
            uint32_t probe_ready[2] = {
                htonl(RTBENCH_NET_MAGIC),
                htonl(RTBENCH_NET_PROBE_READY),
            };

            /* The first trigger can be lost while the guests are under
             * load. This distinct control marker asks RT-Thread to retry;
             * it cannot be mistaken for the trigger acknowledgement. */
            (void)sendto(socket_fd, probe_ready, sizeof(probe_ready), 0,
                         (const struct sockaddr *)target_address,
                         sizeof(*target_address));
            continue;
        }
        return -1;
    }
}

int main(int argc, char **argv)
{
    const char *target_text = NULL;
    unsigned long listen_port = 0;
    unsigned long target_port = 0;
    unsigned long count = 0;
    unsigned long interval_us = 2000;
    unsigned long retries = 0;
    struct sockaddr_in listen_address;
    struct sockaddr_in target_address;
    struct timeval trigger_timeout = {
        .tv_sec = 0,
        .tv_usec = 100000,
    };
    int socket_fd;
    int index;

    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--listen") == 0 && index + 1 < argc) {
            if (parse_uint(argv[++index], &listen_port) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[index], "--target") == 0 && index + 1 < argc) {
            target_text = argv[++index];
        } else if (strcmp(argv[index], "--port") == 0 && index + 1 < argc) {
            if (parse_uint(argv[++index], &target_port) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[index], "--count") == 0 && index + 1 < argc) {
            if (parse_uint(argv[++index], &count) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[index], "--interval-us") == 0 && index + 1 < argc) {
            if (parse_uint(argv[++index], &interval_us) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if (target_text == NULL || listen_port == 0 || listen_port > 65535 ||
        target_port == 0 || target_port > 65535 || count == 0 ||
        count > 100000) {
        usage(argv[0]);
        return 2;
    }

    socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (socket_fd < 0) {
        perror("socket");
        return 1;
    }
    memset(&listen_address, 0, sizeof(listen_address));
    listen_address.sin_family = AF_INET;
    listen_address.sin_port = htons((uint16_t)listen_port);
    listen_address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socket_fd, (struct sockaddr *)&listen_address,
             sizeof(listen_address)) != 0) {
        perror("bind");
        close(socket_fd);
        return 1;
    }
    memset(&target_address, 0, sizeof(target_address));
    target_address.sin_family = AF_INET;
    target_address.sin_port = htons((uint16_t)target_port);
    if (inet_pton(AF_INET, target_text, &target_address.sin_addr) != 1) {
        fprintf(stderr, "invalid target address: %s\n", target_text);
        close(socket_fd);
        return 2;
    }
    if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &trigger_timeout,
                   sizeof(trigger_timeout)) != 0) {
        perror("setsockopt");
        close(socket_fd);
        return 1;
    }

    printf("RTBENCH_NET_PROBE_READY listen=%lu count=%lu\n",
           listen_port, count);
    fflush(stdout);
    if (wait_for_trigger(socket_fd, &target_address) != 0) {
        fprintf(stderr, "invalid or interrupted RTBENCH trigger\n");
        close(socket_fd);
        return 1;
    }
    printf("RTBENCH_NET_PROBE_TRIGGERED count=%lu\n", count);
    fflush(stdout);
    {
        uint32_t ready[2] = {
            htonl(RTBENCH_NET_MAGIC),
            htonl(RTBENCH_NET_READY),
        };
        if (sendto(socket_fd, ready, sizeof(ready), 0,
                   (struct sockaddr *)&target_address,
                   sizeof(target_address)) != (ssize_t)sizeof(ready)) {
            perror("sendto ready");
            close(socket_fd);
            return 1;
        }
    }
    {
        struct timeval timeout = {
            .tv_sec = 0,
            .tv_usec = 100000,
        };
        if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout)) != 0) {
            perror("setsockopt");
            close(socket_fd);
            return 1;
        }
    }
    for (unsigned long sequence = 0; sequence < count; ++sequence) {
        uint32_t payload[2] = {
            htonl(RTBENCH_NET_MAGIC),
            htonl((uint32_t)sequence),
        };
        int acknowledged = 0;

        for (unsigned int attempt = 0; attempt < 4 && !acknowledged;
             ++attempt) {
            uint32_t ack[2];
            ssize_t received;

            if (sendto(socket_fd, payload, sizeof(payload), 0,
                       (struct sockaddr *)&target_address,
                       sizeof(target_address)) != (ssize_t)sizeof(payload)) {
                perror("sendto");
                close(socket_fd);
                return 1;
            }
            do {
                received = recv(socket_fd, ack, sizeof(ack), 0);
            } while (received < 0 && errno == EINTR);
            if (received == (ssize_t)sizeof(ack) &&
                ntohl(ack[0]) == RTBENCH_NET_MAGIC &&
                ntohl(ack[1]) == (uint32_t)sequence) {
                acknowledged = 1;
            } else if (received < 0 &&
                       (errno == EAGAIN || errno == EWOULDBLOCK ||
                        errno == ETIMEDOUT)) {
                retries++;
            }
        }
        if (!acknowledged) {
            fprintf(stderr, "probe sequence %lu was not acknowledged\n",
                    sequence);
            close(socket_fd);
            return 1;
        }
        if (interval_us != 0) {
            struct timespec delay = {
                .tv_sec = (time_t)(interval_us / 1000000UL),
                .tv_nsec = (long)((interval_us % 1000000UL) * 1000UL),
            };
            while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
            }
        }
    }
    printf("RTBENCH_NET_PROBE_END sent=%lu retries=%lu\n", count, retries);
    fflush(stdout);
    close(socket_fd);
    return 0;
}
