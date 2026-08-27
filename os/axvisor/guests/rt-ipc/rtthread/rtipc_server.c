/*
 * RT-IPC UDP Server for RT-Thread.
 * Listens on 192.168.77.30:9876, responds to CTRL_CMD with STATUS_REP.
 * Event-driven: blocks on recvfrom, no polling timer.
 */
#include <rtthread.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netdev.h>
#include <sys/time.h>
#include <string.h>
#include "rt_ipc.h"
#include "rtipc_echo_responder.h"
#include "rtipc_peer.h"
#include "rtipc_server_status.h"
#include "rtipc_time.h"

#define DBG_TAG "rtipic.srv"
#define DBG_LVL DBG_INFO
#include <rtdbg.h>

#define RTIPC_PORT       9876
#define SERVER_IP        "192.168.77.30"
#define SERVER_NM        "255.255.255.0"
#define SERVER_GW        "192.168.77.1"
#define RECV_TIMEOUT_MS  100
#define FIN_TOMBSTONE_MARGIN_MS 100

static rtipc_connection_t s_conn;
static uint8_t s_recv_buf[RTIPC_MAX_PACKET];
static rtipc_tick_extender_t s_clock;

static uint64_t now_ms(void)
{
    return rtipc_tick_extender_update(
        &s_clock, (uint32_t)rt_tick_get_millisecond());
}

static void report_server_error(const char *stage, int error)
{
    LOG_E("RTIPC_SERVER_ERROR stage=%s code=%d", stage, error);
}

static void write_server_status(const char *text, void *context)
{
    (void)context;
    rt_kprintf("%s", text);
}

typedef struct {
    int sock;
    struct sockaddr_in *peer;
    socklen_t peer_len;
} send_context_t;

static int send_packet(const uint8_t *data, size_t len, void *context)
{
    send_context_t *send_context = context;
    if (send_context->peer->sin_family == 0)
        return -1;

    ssize_t sent = sendto(send_context->sock, data, len, 0,
                          (struct sockaddr *)send_context->peer,
                          send_context->peer_len);
    return sent == (ssize_t)len ? 0 : -1;
}

static rtipc_echo_result_t process_actions(int sock, struct sockaddr_in *peer,
                                           socklen_t peer_len)
{
    send_context_t send_context = {
        .sock = sock,
        .peer = peer,
        .peer_len = peer_len,
    };
    rtipc_echo_result_t result = rtipc_echo_process_actions(
        &s_conn, now_ms(), send_packet, &send_context);

    for (uint32_t i = 0; i < result.connected_events; i++)
        LOG_I("client connected");
    for (uint32_t i = 0; i < result.disconnected_events; i++)
        LOG_W("client disconnected");
    if (result.response_errors != 0 || result.send_errors != 0)
        LOG_E("action errors: response=%u send=%u",
              result.response_errors, result.send_errors);
    return result;
}

static bool valid_session_syn(const uint8_t *packet, size_t packet_len,
                              rtipc_header_t *header)
{
    if (rtipc_header_parse(packet, packet_len, header) != 0 ||
        header->version != RTIPC_PROTOCOL_VERSION ||
        header->msg_type != RTIPC_MSG_SYN || header->payload_len != 0 ||
        packet_len != RTIPC_HEADER_SIZE)
        return false;
    return rtipc_verify_packet(header, NULL, 0);
}

static bool valid_session_fin(const uint8_t *packet, size_t packet_len,
                              rtipc_header_t *header)
{
    if (rtipc_header_parse(packet, packet_len, header) != 0 ||
        header->version != RTIPC_PROTOCOL_VERSION ||
        header->msg_type != RTIPC_MSG_FIN || header->payload_len != 0 ||
        packet_len != RTIPC_HEADER_SIZE)
        return false;
    return rtipc_verify_packet(header, NULL, 0);
}

static uint64_t fin_tombstone_deadline(const rtipc_config_t *config,
                                       uint64_t now)
{
    uint64_t attempts = (uint64_t)config->max_retries + 1U;
    uint64_t interval = config->rto_ms == 0 ? 1 : config->rto_ms;

    if (attempts > (UINT64_MAX - FIN_TOMBSTONE_MARGIN_MS) / interval)
        return UINT64_MAX;
    uint64_t duration = attempts * interval + FIN_TOMBSTONE_MARGIN_MS;
    if (duration > UINT64_MAX - now)
        return UINT64_MAX;
    return now + duration;
}

static rtipc_peer_endpoint_t peer_endpoint(const struct sockaddr_in *peer)
{
    rtipc_peer_endpoint_t endpoint = {
        .address = peer->sin_addr.s_addr,
        .port = peer->sin_port,
    };
    return endpoint;
}

static void rtipc_server_entry(void *param)
{
    (void)param;
    rtipc_tick_extender_init(&s_clock);
    rt_thread_mdelay(2000);

    /* Wait for netdev */
    struct netdev *netdev = NULL;
    for (int i = 0; i < 50; i++) {
        netdev = netdev_get_by_family(AF_INET);
        if (netdev) break;
        rt_thread_mdelay(100);
    }
    if (!netdev) {
        rtipc_server_report_no_network(write_server_status, NULL);
        report_server_error("netdev", -RT_ERROR);
        return;
    }

    /* Set static IP */
    netdev->flags &= ~NETDEV_FLAG_DHCP;
    ip_addr_t ip, nm, gw;
    if (inet_aton(SERVER_IP, &ip) != 1 || inet_aton(SERVER_NM, &nm) != 1 ||
        inet_aton(SERVER_GW, &gw) != 1) {
        report_server_error("address_parse", -RT_EINVAL);
        return;
    }
    if (netdev_set_ipaddr(netdev, &ip) != RT_EOK) {
        report_server_error("set_ipaddr", -RT_ERROR);
        return;
    }
    if (netdev_set_netmask(netdev, &nm) != RT_EOK) {
        report_server_error("set_netmask", -RT_ERROR);
        return;
    }
    if (netdev_set_gw(netdev, &gw) != RT_EOK) {
        report_server_error("set_gateway", -RT_ERROR);
        return;
    }

    LOG_I("server starting on %s:%d", SERVER_IP, RTIPC_PORT);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        report_server_error("socket", sock);
        return;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(RTIPC_PORT);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        report_server_error("bind", -RT_ERROR);
        closesocket(sock);
        return;
    }

    struct timeval tv = { .tv_sec = 0, .tv_usec = RECV_TIMEOUT_MS * 1000 };
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        report_server_error("receive_timeout", -RT_ERROR);
        closesocket(sock);
        return;
    }

    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = false;
    cfg.heartbeat_interval_ms = 500;
    /* QEMU TCG can delay a vCPU and its virtio RX path for several seconds.
     * Keep the server session alive for the same recovery window used by the
     * Linux client instead of closing while a valid request is retrying. */
    cfg.heartbeat_timeout_ms = 10000;
    cfg.max_retries = 8;
    cfg.session_id_seed = (now_ms() << 32) ^ (uint64_t)(uintptr_t)&s_conn;
    rtipc_connection_init(&s_conn, &cfg);
    rt_kprintf("RTIPC_SERVER_READY ip=%s port=%d\n", SERVER_IP, RTIPC_PORT);

    struct sockaddr_in peer = {0};
    socklen_t peer_len = sizeof(peer);
    rtipc_peer_guard_t peer_guard;
    rtipc_peer_guard_init(&peer_guard);

    LOG_I("listening...");

    while (1) {
        struct sockaddr_in source = {0};
        socklen_t source_len = sizeof(source);
        ssize_t n = recvfrom(sock, s_recv_buf, sizeof(s_recv_buf), 0,
                             (struct sockaddr *)&source, &source_len);
        if (n > 0) {
            rtipc_peer_endpoint_t source_endpoint = peer_endpoint(&source);
            bool accepted = rtipc_peer_guard_accepts(&peer_guard,
                                                     &source_endpoint);
            uint64_t received_at = now_ms();
            if (accepted) {
                rtipc_connection_on_recv(&s_conn, s_recv_buf, (size_t)n,
                                         received_at);
            } else if (!peer_guard.claimed) {
                rtipc_header_t control;
                if (valid_session_fin(s_recv_buf, (size_t)n, &control) &&
                    rtipc_peer_guard_accepts_closed_fin(
                        &peer_guard, &source_endpoint, control.session_id,
                        control.seq_num, received_at)) {
                    rtipc_connection_on_recv(&s_conn, s_recv_buf, (size_t)n,
                                             received_at);
                } else if (valid_session_syn(s_recv_buf, (size_t)n,
                                             &control) &&
                           rtipc_peer_guard_claim(
                               &peer_guard, &source_endpoint, received_at)) {
                    rtipc_connection_on_recv(&s_conn, s_recv_buf, (size_t)n,
                                             received_at);
                    if (s_conn.state == RTIPC_STATE_CONNECTED &&
                        s_conn.session_id == control.session_id) {
                        peer = source;
                        peer_len = source_len;
                    } else {
                        rtipc_peer_guard_release(&peer_guard);
                    }
                }
            }
        }

        rtipc_echo_result_t actions = process_actions(sock, &peer, peer_len);

        rtipc_connection_tick(&s_conn, now_ms());
        rtipc_echo_result_t tick_actions = process_actions(sock, &peer,
                                                           peer_len);
        if (s_conn.state == RTIPC_STATE_CLOSED &&
            (actions.disconnected_events != 0 ||
             tick_actions.disconnected_events != 0)) {
            if (s_conn.peer_fin_seq_valid) {
                uint64_t deadline = fin_tombstone_deadline(&cfg, now_ms());
                if (!rtipc_peer_guard_retire(
                        &peer_guard, s_conn.session_id,
                        s_conn.peer_fin_seq, deadline)) {
                    rtipc_peer_guard_release(&peer_guard);
                    memset(&peer, 0, sizeof(peer));
                    peer_len = sizeof(peer);
                }
            } else {
                rtipc_peer_guard_release(&peer_guard);
                memset(&peer, 0, sizeof(peer));
                peer_len = sizeof(peer);
            }
        }

    }

    closesocket(sock);
}

int rtipc_server_start(void)
{
    rt_thread_t tid = rt_thread_create("rtipic_srv", rtipc_server_entry, NULL,
                                       65536, 15, 10);
    if (tid == RT_NULL) {
        report_server_error("thread_create", -RT_ENOMEM);
        return -RT_ENOMEM;
    }
    rt_err_t startup_result = rt_thread_startup(tid);
    if (startup_result != RT_EOK)
        report_server_error("thread_startup", startup_result);
    return startup_result;
}
INIT_APP_EXPORT(rtipc_server_start);
