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
#include "rt_ipc.h"

#define DBG_TAG "rtipic.srv"
#define DBG_LVL DBG_INFO
#include <rtdbg.h>

#define RTIPC_PORT       9876
#define SERVER_IP        "192.168.77.30"
#define SERVER_NM        "255.255.255.0"
#define SERVER_GW        "192.168.77.1"
#define RECV_TIMEOUT_MS  100

static rtipc_connection_t s_conn;
static uint8_t s_recv_buf[RTIPC_MAX_PACKET];

static uint64_t now_ms(void)
{
    return (uint64_t)rt_tick_get_millisecond();
}

static void process_actions(int sock, struct sockaddr_in *peer, socklen_t *peer_len)
{
    const rtipc_action_t *act;
    while ((act = rtipc_action_next(&s_conn)) != NULL) {
        switch (act->type) {
        case RTIPC_ACTION_SEND:
            if (peer->sin_family != 0)
                sendto(sock, act->data, act->data_len, 0,
                       (struct sockaddr *)peer, *peer_len);
            break;
        case RTIPC_ACTION_CONNECTED:
            LOG_I("client connected");
            break;
        case RTIPC_ACTION_DISCONNECTED:
            LOG_W("client disconnected");
            break;
        case RTIPC_ACTION_DELIVER: {
            /* Received CTRL_CMD: echo back as STATUS_REP */
            rtipc_connection_send(&s_conn, RTIPC_MSG_STATUS_REP,
                                  act->payload, act->payload_len, now_ms());
            const rtipc_action_t *sa;
            while ((sa = rtipc_action_next(&s_conn)) != NULL) {
                if (sa->type == RTIPC_ACTION_SEND && peer->sin_family != 0)
                    sendto(sock, sa->data, sa->data_len, 0,
                           (struct sockaddr *)peer, *peer_len);
            }
            break;
        }
        default:
            break;
        }
    }
    rtipc_action_clear(&s_conn);
}

static void rtipc_server_entry(void *param)
{
    rt_thread_mdelay(2000);

    /* Wait for netdev */
    struct netdev *netdev = NULL;
    for (int i = 0; i < 50; i++) {
        netdev = netdev_get_by_family(AF_INET);
        if (netdev) break;
        rt_thread_mdelay(100);
    }
    if (!netdev) {
        rt_kprintf("RTIPC: NO NETWORK DEVICE\n");
        rt_kprintf("ALL TESTS COMPLETE\n");
        return;
    }

    /* Set static IP */
    netdev->flags &= ~NETDEV_FLAG_DHCP;
    ip_addr_t ip, nm, gw;
    inet_aton(SERVER_IP, &ip);
    inet_aton(SERVER_NM, &nm);
    inet_aton(SERVER_GW, &gw);
    netdev_set_ipaddr(netdev, &ip);
    netdev_set_netmask(netdev, &nm);
    netdev_set_gw(netdev, &gw);

    LOG_I("server starting on %s:%d", SERVER_IP, RTIPC_PORT);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        LOG_E("socket create failed");
        return;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(RTIPC_PORT);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOG_E("bind failed");
        closesocket(sock);
        return;
    }

    struct timeval tv = { .tv_sec = 0, .tv_usec = RECV_TIMEOUT_MS * 1000 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = true;
    cfg.heartbeat_interval_ms = 500;
    cfg.heartbeat_timeout_ms = 2000;
    rtipc_connection_init(&s_conn, &cfg);

    struct sockaddr_in peer = {0};
    socklen_t peer_len = sizeof(peer);
    uint64_t last_report = now_ms();
    uint64_t msg_count = 0;
    uint64_t byte_count = 0;

    LOG_I("listening...");

    while (1) {
        ssize_t n = recvfrom(sock, s_recv_buf, sizeof(s_recv_buf), 0,
                             (struct sockaddr *)&peer, &peer_len);
        if (n > 0) {
            rtipc_connection_on_recv(&s_conn, s_recv_buf, (size_t)n, now_ms());
            msg_count++;
            byte_count += (uint64_t)n;
        }

        process_actions(sock, &peer, &peer_len);

        rtipc_connection_tick(&s_conn, now_ms());
        process_actions(sock, &peer, &peer_len);

        uint64_t now = now_ms();
        if (now - last_report >= 10000) {
            LOG_I("stats: msgs=%llu bytes=%lluKB conn=%d",
                  (unsigned long long)msg_count,
                  (unsigned long long)(byte_count / 1024),
                  rtipc_connection_is_connected(&s_conn));
            last_report = now;
        }
    }

    closesocket(sock);
}

static int rtipc_server_init(void)
{
    rt_thread_t tid = rt_thread_create("rtipic_srv", rtipc_server_entry, NULL,
                                       65536, 15, 10);
    if (tid)
        rt_thread_startup(tid);
    return 0;
}
INIT_APP_EXPORT(rtipc_server_init);
