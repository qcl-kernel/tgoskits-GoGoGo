#include <rtthread.h>

#include "controller.h"
#include "rt_ipc.h"
#include "task3_protocol.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef int (*task3_server_reply_fn)(void *context, uint8_t message_type,
                                     const uint8_t *payload, size_t length,
                                     uint64_t now_ms);

typedef struct {
    task3_controller_t controller;
    task3_server_reply_fn send_reply;
    void *reply_context;
    task3_status_t cached_status;
    uint64_t requests;
    uint64_t errors;
    uint64_t duplicate_requests;
    int cached_status_valid;
    int stop_requested;
    int verbose;
} task3_server_app_t;

#ifdef TASK3_HOST_TEST
static uint64_t high_resolution_us(void)
{
    return 0;
}
#else
static uint64_t high_resolution_us(void)
{
    uint64_t counter;
    uint64_t frequency;

    __asm__ volatile("mrs %0, cntpct_el0" : "=r"(counter));
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
    if (frequency == 0) {
        return 0;
    }
    return counter / frequency * UINT64_C(1000000) +
           counter % frequency * UINT64_C(1000000) / frequency;
}
#endif

static uint32_t read_be32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
           (uint32_t)bytes[2] << 8 | bytes[3];
}

void task3_server_app_init(task3_server_app_t *app,
                           task3_server_reply_fn send_reply,
                           void *reply_context)
{
    memset(app, 0, sizeof(*app));
    task3_controller_init(&app->controller);
    app->send_reply = send_reply;
    app->reply_context = reply_context;
}

static int send_error(task3_server_app_t *app, const uint8_t *payload,
                      size_t length, int detail, uint64_t now_ms)
{
    task3_error_t error;
    uint8_t wire[TASK3_ERROR_WIRE_SIZE];

    memset(&error, 0, sizeof(error));
    error.category = TASK3_ERROR_CATEGORY_PROTOCOL;
    error.code = TASK3_APP_INVALID_COMMAND;
    if (payload != NULL && length >= 12) {
        error.frame_id = read_be32(payload + 8);
    }
    error.detail = (uint32_t)(detail < 0 ? -detail : detail);
    if (task3_encode_error(&error, wire) != TASK3_CODEC_OK) {
        return -1;
    }
    app->errors++;
    return app->send_reply(app->reply_context, RTIPC_MSG_ERROR_NOTIFY, wire,
                           sizeof(wire), now_ms);
}

int task3_server_handle_message(task3_server_app_t *app, uint8_t message_type,
                                const uint8_t *payload, size_t length,
                                uint64_t now_ms)
{
    task3_control_t control;
    task3_status_t status;
    uint8_t wire[TASK3_STATUS_WIRE_SIZE];
    uint64_t started;
    uint64_t finished;
    int result;

    if (app == NULL || app->send_reply == NULL ||
        (payload == NULL && length != 0)) {
        return -1;
    }
    app->requests++;
    if (message_type != RTIPC_MSG_CTRL_CMD) {
        return send_error(app, payload, length, TASK3_CODEC_INVALID_FIELD,
                          now_ms);
    }
    result = task3_decode_control(payload, length, &control);
    if (result != TASK3_CODEC_OK) {
        return send_error(app, payload, length, result, now_ms);
    }
    started = high_resolution_us();
    result = task3_controller_apply(&app->controller, &control, &status);
    finished = high_resolution_us();
    if (result != TASK3_APP_OK) {
        return send_error(app, payload, length, result, now_ms);
    }
    if ((status.flags & TASK3_STATUS_FLAG_DUPLICATE) != 0 &&
        app->cached_status_valid &&
        app->cached_status.frame_id == control.frame_id) {
        status = app->cached_status;
        status.flags |= TASK3_STATUS_FLAG_DUPLICATE;
        status.echoed_tx_monotonic_ns = control.tx_monotonic_ns;
        app->duplicate_requests++;
    } else {
        uint64_t elapsed = finished >= started ? finished - started : 0;

        status.processing_us =
            elapsed > UINT32_MAX ? UINT32_MAX : (uint32_t)elapsed;
        if (control.command == TASK3_CMD_STEP) {
            app->cached_status = status;
            app->cached_status_valid = 1;
        } else if (control.command == TASK3_CMD_RESET) {
            app->cached_status_valid = 0;
        }
    }
    if (control.command == TASK3_CMD_STOP) {
        app->stop_requested = 1;
    }
    if (app->verbose) {
        rt_kprintf("task3 frame=%u command=%u position=%d pwm=%d\n",
                   status.frame_id, control.command, status.actuator_q15,
                   status.pwm);
    }
    if (task3_encode_status(&status, wire) != TASK3_CODEC_OK) {
        return -1;
    }
    return app->send_reply(app->reply_context, RTIPC_MSG_STATUS_REP, wire,
                           sizeof(wire), now_ms);
}

#ifndef TASK3_HOST_TEST

#include "session.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdev.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
    TASK3_SERVER_PORT = 9876,
    TASK3_SERVER_STACK_SIZE = 16384,
    TASK3_SERVER_PRIORITY = 15,
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
#ifdef TASK3_FAULT_DROP_STATUS_ONCE
    if (!server->dropped_status && length >= RTIPC_HEADER_SIZE &&
        bytes[1] == RTIPC_MSG_STATUS_REP) {
        server->dropped_status = 1;
        rt_kprintf("TASK3_FAULT_DROP_STATUS dropped=1\n");
        return 0;
    }
#endif
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
    int attempts;

    for (attempts = 0; attempts < 300; attempts++) {
        device = netdev_get_by_family(AF_INET);
        if (device != RT_NULL && netdev_is_up(device) &&
            netdev_is_link_up(device)) {
            ip_addr_t address;
            ip_addr_t netmask;
            ip_addr_t gateway;

            inet_aton("192.168.77.30", &address);
            inet_aton("255.255.255.0", &netmask);
            inet_aton("0.0.0.0", &gateway);
            netdev_set_ipaddr(device, &address);
            netdev_set_netmask(device, &netmask);
            netdev_set_gw(device, &gateway);
            return 0;
        }
        rt_thread_mdelay(100);
    }
    return -1;
}

static void task3_server_entry(void *parameter)
{
    struct sockaddr_in local_address;
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 10000};
    uint64_t next_report;

    (void)parameter;
    memset(&runtime, 0, sizeof(runtime));
    runtime.socket_fd = -1;
    if (wait_for_network() != 0) {
        rt_kprintf("TASK3_RTOS_ERROR network-timeout\n");
        return;
    }
    runtime.socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (runtime.socket_fd < 0) {
        rt_kprintf("TASK3_RTOS_ERROR socket\n");
        return;
    }
    setsockopt(runtime.socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               sizeof(timeout));
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
    task3_session_init(&runtime.session, TASK3_SESSION_SERVER, send_datagram,
                       deliver_message, &runtime);
    rt_kprintf("TASK3_RTOS_READY ip=192.168.77.30 port=9876\n");
    next_report = now_ms() + 5000;
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
        if (timestamp >= next_report) {
            rt_kprintf("TASK3_RTOS_STATS requests=%llu errors=%llu duplicates=%llu "
                       "retries=%llu\n",
                       (unsigned long long)runtime.app.requests,
                       (unsigned long long)runtime.app.errors,
                       (unsigned long long)runtime.app.duplicate_requests,
                       (unsigned long long)
                           runtime.session.counters.transport_retries);
            next_report = timestamp + 5000;
        }
    }
    rt_kprintf("TASK3_RTOS_FINAL requests=%llu errors=%llu duplicates=%llu "
               "applied_steps=%llu retries=%llu\n",
               (unsigned long long)runtime.app.requests,
               (unsigned long long)runtime.app.errors,
               (unsigned long long)runtime.app.duplicate_requests,
               (unsigned long long)runtime.app.controller.applied_steps,
               (unsigned long long)
                   runtime.session.counters.transport_retries);
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
