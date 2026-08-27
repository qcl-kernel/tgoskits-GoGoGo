#include "task3_protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, \
                    #condition);                                                \
            failures++;                                                         \
        }                                                                       \
    } while (0)

static void test_control_golden_vector(void)
{
    const task3_control_t value = {
        .command = TASK3_CMD_STEP,
        .mode = TASK3_MODE_AI,
        .klass = TASK3_CLASS_LEFT,
        .confidence_q15 = 0x1234,
        .frame_id = 0x01020304,
        .tx_monotonic_ns = UINT64_C(0x0102030405060708),
    };
    const uint8_t expected[TASK3_CTRL_WIRE_SIZE] = {
        1, TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_LEFT,
        0x12, 0x34, 0, 0, 0x01, 0x02, 0x03, 0x04,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0, 0, 0, 0,
    };
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];
    task3_control_t decoded;

    CHECK(task3_encode_control(&value, wire) == TASK3_CODEC_OK);
    CHECK(memcmp(wire, expected, sizeof(expected)) == 0);
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) == TASK3_CODEC_OK);
    CHECK(decoded.command == value.command);
    CHECK(decoded.mode == value.mode);
    CHECK(decoded.klass == value.klass);
    CHECK(decoded.confidence_q15 == value.confidence_q15);
    CHECK(decoded.frame_id == value.frame_id);
    CHECK(decoded.tx_monotonic_ns == value.tx_monotonic_ns);
}

static void test_control_rejects_invalid_wire(void)
{
    task3_control_t value = {
        .command = TASK3_CMD_STEP,
        .mode = TASK3_MODE_AI,
        .klass = TASK3_CLASS_CENTER,
    };
    task3_control_t decoded = {.frame_id = UINT32_C(0xfeedface)};
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];

    CHECK(task3_encode_control(&value, wire) == TASK3_CODEC_OK);
    CHECK(task3_decode_control(wire, sizeof(wire) - 1, &decoded) ==
          TASK3_CODEC_INVALID_LENGTH);
    CHECK(decoded.frame_id == UINT32_C(0xfeedface));

    wire[0] = 2;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_VERSION);
    wire[0] = TASK3_SCHEMA_VERSION;

    wire[1] = 0xff;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
    wire[1] = TASK3_CMD_STEP;
    wire[2] = 0xff;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
    wire[2] = TASK3_MODE_AI;
    wire[3] = 0xff;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
    wire[3] = TASK3_CLASS_CENTER;
    wire[6] = 1;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_NONZERO_RESERVED);
    wire[6] = 0;
    wire[20] = 1;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_NONZERO_RESERVED);
    wire[20] = 0;
    wire[4] = 0x80;
    wire[5] = 0x00;
    CHECK(task3_decode_control(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
}

static void test_encode_rejects_invalid_fields(void)
{
    task3_control_t control = {
        .command = TASK3_CMD_STEP,
        .mode = TASK3_MODE_AI,
        .klass = TASK3_CLASS_CENTER,
    };
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];

    control.command = (task3_command_t)0xff;
    CHECK(task3_encode_control(&control, wire) == TASK3_CODEC_INVALID_FIELD);
    control.command = TASK3_CMD_STEP;
    control.mode = (task3_mode_t)0xff;
    CHECK(task3_encode_control(&control, wire) == TASK3_CODEC_INVALID_FIELD);
    control.mode = TASK3_MODE_AI;
    control.klass = (task3_class_t)0xff;
    CHECK(task3_encode_control(&control, wire) == TASK3_CODEC_INVALID_FIELD);
    control.klass = TASK3_CLASS_CENTER;
    control.confidence_q15 = UINT16_C(32768);
    CHECK(task3_encode_control(&control, wire) == TASK3_CODEC_INVALID_FIELD);
    CHECK(task3_encode_control(NULL, wire) == TASK3_CODEC_NULL_ARGUMENT);
    CHECK(task3_encode_control(&control, NULL) == TASK3_CODEC_NULL_ARGUMENT);
}

static void test_status_signed_round_trip(void)
{
    const task3_status_t value = {
        .status = TASK3_STATUS_OK,
        .applied_class = TASK3_CLASS_RIGHT,
        .flags = TASK3_STATUS_FLAG_DUPLICATE,
        .frame_id = UINT32_C(0xa1b2c3d4),
        .pwm = -1000,
        .actuator_q15 = -32768,
        .processing_us = UINT32_C(0x10203040),
        .echoed_tx_monotonic_ns = UINT64_C(0x1122334455667788),
    };
    task3_status_t decoded;
    uint8_t wire[TASK3_STATUS_WIRE_SIZE];

    CHECK(task3_encode_status(&value, wire) == TASK3_CODEC_OK);
    CHECK(wire[8] == 0xfc && wire[9] == 0x18);
    CHECK(wire[10] == 0x80 && wire[11] == 0x00);
    CHECK(task3_decode_status(wire, sizeof(wire), &decoded) == TASK3_CODEC_OK);
    CHECK(decoded.pwm == value.pwm);
    CHECK(decoded.actuator_q15 == value.actuator_q15);
    CHECK(decoded.frame_id == value.frame_id);
    CHECK(decoded.processing_us == value.processing_us);
    CHECK(decoded.echoed_tx_monotonic_ns == value.echoed_tx_monotonic_ns);

    wire[0] = 2;
    CHECK(task3_decode_status(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_VERSION);
    wire[0] = TASK3_SCHEMA_VERSION;
    wire[1] = 0xff;
    CHECK(task3_decode_status(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
    wire[1] = TASK3_STATUS_OK;
    wire[3] = 0x80;
    CHECK(task3_decode_status(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
}

static void test_error_round_trip(void)
{
    const task3_error_t value = {
        .category = TASK3_ERROR_CATEGORY_APPLICATION,
        .code = TASK3_APP_INVALID_CLASS,
        .frame_id = UINT32_C(0x89abcdef),
        .detail = UINT32_C(0x76543210),
    };
    task3_error_t decoded;
    uint8_t wire[TASK3_ERROR_WIRE_SIZE];

    CHECK(task3_encode_error(&value, wire) == TASK3_CODEC_OK);
    CHECK(task3_decode_error(wire, sizeof(wire), &decoded) == TASK3_CODEC_OK);
    CHECK(decoded.category == value.category);
    CHECK(decoded.code == value.code);
    CHECK(decoded.frame_id == value.frame_id);
    CHECK(decoded.detail == value.detail);

    wire[1] = 0xff;
    CHECK(task3_decode_error(wire, sizeof(wire), &decoded) ==
          TASK3_CODEC_INVALID_FIELD);
    CHECK(task3_decode_error(wire, sizeof(wire) - 1, &decoded) ==
          TASK3_CODEC_INVALID_LENGTH);
}

int main(void)
{
    test_control_golden_vector();
    test_control_rejects_invalid_wire();
    test_encode_rejects_invalid_fields();
    test_status_signed_round_trip();
    test_error_round_trip();

    if (failures != 0) {
        fprintf(stderr, "test_task3_protocol: %d failure(s)\n", failures);
        return 1;
    }
    puts("test_task3_protocol: PASS");
    return 0;
}
