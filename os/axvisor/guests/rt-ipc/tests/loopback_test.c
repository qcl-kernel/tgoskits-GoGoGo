/* RT-IPC Reliability Loopback Test */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../common/rt_ipc.h"

static int tests_run = 0;
static int tests_passed = 0;
#define TEST(name) do { tests_run++; printf("  TEST: %s ... ", #name); } while(0)
#define PASS() do { tests_passed++; printf("PASS\n"); } while(0)
#define FAIL(msg) do { printf("FAIL: %s\n", msg); } while(0)

typedef struct { uint32_t drop_seq; int dropped_once; } fp_t;

static int should_drop(fp_t *f, const uint8_t *d, size_t l) {
    if (l < 12) return 0;
    if (d[1] != 1 && d[1] != 2) return 0;
    uint32_t s = ((uint32_t)d[4]<<24)|((uint32_t)d[5]<<16)|((uint32_t)d[6]<<8)|d[7];
    if (!f->dropped_once && s == f->drop_seq) { f->dropped_once = 1; return 1; }
    return 0;
}

static void xfer(rtipc_connection_t *snd, rtipc_connection_t *rcv, fp_t *f, uint64_t now) {
    const rtipc_action_t *a;
    while ((a = rtipc_action_next(snd))) {
        if (a->type == RTIPC_ACTION_SEND && !should_drop(f, a->data, a->data_len))
            rtipc_connection_on_recv(rcv, a->data, a->data_len, now);
    }
    rtipc_action_clear(snd);
}

static void xfer2(rtipc_connection_t *a, rtipc_connection_t *b, fp_t *f, uint64_t now) {
    xfer(a, b, f, now);
    xfer(b, a, f, now);
    xfer(a, b, f, now);
}

static void test_retx(void) {
    TEST(retransmission_under_loss);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    cfg.rto_ms = 10; cfg.max_retries = 10;
    static rtipc_connection_t cli, srv;
    rtipc_connection_init(&cli, &cfg);
    rtipc_connection_init(&srv, &cfg);
    fp_t f = {0xFFFF, 0};
    rtipc_connection_connect(&cli, 0);
    xfer2(&cli, &srv, &f, 0);
    if (!rtipc_connection_is_connected(&cli) || !rtipc_connection_is_connected(&srv)) {
        FAIL("handshake"); return;
    }
    f.drop_seq = 2; f.dropped_once = 0;
    uint8_t pl[] = "test";
    for (int i = 0; i < 5; i++) {
        rtipc_connection_send(&cli, RTIPC_MSG_CTRL_CMD, pl, sizeof(pl), i);
        xfer2(&cli, &srv, &f, i);
    }
    f.drop_seq = 0xFFFF;
    for (uint64_t t = 5; t < 200; t += 5) {
        rtipc_connection_tick(&cli, t);
        xfer2(&cli, &srv, &f, t);
        rtipc_connection_tick(&srv, t);
        xfer2(&srv, &cli, &f, t);
    }
    int delivered = (int)(srv.expected_seq - srv.session_seq);
    if (delivered == 5) PASS();
    else { char m[64]; snprintf(m,sizeof(m),"expected 5 got %d",delivered); FAIL(m); }
}

static void test_reorder(void) {
    TEST(reorder_recovery);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    static rtipc_connection_t srv;
    rtipc_connection_init(&srv, &cfg);
    srv.state = RTIPC_STATE_CONNECTED;
    srv.expected_seq = 0;
    uint8_t pl[] = "x";
    int delivered = 0;
    int seqs[] = {1, 0};
    for (int s = 0; s < 2; s++) {
        rtipc_header_t h = {0};
        h.version = RTIPC_PROTOCOL_VERSION;
        h.msg_type = RTIPC_MSG_CTRL_CMD;
        h.seq_num = seqs[s];
        uint8_t pkt[RTIPC_MAX_PACKET];
        size_t n = rtipc_build_packet(&h, pl, sizeof(pl), pkt, sizeof(pkt));
        rtipc_connection_on_recv(&srv, pkt, n, 0);
        const rtipc_action_t *a;
        while ((a = rtipc_action_next(&srv)))
            if (a->type == RTIPC_ACTION_DELIVER) delivered++;
        rtipc_action_clear(&srv);
    }
    if (delivered >= 1) PASS(); else FAIL("no delivery");
}

static void test_hb(void) {
    TEST(heartbeat_maintains_connection);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    cfg.heartbeat_interval_ms = 100;
    cfg.heartbeat_timeout_ms = 500;
    static rtipc_connection_t cli, srv;
    rtipc_connection_init(&cli, &cfg);
    rtipc_connection_init(&srv, &cfg);
    fp_t f = {0xFFFF, 0};
    rtipc_connection_connect(&cli, 0);
    xfer2(&cli, &srv, &f, 0);
    for (uint64_t t = 0; t < 600; t += 50) {
        rtipc_connection_tick(&cli, t);
        xfer2(&cli, &srv, &f, t);
        rtipc_connection_tick(&srv, t);
        xfer2(&srv, &cli, &f, t);
    }
    if (rtipc_connection_is_connected(&cli) && rtipc_connection_is_connected(&srv))
        PASS();
    else FAIL("connection lost");
}

static int exchange_one_data(rtipc_connection_t *sender,
                             rtipc_connection_t *receiver,
                             fp_t *faults, uint64_t now)
{
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(sender))) {
        if (action->type == RTIPC_ACTION_SEND &&
            !should_drop(faults, action->data, action->data_len))
            rtipc_connection_on_recv(receiver, action->data,
                                     action->data_len, now);
    }
    rtipc_action_clear(sender);

    int delivered = 0;
    while ((action = rtipc_action_next(receiver))) {
        if (action->type == RTIPC_ACTION_DELIVER)
            delivered++;
        if (action->type == RTIPC_ACTION_SEND)
            rtipc_connection_on_recv(sender, action->data,
                                     action->data_len, now);
    }
    rtipc_action_clear(receiver);
    rtipc_action_clear(sender);
    return delivered;
}

static void test_reconnect_negotiates_new_sequence_space(void) {
    TEST(reconnect_negotiates_new_sequence_space);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = true;
    cfg.reconnect_initial_delay_ms = 10;
    cfg.reconnect_max_delay_ms = 20;

    static rtipc_connection_t cli, srv;
    rtipc_connection_init(&cli, &cfg);
    rtipc_connection_init(&srv, &cfg);
    fp_t faults = {0xFFFF, 0};

    rtipc_connection_connect(&cli, 0);
    xfer2(&cli, &srv, &faults, 0);
    if (!rtipc_connection_is_connected(&cli) ||
        !rtipc_connection_is_connected(&srv)) {
        FAIL("initial handshake");
        return;
    }

    const uint8_t payload[] = "before-and-after-reconnect";
    if (rtipc_connection_send(&cli, RTIPC_MSG_CTRL_CMD,
                              payload, sizeof(payload), 1) != 0 ||
        exchange_one_data(&cli, &srv, &faults, 1) != 1) {
        FAIL("pre-reconnect delivery");
        return;
    }

    rtipc_connection_force_disconnect(&cli, 10);
    rtipc_action_clear(&cli);
    rtipc_connection_tick(&cli, 30);
    xfer2(&cli, &srv, &faults, 30);
    if (!rtipc_connection_is_connected(&cli) ||
        !rtipc_connection_is_connected(&srv)) {
        FAIL("reconnect handshake");
        return;
    }

    if (rtipc_connection_send(&cli, RTIPC_MSG_CTRL_CMD,
                              payload, sizeof(payload), 31) != 0) {
        FAIL("post-reconnect send");
        return;
    }
    if (exchange_one_data(&cli, &srv, &faults, 31) == 1)
        PASS();
    else
        FAIL("post-reconnect session sequence was not delivered");
}

int main(void) {
    printf("\n=== RT-IPC Reliability Loopback Tests ===\n\n");
    test_retx();
    test_reorder();
    test_hb();
    test_reconnect_negotiates_new_sequence_space();
    printf("\n=== Results: %d/%d passed ===\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
