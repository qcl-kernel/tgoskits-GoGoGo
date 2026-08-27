/*
 * RT-IPC Protocol Core Unit Tests (host-compiled)
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../common/rt_ipc.h"

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { tests_run++; printf("  TEST: %s ... ", #name); } while(0)
#define PASS() do { tests_passed++; printf("PASS\n"); } while(0)
#define FAIL(msg) do { printf("FAIL: %s\n", msg); } while(0)

static size_t build_unchecked_packet(rtipc_header_t *hdr,
                                     const uint8_t *payload,
                                     size_t payload_len,
                                     uint8_t *packet)
{
    uint8_t header_bytes[RTIPC_HEADER_SIZE];

    hdr->payload_len = (uint16_t)payload_len;
    hdr->checksum = 0;
    rtipc_header_serialize(hdr, header_bytes);
    hdr->checksum = rtipc_crc16(header_bytes, sizeof(header_bytes));
    if (payload_len > 0)
        hdr->checksum = rtipc_crc16_continue(hdr->checksum, payload,
                                             payload_len);
    rtipc_header_serialize(hdr, packet);
    if (payload_len > 0)
        memcpy(packet + RTIPC_HEADER_SIZE, payload, payload_len);
    return RTIPC_HEADER_SIZE + payload_len;
}

static size_t build_control_packet(uint8_t msg_type, uint32_t seq,
                                   uint8_t *packet, size_t packet_size)
{
    rtipc_header_t hdr = {0};

    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = msg_type;
    hdr.seq_num = seq;
    return rtipc_build_packet(&hdr, NULL, 0, packet, packet_size);
}

static void test_header_serialize_parse(void) {
    TEST(header_serialize_parse);
    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.payload_len = 256;
    hdr.seq_num = 0x12345678;
    hdr.session_id = UINT64_C(0x0123456789abcdef);
    hdr.error_code = RTIPC_ERR_OK;
    hdr.checksum = 0xBEEF;

    uint8_t buf[RTIPC_HEADER_SIZE];
    rtipc_header_serialize(&hdr, buf);

    rtipc_header_t parsed;
    if (rtipc_header_parse(buf, RTIPC_HEADER_SIZE, &parsed) != 0) {
        FAIL("parse failed"); return;
    }

    if (parsed.version == RTIPC_PROTOCOL_VERSION &&
        parsed.msg_type == RTIPC_MSG_CTRL_CMD &&
        parsed.payload_len == 256 && parsed.seq_num == 0x12345678 &&
        parsed.session_id == UINT64_C(0x0123456789abcdef) &&
        parsed.error_code == RTIPC_ERR_OK && parsed.checksum == 0xBEEF) {
        PASS();
    } else FAIL("fields mismatch");
}

static void test_crc16_known_vectors(void) {
    TEST(crc16_empty);
    uint16_t crc = rtipc_crc16("", 0);
    if (crc == 0xFFFF) PASS(); else { char msg[64]; snprintf(msg,sizeof(msg),"expected 0xFFFF got 0x%04X",crc); FAIL(msg); }

    TEST(crc16_123456789);
    const uint8_t data[] = "123456789";
    crc = rtipc_crc16(data, 9);
    if (crc == 0x29B1) PASS(); else { char msg[64]; snprintf(msg,sizeof(msg),"expected 0x29B1 got 0x%04X",crc); FAIL(msg); }
}

static void test_build_and_verify_packet(void) {
    TEST(build_and_verify_packet);
    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 42;
    uint8_t payload[] = "hello world";
    uint8_t pkt[RTIPC_MAX_PACKET];
    size_t n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    if (n != RTIPC_HEADER_SIZE + sizeof(payload)) { FAIL("wrong packet size"); return; }
    rtipc_header_t parsed;
    rtipc_header_parse(pkt, n, &parsed);
    if (rtipc_verify_packet(&parsed, pkt + RTIPC_HEADER_SIZE, parsed.payload_len)) PASS();
    else FAIL("CRC verification failed");
}

static void test_crc_tamper_detected(void) {
    TEST(crc_tamper_detected);
    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 1;
    uint8_t payload[] = "test data";
    uint8_t pkt[RTIPC_MAX_PACKET];
    rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    pkt[RTIPC_HEADER_SIZE + 2] ^= 0xFF;
    rtipc_header_t parsed;
    rtipc_header_parse(pkt, RTIPC_HEADER_SIZE + sizeof(payload), &parsed);
    if (!rtipc_verify_packet(&parsed, pkt + RTIPC_HEADER_SIZE, parsed.payload_len)) PASS();
    else FAIL("tampered packet passed CRC");
}

static void test_syn_handshake(void) {
    TEST(syn_handshake);
    rtipc_config_t cfg; rtipc_config_default(&cfg);

    static rtipc_connection_t client, server;
    rtipc_connection_init(&client, &cfg);
    rtipc_connection_init(&server, &cfg);

    /* Client sends SYN */
    rtipc_connection_connect(&client, 0);
    if (client.state != RTIPC_STATE_SYN_SENT) { FAIL("client not SYN_SENT"); return; }

    const rtipc_action_t *act = rtipc_action_next(&client);
    if (!act || act->type != RTIPC_ACTION_SEND) { FAIL("no SYN send"); return; }

    /* Server commits the v1 session once SYNACK is admitted. */
    rtipc_connection_on_recv(&server, act->data, act->data_len, 0);
    rtipc_action_clear(&client);

    if (server.state != RTIPC_STATE_CONNECTED) { FAIL("server not CONNECTED after SYN"); return; }

    /* Extract SYNACK from server */
    const rtipc_action_t *sa = rtipc_action_next(&server);
    if (!sa || sa->type != RTIPC_ACTION_SEND) { FAIL("no SYNACK send"); return; }

    /* Client receives SYNACK and becomes CONNECTED without a third packet. */
    rtipc_connection_on_recv(&client, sa->data, sa->data_len, 0);
    rtipc_action_clear(&server);

    const rtipc_action_t *ca;
    bool sent_ack = false;
    while ((ca = rtipc_action_next(&client)) != NULL) {
        if (ca->type == RTIPC_ACTION_SEND) {
            rtipc_connection_on_recv(&server, ca->data, ca->data_len, 0);
            sent_ack = true;
        }
    }
    rtipc_action_clear(&client);

    if (!sent_ack && client.state == RTIPC_STATE_CONNECTED &&
        server.state == RTIPC_STATE_CONNECTED) PASS();
    else { char msg[64]; snprintf(msg,sizeof(msg),"client=%d server=%d",client.state,server.state); FAIL(msg); }
}

static void test_cumulative_ack(void) {
    TEST(cumulative_ack);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    uint8_t p[] = "x";
    rtipc_connection_send(&conn, RTIPC_MSG_CTRL_CMD, p, 1, 0); rtipc_action_clear(&conn);
    rtipc_connection_send(&conn, RTIPC_MSG_CTRL_CMD, p, 1, 0); rtipc_action_clear(&conn);
    rtipc_connection_send(&conn, RTIPC_MSG_CTRL_CMD, p, 1, 0); rtipc_action_clear(&conn);

    uint32_t before = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) if (conn.pending[i].in_use) before++;
    if (before != 3) { char msg[64]; snprintf(msg,sizeof(msg),"expected 3 inflight got %u",before); FAIL(msg); return; }

    rtipc_header_t ack = {0};
    ack.version = RTIPC_PROTOCOL_VERSION; ack.msg_type = RTIPC_MSG_ACK; ack.seq_num = 2;
    uint8_t pkt[RTIPC_HEADER_SIZE];
    rtipc_build_packet(&ack, NULL, 0, pkt, sizeof(pkt));
    rtipc_connection_on_recv(&conn, pkt, RTIPC_HEADER_SIZE, 0);

    uint32_t after = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) if (conn.pending[i].in_use) after++;
    if (after == 0) PASS(); else { char msg[64]; snprintf(msg,sizeof(msg),"expected 0 inflight got %u",after); FAIL(msg); }
}

static void test_duplicate_filtering(void) {
    TEST(duplicate_filtering);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;
    conn.expected_seq = 5;

    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION; hdr.msg_type = RTIPC_MSG_CTRL_CMD; hdr.seq_num = 5;
    uint8_t payload[] = "dup test";
    uint8_t pkt[RTIPC_MAX_PACKET];
    size_t n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));

    rtipc_connection_on_recv(&conn, pkt, n, 0);
    int d1 = 0; const rtipc_action_t *a;
    while ((a = rtipc_action_next(&conn))) if (a->type == RTIPC_ACTION_DELIVER) d1++;
    rtipc_action_clear(&conn);

    rtipc_connection_on_recv(&conn, pkt, n, 0);
    int d2 = 0;
    while ((a = rtipc_action_next(&conn))) if (a->type == RTIPC_ACTION_DELIVER) d2++;
    rtipc_action_clear(&conn);

    if (d1 == 1 && d2 == 0) PASS();
    else { char msg[64]; snprintf(msg,sizeof(msg),"deliver1=%d deliver2=%d",d1,d2); FAIL(msg); }
}

static void test_receive_actions_survive_until_drained(void) {
    TEST(receive_actions_survive_until_drained);
    rtipc_config_t cfg; rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 0;
    uint8_t payload[] = "drain";
    uint8_t pkt[RTIPC_MAX_PACKET];
    size_t n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&conn, pkt, n, 0);

    int delivers = 0, sends = 0;
    const rtipc_action_t *a;
    while ((a = rtipc_action_next(&conn))) {
        if (a->type == RTIPC_ACTION_DELIVER) delivers++;
        if (a->type == RTIPC_ACTION_SEND) sends++;
    }
    rtipc_action_clear(&conn);

    /* A timer tick must not erase events that the integration layer has not
     * consumed. Use the next sequence number so this is not filtered as a
     * duplicate packet. */
    hdr.seq_num = 1;
    n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&conn, pkt, n, 0);
    rtipc_connection_tick(&conn, 0);
    int tick_delivers = 0, tick_sends = 0;
    while ((a = rtipc_action_next(&conn))) {
        if (a->type == RTIPC_ACTION_DELIVER) tick_delivers++;
        if (a->type == RTIPC_ACTION_SEND) tick_sends++;
    }
    rtipc_action_clear(&conn);

    if (delivers == 1 && sends == 1 && tick_delivers == 1) PASS();
    else { char msg[96]; snprintf(msg,sizeof(msg),"drain d=%d s=%d tick d=%d s=%d",delivers,sends,tick_delivers,tick_sends); FAIL(msg); }
}

static void test_queued_deliver_payloads_are_independent(void) {
    TEST(queued_deliver_payloads_are_independent);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    uint8_t first[] = "first-payload";
    uint8_t second[] = "second-payload";
    uint8_t pkt[RTIPC_MAX_PACKET];

    hdr.seq_num = 0;
    size_t n = rtipc_build_packet(&hdr, first, sizeof(first), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&conn, pkt, n, 0);
    hdr.seq_num = 1;
    n = rtipc_build_packet(&hdr, second, sizeof(second), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&conn, pkt, n, 0);

    const rtipc_action_t *deliveries[2] = {NULL, NULL};
    unsigned deliver_count = 0;
    const rtipc_action_t *a;
    while ((a = rtipc_action_next(&conn))) {
        if (a->type == RTIPC_ACTION_DELIVER && deliver_count < 2)
            deliveries[deliver_count++] = a;
    }

    if (deliver_count == 2 &&
        deliveries[0]->payload_len == sizeof(first) &&
        memcmp(deliveries[0]->payload, first, sizeof(first)) == 0 &&
        deliveries[1]->payload_len == sizeof(second) &&
        memcmp(deliveries[1]->payload, second, sizeof(second)) == 0) {
        PASS();
    } else {
        FAIL("queued DELIVER payloads were not independently preserved");
    }
}

static void test_transport_reliability_statistics(void) {
    TEST(transport_reliability_statistics);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.rto_ms = 10;
    cfg.max_retries = 2;
    static rtipc_connection_t sender, receiver;
    rtipc_connection_init(&sender, &cfg);
    rtipc_connection_init(&receiver, &cfg);
    sender.state = RTIPC_STATE_CONNECTED;
    receiver.state = RTIPC_STATE_CONNECTED;

    const uint8_t payload[4] = {1, 2, 3, 4};
    for (uint32_t seq = 0; seq < 3; seq++) {
        if (rtipc_connection_send(&sender, RTIPC_MSG_CTRL_CMD, payload, sizeof(payload), 0) != 0) {
            FAIL("send failed");
            return;
        }
    }
    rtipc_action_clear(&sender);

    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    uint8_t pkt[RTIPC_MAX_PACKET];
    hdr.seq_num = 0;
    size_t n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&receiver, pkt, n, 0);
    hdr.seq_num = 2;
    n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&receiver, pkt, n, 0);
    rtipc_action_clear(&receiver);

    hdr.seq_num = 1;
    n = rtipc_build_packet(&hdr, payload, sizeof(payload), pkt, sizeof(pkt));
    rtipc_connection_on_recv(&receiver, pkt, n, 0);
    rtipc_action_clear(&receiver);
    rtipc_connection_on_recv(&receiver, pkt, n, 0);
    rtipc_action_clear(&receiver);

    pkt[RTIPC_HEADER_SIZE] ^= 0xff;
    rtipc_connection_on_recv(&receiver, pkt, n, 0);
    rtipc_action_clear(&receiver);

    rtipc_stats_t tx = rtipc_connection_stats(&sender);
    rtipc_stats_t rx = rtipc_connection_stats(&receiver);
    if (tx.tx_packets != 3 || tx.tx_bytes != 12 ||
        rx.rx_packets != 4 || rx.rx_bytes != 16 ||
        rx.rx_duplicates != 1 || rx.rx_out_of_order != 1 || rx.rx_errors != 1) {
        FAIL("transport counters did not match accepted, duplicate, reordered, and erroneous input");
        return;
    }

    hdr.msg_type = RTIPC_MSG_ACK;
    hdr.seq_num = 2;
    hdr.payload_len = 0;
    n = rtipc_build_packet(&hdr, NULL, 0, pkt, sizeof(pkt));
    rtipc_connection_on_recv(&sender, pkt, n, 0);
    rtipc_action_clear(&sender);

    rtipc_connection_send(&sender, RTIPC_MSG_CTRL_CMD, payload, sizeof(payload), 0);
    rtipc_action_clear(&sender);
    rtipc_connection_tick(&sender, cfg.rto_ms);
    rtipc_action_clear(&sender);
    rtipc_connection_tick(&sender, cfg.rto_ms * 5);
    rtipc_action_clear(&sender);
    rtipc_connection_tick(&sender, cfg.rto_ms * 6);
    rtipc_action_clear(&sender);

    tx = rtipc_connection_stats(&sender);
    if (tx.acks_received != 1 || tx.retransmissions != 2 ||
        tx.timeouts != 1 || sender.state != RTIPC_STATE_CLOSED ||
        sender.pending_count != 0) {
        FAIL("ACK, retransmission, and timeout counters did not match reliability events");
        return;
    }
    PASS();
}

static void test_default_rto_has_qemu_network_margin(void) {
    TEST(default_rto_has_qemu_network_margin);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    const uint8_t payload[] = {1};
    if (rtipc_connection_send(&conn, RTIPC_MSG_CTRL_CMD,
                              payload, sizeof(payload), 0) != 0) {
        FAIL("send failed");
        return;
    }
    rtipc_action_clear(&conn);
    rtipc_connection_tick(&conn, 499);

    rtipc_stats_t stats = rtipc_connection_stats(&conn);
    if (cfg.rto_ms >= 500 && stats.retransmissions == 0) PASS();
    else {
        char msg[96];
        snprintf(msg, sizeof(msg), "rto=%llu retrans=%u",
                 (unsigned long long)cfg.rto_ms, stats.retransmissions);
        FAIL(msg);
    }
}

static void test_full_reorder_window_preserves_delivery_data(void) {
    TEST(full_reorder_window_preserves_delivery_data);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    uint8_t packet[RTIPC_MAX_PACKET];
    for (uint32_t seq = 1; seq < RTIPC_SEND_WINDOW; seq++) {
        uint8_t payload[4] = {
            (uint8_t)(seq >> 24), (uint8_t)(seq >> 16),
            (uint8_t)(seq >> 8), (uint8_t)seq
        };
        rtipc_header_t hdr = {0};
        hdr.version = RTIPC_PROTOCOL_VERSION;
        hdr.msg_type = (seq & 1) ? RTIPC_MSG_CTRL_CMD
                                 : RTIPC_MSG_STATUS_REP;
        hdr.seq_num = seq;
        size_t n = rtipc_build_packet(&hdr, payload, sizeof(payload),
                                      packet, sizeof(packet));
        rtipc_connection_on_recv(&conn, packet, n, 0);
        rtipc_action_clear(&conn);
    }

    uint8_t zero_payload[4] = {0, 0, 0, 0};
    rtipc_header_t zero = {0};
    zero.version = RTIPC_PROTOCOL_VERSION;
    zero.msg_type = RTIPC_MSG_STATUS_REP;
    zero.seq_num = 0;
    size_t n = rtipc_build_packet(&zero, zero_payload, sizeof(zero_payload),
                                  packet, sizeof(packet));
    rtipc_connection_on_recv(&conn, packet, n, 0);

    /* All 64 backing slots are still owned by queued DELIVER actions. A new
     * datagram must not overwrite them or advance the cumulative ACK point. */
    uint8_t next_payload[4] = {0, 0, 0, RTIPC_SEND_WINDOW};
    rtipc_header_t next = zero;
    next.msg_type = RTIPC_MSG_CTRL_CMD;
    next.seq_num = RTIPC_SEND_WINDOW;
    n = rtipc_build_packet(&next, next_payload, sizeof(next_payload),
                           packet, sizeof(packet));
    rtipc_connection_on_recv(&conn, packet, n, 0);

    unsigned deliveries = 0;
    unsigned sends = 0;
    bool payloads_ok = true;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&conn)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND) {
            sends++;
            continue;
        }
        if (action->type != RTIPC_ACTION_DELIVER)
            continue;

        uint32_t seq = deliveries;
        uint8_t expected_payload[4] = {
            (uint8_t)(seq >> 24), (uint8_t)(seq >> 16),
            (uint8_t)(seq >> 8), (uint8_t)seq
        };
        uint8_t expected_type = (seq == 0 || (seq & 1) == 0)
                              ? RTIPC_MSG_STATUS_REP
                              : RTIPC_MSG_CTRL_CMD;
        if (action->payload_len != sizeof(expected_payload) ||
            memcmp(action->payload, expected_payload,
                   sizeof(expected_payload)) != 0 ||
            action->msg_type != expected_type)
            payloads_ok = false;
        deliveries++;
    }

    if (deliveries != RTIPC_SEND_WINDOW || sends != 1 ||
        conn.expected_seq != RTIPC_SEND_WINDOW || !payloads_ok) {
        char msg[128];
        snprintf(msg, sizeof(msg),
                 "deliver=%u send=%u expected=%u payloads_ok=%d",
                 deliveries, sends, conn.expected_seq, payloads_ok);
        FAIL(msg);
        rtipc_action_clear(&conn);
        return;
    }

    rtipc_action_clear(&conn);
    rtipc_connection_on_recv(&conn, packet, n, 0);
    unsigned next_deliveries = 0;
    while ((action = rtipc_action_next(&conn)) != NULL)
        if (action->type == RTIPC_ACTION_DELIVER)
            next_deliveries++;

    if (next_deliveries == 1 &&
        conn.expected_seq == RTIPC_SEND_WINDOW + 1)
        PASS();
    else
        FAIL("delivery backing slots were not released by action_clear");
    rtipc_action_clear(&conn);
}

static void test_rejects_malformed_datagrams_without_state_change(void) {
    TEST(rejects_malformed_datagrams_without_state_change);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;
    conn.expected_seq = 9;
    conn.last_hb_recv_ms = 77;

    uint8_t packet[RTIPC_MAX_PACKET + 1];
    uint8_t payload[RTIPC_MAX_PAYLOAD + 1];
    memset(payload, 0x5a, sizeof(payload));

    rtipc_connection_on_recv(&conn, packet, RTIPC_HEADER_SIZE - 1, 100);

    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION + 1;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 9;
    size_t n = build_unchecked_packet(&hdr, payload, 1, packet);
    rtipc_connection_on_recv(&conn, packet, n, 100);

    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = 0xff;
    n = build_unchecked_packet(&hdr, payload, 1, packet);
    rtipc_connection_on_recv(&conn, packet, n, 100);

    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    n = build_unchecked_packet(&hdr, payload, RTIPC_MAX_PAYLOAD + 1,
                               packet);
    rtipc_connection_on_recv(&conn, packet, n, 100);

    n = build_unchecked_packet(&hdr, payload, 3, packet);
    rtipc_connection_on_recv(&conn, packet, n - 1, 100);
    packet[n] = 0;
    rtipc_connection_on_recv(&conn, packet, n + 1, 100);

    if (conn.stats.rx_errors == 6 &&
        conn.state == RTIPC_STATE_CONNECTED && conn.expected_seq == 9 &&
        conn.last_hb_recv_ms == 77 && conn.action_count == 0)
        PASS();
    else {
        char msg[128];
        snprintf(msg, sizeof(msg),
                 "errors=%u state=%d expected=%u hb=%llu actions=%u",
                 conn.stats.rx_errors, conn.state, conn.expected_seq,
                 (unsigned long long)conn.last_hb_recv_ms,
                 conn.action_count);
        FAIL(msg);
    }
}

static void test_build_rejects_oversized_payload(void) {
    TEST(build_rejects_oversized_payload);
    rtipc_header_t hdr = {0};
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    uint8_t payload[RTIPC_MAX_PAYLOAD + 1];
    uint8_t packet[RTIPC_MAX_PACKET + 1];

    if (rtipc_build_packet(&hdr, payload, sizeof(payload), packet,
                           sizeof(packet)) == 0)
        PASS();
    else
        FAIL("oversized payload was serialized");
}

static void test_future_and_stale_acks_do_not_release_pending(void) {
    TEST(future_and_stale_acks_do_not_release_pending);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    const uint8_t payload[] = {1};
    for (int i = 0; i < 3; i++) {
        if (rtipc_connection_send(&conn, RTIPC_MSG_CTRL_CMD, payload,
                                  sizeof(payload), 0) != 0) {
            FAIL("send setup failed");
            return;
        }
        rtipc_action_clear(&conn);
    }

    uint8_t packet[RTIPC_HEADER_SIZE];
    size_t n = build_control_packet(RTIPC_MSG_ACK, 99, packet,
                                    sizeof(packet));
    rtipc_connection_on_recv(&conn, packet, n, 0);
    if (conn.pending_count != 3 || conn.last_acked != 0xffffffffU) {
        FAIL("future ACK released pending packets");
        return;
    }

    n = build_control_packet(RTIPC_MSG_ACK, 1, packet, sizeof(packet));
    rtipc_connection_on_recv(&conn, packet, n, 0);
    if (conn.pending_count != 1 || conn.last_acked != 1) {
        FAIL("valid cumulative ACK was not applied");
        return;
    }

    const uint32_t stale_acks[] = {0, 1, 99};
    for (size_t i = 0; i < sizeof(stale_acks) / sizeof(stale_acks[0]); i++) {
        n = build_control_packet(RTIPC_MSG_ACK, stale_acks[i], packet,
                                 sizeof(packet));
        rtipc_connection_on_recv(&conn, packet, n, 0);
    }

    if (conn.pending_count == 1 && conn.last_acked == 1 &&
        conn.pending[2].in_use)
        PASS();
    else
        FAIL("stale or future ACK corrupted sender state");
}

typedef struct {
    const uint8_t *payload;
    size_t payload_len;
} held_delivery_t;

static bool queue_held_delivery(rtipc_connection_t *conn,
                                const uint8_t *payload, size_t payload_len,
                                held_delivery_t *held)
{
    rtipc_header_t hdr = {0};
    uint8_t packet[RTIPC_MAX_PACKET];

    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 0;
    size_t n = rtipc_build_packet(&hdr, payload, payload_len,
                                  packet, sizeof(packet));
    rtipc_connection_on_recv(conn, packet, n, 0);

    const rtipc_action_t *action;
    while ((action = rtipc_action_next(conn)) != NULL) {
        if (action->type == RTIPC_ACTION_DELIVER) {
            held->payload = action->payload;
            held->payload_len = action->payload_len;
            return true;
        }
    }
    return false;
}

static unsigned queued_delivery_slots(const rtipc_connection_t *conn)
{
    unsigned count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++)
        if (conn->reorder_buf[i].delivery_queued)
            count++;
    return count;
}

static bool held_delivery_is_intact(const rtipc_connection_t *conn,
                                    const held_delivery_t *held,
                                    const uint8_t *expected,
                                    size_t expected_len)
{
    return queued_delivery_slots(conn) > 0 &&
           held->payload_len == expected_len &&
           memcmp(held->payload, expected, expected_len) == 0;
}

static bool add_pending_packet(rtipc_connection_t *conn)
{
    static const uint8_t pending_payload[] = "pending";
    return rtipc_connection_send(conn, RTIPC_MSG_STATUS_REP,
                                 pending_payload,
                                 sizeof(pending_payload), 0) == 0;
}

static void test_connect_preserves_uncleared_delivery(void) {
    TEST(connect_preserves_uncleared_delivery);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    static const uint8_t original[] = "connect-held-delivery";
    held_delivery_t held = {0};
    if (!queue_held_delivery(&conn, original, sizeof(original), &held)) {
        FAIL("delivery setup failed");
        return;
    }

    rtipc_connection_connect(&conn, 1);

    rtipc_header_t hdr = {0};
    uint8_t replacement[] = "replacement-payload";
    uint8_t packet[RTIPC_MAX_PACKET];
    hdr.version = RTIPC_PROTOCOL_VERSION;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.seq_num = 1;
    size_t n = rtipc_build_packet(&hdr, replacement, sizeof(replacement),
                                  packet, sizeof(packet));
    rtipc_connection_on_recv(&conn, packet, n, 2);

    if (conn.state == RTIPC_STATE_CONNECTED && conn.expected_seq == 2 &&
        held_delivery_is_intact(&conn, &held, original, sizeof(original))) {
        rtipc_action_clear(&conn);
        if (queued_delivery_slots(&conn) == 0)
            PASS();
        else
            FAIL("explicit action_clear did not release delivery");
    } else {
        FAIL("connect released or overwrote uncleared delivery");
        rtipc_action_clear(&conn);
    }
}

static void test_force_disconnect_preserves_uncleared_delivery(void) {
    TEST(force_disconnect_preserves_uncleared_delivery);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    static const uint8_t original[] = "force-held-delivery";
    held_delivery_t held = {0};
    if (!add_pending_packet(&conn) ||
        !queue_held_delivery(&conn, original, sizeof(original), &held)) {
        FAIL("delivery setup failed");
        return;
    }

    rtipc_connection_force_disconnect(&conn, 10);
    bool valid = conn.state == RTIPC_STATE_CLOSED &&
                 conn.pending_count == 0 && conn.expected_seq == 0 &&
                 held_delivery_is_intact(&conn, &held, original,
                                         sizeof(original));

    rtipc_connection_force_disconnect(&conn, 11);
    rtipc_connection_disconnect(&conn, 12);
    valid = valid && held_delivery_is_intact(&conn, &held, original,
                                             sizeof(original));

    rtipc_connection_connect(&conn, 13);
    valid = valid && conn.state == RTIPC_STATE_SYN_SENT &&
            conn.pending_count == 0 && conn.session_seq_valid &&
            conn.expected_seq == conn.session_seq &&
            held_delivery_is_intact(&conn, &held, original,
                                    sizeof(original));
    rtipc_connection_connect(&conn, 14);
    valid = valid && held_delivery_is_intact(&conn, &held, original,
                                             sizeof(original));

    rtipc_action_clear(&conn);
    if (valid && queued_delivery_slots(&conn) == 0)
        PASS();
    else
        FAIL("force/connect lifecycle released delivery or kept data state");
}

static void test_auto_reconnect_preserves_uncleared_delivery(void) {
    TEST(auto_reconnect_preserves_uncleared_delivery);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    cfg.auto_reconnect = true;
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    static const uint8_t original[] = "reconnect-held-delivery";
    held_delivery_t held = {0};
    if (!add_pending_packet(&conn) ||
        !queue_held_delivery(&conn, original, sizeof(original), &held)) {
        FAIL("delivery setup failed");
        return;
    }

    rtipc_connection_force_disconnect(&conn, 10);
    bool valid = conn.state == RTIPC_STATE_RECONNECTING &&
                 conn.pending_count == 0 && conn.expected_seq == 0 &&
                 held_delivery_is_intact(&conn, &held, original,
                                         sizeof(original));
    rtipc_connection_force_disconnect(&conn, 11);
    valid = valid && held_delivery_is_intact(&conn, &held, original,
                                             sizeof(original));
    rtipc_connection_connect(&conn, 12);
    valid = valid && conn.state == RTIPC_STATE_SYN_SENT &&
            held_delivery_is_intact(&conn, &held, original,
                                    sizeof(original));

    rtipc_action_clear(&conn);
    if (valid && queued_delivery_slots(&conn) == 0)
        PASS();
    else
        FAIL("auto reconnect lifecycle released uncleared delivery");
}

static void test_disconnect_preserves_uncleared_delivery(void) {
    TEST(disconnect_preserves_uncleared_delivery);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    static const uint8_t original[] = "disconnect-held-delivery";
    held_delivery_t held = {0};
    if (!add_pending_packet(&conn) ||
        !queue_held_delivery(&conn, original, sizeof(original), &held)) {
        FAIL("delivery setup failed");
        return;
    }

    rtipc_connection_disconnect(&conn, 10);
    bool valid = conn.state == RTIPC_STATE_SHUTDOWN &&
                 conn.pending_count == 0 && conn.expected_seq == 0 &&
                 held_delivery_is_intact(&conn, &held, original,
                                         sizeof(original));
    rtipc_connection_disconnect(&conn, 11);
    valid = valid && held_delivery_is_intact(&conn, &held, original,
                                             sizeof(original));

    rtipc_action_clear(&conn);
    if (valid && queued_delivery_slots(&conn) == 0)
        PASS();
    else
        FAIL("disconnect released delivery or kept data state");
}

static void test_reset_preserves_uncleared_delivery(void) {
    TEST(reset_preserves_uncleared_delivery);
    rtipc_config_t cfg;
    rtipc_config_default(&cfg);
    static rtipc_connection_t conn;
    rtipc_connection_init(&conn, &cfg);
    conn.state = RTIPC_STATE_CONNECTED;

    static const uint8_t original[] = "reset-held-delivery";
    held_delivery_t held = {0};
    if (!add_pending_packet(&conn) ||
        !queue_held_delivery(&conn, original, sizeof(original), &held)) {
        FAIL("delivery setup failed");
        return;
    }

    rtipc_connection_reset(&conn);
    bool valid = conn.state == RTIPC_STATE_CLOSED &&
                 conn.pending_count == 0 && conn.expected_seq == 0 &&
                 held_delivery_is_intact(&conn, &held, original,
                                         sizeof(original));
    rtipc_connection_connect(&conn, 1);
    valid = valid && conn.state == RTIPC_STATE_SYN_SENT &&
            held_delivery_is_intact(&conn, &held, original,
                                    sizeof(original));

    rtipc_action_clear(&conn);
    if (valid && queued_delivery_slots(&conn) == 0)
        PASS();
    else
        FAIL("reset released uncleared delivery or kept data state");
}

int main(void) {
    printf("\n=== RT-IPC Protocol Core Unit Tests ===\n\n");
    test_header_serialize_parse();
    test_crc16_known_vectors();
    test_build_and_verify_packet();
    test_crc_tamper_detected();
    test_syn_handshake();
    test_cumulative_ack();
    test_duplicate_filtering();
    test_receive_actions_survive_until_drained();
    test_queued_deliver_payloads_are_independent();
    test_transport_reliability_statistics();
    test_default_rto_has_qemu_network_margin();
    test_full_reorder_window_preserves_delivery_data();
    test_rejects_malformed_datagrams_without_state_change();
    test_build_rejects_oversized_payload();
    test_future_and_stale_acks_do_not_release_pending();
    test_connect_preserves_uncleared_delivery();
    test_force_disconnect_preserves_uncleared_delivery();
    test_auto_reconnect_preserves_uncleared_delivery();
    test_disconnect_preserves_uncleared_delivery();
    test_reset_preserves_uncleared_delivery();
    printf("\n=== Results: %d/%d passed ===\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
