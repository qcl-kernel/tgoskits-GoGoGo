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

static void test_header_serialize_parse(void) {
    TEST(header_serialize_parse);
    rtipc_header_t hdr = {0};
    hdr.version = 1;
    hdr.msg_type = RTIPC_MSG_CTRL_CMD;
    hdr.payload_len = 256;
    hdr.seq_num = 0x12345678;
    hdr.error_code = RTIPC_ERR_OK;
    hdr.checksum = 0xBEEF;

    uint8_t buf[RTIPC_HEADER_SIZE];
    rtipc_header_serialize(&hdr, buf);

    rtipc_header_t parsed;
    if (rtipc_header_parse(buf, RTIPC_HEADER_SIZE, &parsed) != 0) {
        FAIL("parse failed"); return;
    }

    if (parsed.version == 1 && parsed.msg_type == RTIPC_MSG_CTRL_CMD &&
        parsed.payload_len == 256 && parsed.seq_num == 0x12345678 &&
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

    /* Server receives SYN -> goes directly to CONNECTED + SYNACK */
    rtipc_connection_on_recv(&server, act->data, act->data_len, 0);
    rtipc_action_clear(&client);

    if (server.state != RTIPC_STATE_CONNECTED) { FAIL("server not CONNECTED after SYN"); return; }

    /* Extract SYNACK from server */
    const rtipc_action_t *sa = rtipc_action_next(&server);
    if (!sa || sa->type != RTIPC_ACTION_SEND) { FAIL("no SYNACK send"); return; }

    /* Client receives SYNACK -> CONNECTED */
    rtipc_connection_on_recv(&client, sa->data, sa->data_len, 0);
    rtipc_action_clear(&server);

    if (client.state == RTIPC_STATE_CONNECTED && server.state == RTIPC_STATE_CONNECTED) PASS();
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

int main(void) {
    printf("\n=== RT-IPC Protocol Core Unit Tests ===\n\n");
    test_header_serialize_parse();
    test_crc16_known_vectors();
    test_build_and_verify_packet();
    test_crc_tamper_detected();
    test_syn_handshake();
    test_cumulative_ack();
    test_duplicate_filtering();
    printf("\n=== Results: %d/%d passed ===\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
