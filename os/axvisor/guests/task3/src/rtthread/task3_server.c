#include <rtthread.h>

#include "controller.h"
#include "rt_ipc.h"
#include "task3_server_core.h"
#include "task3_protocol.h"

#ifndef TASK3_HOST_TEST
#include <drivers/ofw.h>

#include "session.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdev.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
    TASK3_SERVER_PORT = 9877,
    TASK3_SERVER_STACK_SIZE = 16384,
    TASK3_SERVER_PRIORITY = 15,
    TASK3_SERVER_RECV_TIMEOUT_MS = 10,
    TASK3_SERVER_TICK = 5,
};

typedef struct {
    task3_server_app_t app;
    task3_session_t session;
    int socket_fd;
    struct sockaddr_in peer;
    socklen_t peer_length;
    int have_peer;
    int dropped_status;
    int drop_status_once;
} task3_server_runtime_t;

static task3_server_runtime_t runtime;
static uint8_t receive_buffer[RTIPC_MAX_PACKET];

static uint64_t now_ms(void)
{
    return (uint64_t)rt_tick_get_millisecond();
}

static int send_datagram(void *context, const uint8_t *bytes, size_t length)
{
    task3_server_runtime_t *server = context;
    ssize_t sent;

    if (!server->have_peer) {
        return -1;
    }
    if (server->drop_status_once && !server->dropped_status &&
        length >= RTIPC_HEADER_SIZE &&
        bytes[1] == RTIPC_MSG_STATUS_REP) {
        server->dropped_status = 1;
        rt_kprintf("TASK3_FAULT_DROP_STATUS dropped=1\n");
        return 0;
    }
    sent = sendto(server->socket_fd, bytes, length, 0,
                  (struct sockaddr *)&server->peer, server->peer_length);
    return sent == (ssize_t)length ? 0 : -1;
}

static int send_application_reply(void *context, uint8_t message_type,
                                  const uint8_t *payload, size_t length,
                                  uint64_t timestamp_ms)
{
    task3_server_runtime_t *server = context;

    return task3_session_send(&server->session,
                              (rtipc_msg_type_t)message_type, payload, length,
                              timestamp_ms);
}

static int deliver_message(void *context, uint8_t message_type,
                           const uint8_t *payload, size_t length,
                           uint64_t timestamp_ms)
{
    task3_server_runtime_t *server = context;

    return task3_server_handle_message(&server->app, message_type, payload,
                                       length, timestamp_ms);
}

static int wait_for_network(void)
{
    struct netdev *device;
    ip_addr_t address;
    int attempts;

    if (inet_aton("192.168.77.30", &address) != 1) {
        return -1;
    }
    for (attempts = 0; attempts < 300; attempts++) {
        device = netdev_get_by_family(AF_INET);
        if (device != RT_NULL && netdev_is_up(device) &&
            netdev_is_link_up(device) &&
            ip_addr_cmp(&device->ip_addr, &address)) {
            return 0;
        }
        rt_thread_mdelay(100);
    }
    return -1;
}

static int configure_receive_timeout(int socket_fd)
{
    struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = TASK3_SERVER_RECV_TIMEOUT_MS * 1000,
    };

    return setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                      sizeof(timeout));
}

static void configure_runtime_faults(task3_server_runtime_t *server)
{
#ifdef TASK3_HOST_TEST
    (void)server;
#else
    const char *fault = rt_ofw_bootargs_select("task3.fault=", 0);

    if (fault == RT_NULL) {
        return;
    }
    if (rt_strcmp(fault, "drop-status") == 0) {
        server->drop_status_once = 1;
        rt_kprintf("TASK3_RTOS_FAULT drop-status\n");
    } else if (rt_strcmp(fault, "delayed-server") == 0) {
        rt_kprintf("TASK3_FAULT_DELAYED_SERVER delay_ms=%d\n", 3000);
        rt_thread_mdelay(3000);
    } else if (rt_strcmp(fault, "normal") != 0) {
        rt_kprintf("TASK3_RTOS_ERROR invalid-task3-fault\n");
    }
#endif
}

static void task3_server_entry(void *parameter)
{
    struct sockaddr_in local_address;

    (void)parameter;
    memset(&runtime, 0, sizeof(runtime));
    runtime.socket_fd = -1;
    configure_runtime_faults(&runtime);
    if (wait_for_network() != 0) {
        rt_kprintf("TASK3_RTOS_ERROR network-timeout\n");
        return;
    }
    runtime.socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (runtime.socket_fd < 0) {
        rt_kprintf("TASK3_RTOS_ERROR socket\n");
        return;
    }
    if (configure_receive_timeout(runtime.socket_fd) != 0) {
        rt_kprintf("TASK3_RTOS_ERROR receive-timeout\n");
        closesocket(runtime.socket_fd);
        runtime.socket_fd = -1;
        return;
    }
    memset(&local_address, 0, sizeof(local_address));
    local_address.sin_family = AF_INET;
    local_address.sin_port = htons(TASK3_SERVER_PORT);
    local_address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(runtime.socket_fd, (struct sockaddr *)&local_address,
             sizeof(local_address)) != 0) {
        rt_kprintf("TASK3_RTOS_ERROR bind\n");
        closesocket(runtime.socket_fd);
        runtime.socket_fd = -1;
        return;
    }
    task3_server_app_init(&runtime.app, send_application_reply, &runtime);
    task3_session_init(&runtime.session, TASK3_SESSION_SERVER,
                       (now_ms() ^ (uint64_t)(uintptr_t)&runtime) | UINT64_C(1),
                       send_datagram,
                       deliver_message, &runtime);
    rt_kprintf("TASK3_RTOS_READY ip=192.168.77.30 port=9877\n");
    while (!runtime.app.stop_requested) {
        struct sockaddr_in peer;
        socklen_t peer_length = sizeof(peer);
        ssize_t received =
            recvfrom(runtime.socket_fd, receive_buffer, sizeof(receive_buffer),
                     0, (struct sockaddr *)&peer, &peer_length);
        uint64_t timestamp = now_ms();

        if (received > 0) {
            runtime.peer = peer;
            runtime.peer_length = peer_length;
            runtime.have_peer = 1;
            (void)task3_session_on_datagram(&runtime.session, receive_buffer,
                                            (size_t)received, timestamp);
        } else if (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != ETIMEDOUT) {
            runtime.app.errors++;
        }
        (void)task3_session_tick(&runtime.session, timestamp);
    }
    rt_kprintf("TASK3_RTOS_FINAL requests=%llu errors=%llu duplicates=%llu "
               "applied_steps=%llu retries=%llu\n",
               (unsigned long long)runtime.app.requests,
               (unsigned long long)runtime.app.errors,
               (unsigned long long)runtime.app.duplicate_requests,
               (unsigned long long)runtime.app.applied_steps,
               (unsigned long long)
                   runtime.session.counters.transport_retries);
    rt_kprintf("TASK3_RTOS_FINAL_DONE\n");
    closesocket(runtime.socket_fd);
    runtime.socket_fd = -1;
}

int task3_server_start(void)
{
    rt_thread_t thread =
        rt_thread_create("task3_srv", task3_server_entry, RT_NULL,
                         TASK3_SERVER_STACK_SIZE, TASK3_SERVER_PRIORITY,
                         TASK3_SERVER_TICK);

    if (thread == RT_NULL) {
        return -1;
    }
    return rt_thread_startup(thread);
}
INIT_APP_EXPORT(task3_server_start);

#endif
