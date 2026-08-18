#include <stdio.h>
#include <string.h>

#include "../common/rt_ipc.h"
#include "../linux/rtipc_fault.h"

static int failures;

#define CHECK(condition, message)                                             \
    do {                                                                      \
        if (!(condition)) {                                                   \
            fprintf(stderr, "FAIL: %s\n", message);                         \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static size_t build_data_packet(uint8_t type, uint32_t seq,
                                uint8_t fill, uint8_t *packet)
{
    uint8_t payload[64];
    rtipc_header_t header = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = type,
        .seq_num = seq,
        .error_code = RTIPC_ERR_OK,
    };

    memset(payload, fill, sizeof(payload));
    return rtipc_build_packet(&header, payload, sizeof(payload), packet,
                              RTIPC_MAX_PACKET);
}

static void test_profile_parser(void)
{
    rtipc_fault_profile_t profile = RTIPC_FAULT_PROFILE_RELIABILITY;

    CHECK(rtipc_fault_profile_parse("none", &profile) == 0,
          "none profile must parse");
    CHECK(profile == RTIPC_FAULT_PROFILE_NONE,
          "none profile must select no injection");
    CHECK(rtipc_fault_profile_parse("reliability", &profile) == 0,
          "reliability profile must parse");
    CHECK(profile == RTIPC_FAULT_PROFILE_RELIABILITY,
          "reliability profile must select all reliability faults");
    CHECK(rtipc_fault_profile_parse("unknown", &profile) != 0,
          "unknown profile must be rejected");
}

static void test_drop_first_64_byte_command(void)
{
    rtipc_fault_context_t faults;
    uint8_t packet[RTIPC_MAX_PACKET];
    size_t length = build_data_packet(RTIPC_MSG_CTRL_CMD, 0, 0x11, packet);

    rtipc_fault_init(&faults, RTIPC_FAULT_PROFILE_RELIABILITY);
    CHECK(rtipc_fault_on_tx(&faults, 64, packet, length) ==
              RTIPC_FAULT_ACTION_DROP,
          "first 64-byte command must be dropped");
    CHECK(rtipc_fault_on_tx(&faults, 64, packet, length) ==
              RTIPC_FAULT_ACTION_PASS,
          "64-byte command must only be dropped once");
    CHECK(rtipc_fault_on_tx(&faults, 256, packet, length) ==
              RTIPC_FAULT_ACTION_PASS,
          "drop fault must not affect other payload sections");
}

static void test_duplicate_first_256_byte_response(void)
{
    rtipc_fault_context_t faults;
    uint8_t packet[RTIPC_MAX_PACKET];
    size_t length = build_data_packet(RTIPC_MSG_STATUS_REP, 0, 0x22, packet);

    rtipc_fault_init(&faults, RTIPC_FAULT_PROFILE_RELIABILITY);
    CHECK(rtipc_fault_on_rx(&faults, 256, packet, length) ==
              RTIPC_FAULT_ACTION_DUPLICATE,
          "first 256-byte status response must be duplicated");
    CHECK(rtipc_fault_on_rx(&faults, 256, packet, length) ==
              RTIPC_FAULT_ACTION_PASS,
          "256-byte response must only be duplicated once");
}

static void test_reverse_first_two_1024_byte_responses(void)
{
    rtipc_fault_context_t faults;
    uint8_t first[RTIPC_MAX_PACKET];
    uint8_t second[RTIPC_MAX_PACKET];
    uint8_t held[RTIPC_MAX_PACKET];
    size_t first_length = build_data_packet(RTIPC_MSG_STATUS_REP, 0,
                                            0x33, first);
    size_t second_length = build_data_packet(RTIPC_MSG_STATUS_REP, 1,
                                             0x44, second);
    size_t held_length = 0;

    rtipc_fault_init(&faults, RTIPC_FAULT_PROFILE_RELIABILITY);
    CHECK(rtipc_fault_on_rx(&faults, 1024, first, first_length) ==
              RTIPC_FAULT_ACTION_HOLD,
          "first 1024-byte response must be held");
    CHECK(rtipc_fault_on_rx(&faults, 1024, first, first_length) ==
              RTIPC_FAULT_ACTION_HOLD,
          "duplicate held sequence must not satisfy response reordering");
    CHECK(faults.reorder_held && !faults.reorder_done,
          "duplicate held sequence must leave reorder pending");
    CHECK(rtipc_fault_on_rx(&faults, 1024, second, second_length) ==
              RTIPC_FAULT_ACTION_RELEASE_REVERSED,
          "second 1024-byte response must release the reversed pair");
    CHECK(rtipc_fault_take_held(&faults, held, sizeof(held), &held_length) == 0,
          "held response must be retrievable");
    CHECK(held_length == first_length && memcmp(held, first, first_length) == 0,
          "held response bytes must be preserved");
    CHECK(rtipc_fault_on_rx(&faults, 1024, first, first_length) ==
              RTIPC_FAULT_ACTION_PASS,
          "response reordering must only happen once");
}

static void test_none_profile_is_transparent(void)
{
    rtipc_fault_context_t faults;
    uint8_t command[RTIPC_MAX_PACKET];
    uint8_t response[RTIPC_MAX_PACKET];
    size_t command_length = build_data_packet(RTIPC_MSG_CTRL_CMD, 0,
                                              0x55, command);
    size_t response_length = build_data_packet(RTIPC_MSG_STATUS_REP, 0,
                                               0x66, response);

    rtipc_fault_init(&faults, RTIPC_FAULT_PROFILE_NONE);
    CHECK(rtipc_fault_on_tx(&faults, 64, command, command_length) ==
              RTIPC_FAULT_ACTION_PASS,
          "none profile must not drop commands");
    CHECK(rtipc_fault_on_rx(&faults, 256, response, response_length) ==
              RTIPC_FAULT_ACTION_PASS,
          "none profile must not duplicate responses");
    CHECK(rtipc_fault_on_rx(&faults, 1024, response, response_length) ==
              RTIPC_FAULT_ACTION_PASS,
          "none profile must not reorder responses");
}

int main(void)
{
    test_profile_parser();
    test_drop_first_64_byte_command();
    test_duplicate_first_256_byte_response();
    test_reverse_first_two_1024_byte_responses();
    test_none_profile_is_transparent();

    if (failures != 0) {
        fprintf(stderr, "fault profile tests failed: %d\n", failures);
        return 1;
    }
    printf("PASS: RT-IPC deterministic fault profile\n");
    return 0;
}
