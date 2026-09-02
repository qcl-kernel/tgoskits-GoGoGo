#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define TASK3_HOST_TEST 1
#include "../src/rtthread/task3_server.c"

#define ASSERT_TRUE(value)                                                        \
    do {                                                                          \
        if (!(value)) {                                                           \
            fprintf(stderr, "%s:%d assertion failed: %s\n", __FILE__, __LINE__,  \
                    #value);                                                      \
            return 1;                                                             \
        }                                                                         \
    } while (0)

typedef struct {
    uint8_t message_type;
    uint8_t payload[RTIPC_MAX_PAYLOAD];
    size_t length;
    uint32_t responses;
} capture_t;

static int print_calls;

void task3_server_print_status(const task3_status_t *status,
                               const task3_control_t *control)
{
    (void)status;
    (void)control;
    print_calls++;
}

static int capture_response(void *context, uint8_t message_type,
                            const uint8_t *payload, size_t length,
                            uint64_t now_ms)
{
    capture_t *capture = context;

    (void)now_ms;
    if (length > sizeof(capture->payload)) {
        return -1;
    }
    capture->message_type = message_type;
    capture->length = length;
    memcpy(capture->payload, payload, length);
    capture->responses++;
    return 0;
}

static int send_control(task3_server_app_t *app, capture_t *capture,
                        task3_command_t command, task3_mode_t mode,
                        task3_class_t klass, uint32_t frame_id,
                        uint64_t tx_monotonic_ns)
{
    task3_control_t control = {
        .command = command,
        .mode = mode,
        .klass = klass,
        .confidence_q15 = 30000,
        .frame_id = frame_id,
        .tx_monotonic_ns = tx_monotonic_ns,
    };
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];

    if (task3_encode_control(&control, wire) != TASK3_CODEC_OK) {
        return -1;
    }
    capture->responses = 0;
    return task3_server_handle_message(app, RTIPC_MSG_CTRL_CMD, wire,
                                       sizeof(wire), UINT64_C(10));
}

int main(void)
{
    task3_server_app_t app;
    capture_t capture = {0};
    task3_status_t first;
    task3_status_t duplicate;
    task3_error_t error;
    uint8_t malformed[TASK3_CTRL_WIRE_SIZE] = {0};
    uint64_t applied;

    task3_server_app_init(&app, capture_response, &capture);
    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_RESET, TASK3_MODE_FIXED,
                             TASK3_CLASS_CENTER, 0, UINT64_C(100)) == 0);
    ASSERT_TRUE(capture.responses == 1 &&
                capture.message_type == RTIPC_MSG_STATUS_REP);
    ASSERT_TRUE(task3_decode_status(capture.payload, capture.length, &first) ==
                TASK3_CODEC_OK);
    ASSERT_TRUE(first.actuator_q15 == 0);
    ASSERT_TRUE(app.requests == 0);
    ASSERT_TRUE(app.applied_steps == 0);

    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_STEP, TASK3_MODE_AI,
                             TASK3_CLASS_RIGHT, 7, UINT64_C(200)) == 0);
    ASSERT_TRUE(task3_decode_status(capture.payload, capture.length, &first) ==
                TASK3_CODEC_OK);
    applied = app.controller.applied_steps;
    ASSERT_TRUE(applied == 1 && first.frame_id == 7);
    ASSERT_TRUE(app.requests == 1);
    ASSERT_TRUE(app.applied_steps == 1);

    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_STEP, TASK3_MODE_AI,
                             TASK3_CLASS_RIGHT, 7, UINT64_C(300)) == 0);
    ASSERT_TRUE(task3_decode_status(capture.payload, capture.length, &duplicate) ==
                TASK3_CODEC_OK);
    ASSERT_TRUE(app.controller.applied_steps == applied);
    ASSERT_TRUE((duplicate.flags & TASK3_STATUS_FLAG_DUPLICATE) != 0);
    ASSERT_TRUE(duplicate.actuator_q15 == first.actuator_q15);
    ASSERT_TRUE(duplicate.pwm == first.pwm);
    ASSERT_TRUE(duplicate.processing_us == first.processing_us);
    ASSERT_TRUE(first.echoed_tx_monotonic_ns == UINT64_C(200));
    ASSERT_TRUE(duplicate.echoed_tx_monotonic_ns == UINT64_C(300));
    ASSERT_TRUE(app.requests == 1);
    ASSERT_TRUE(app.applied_steps == 1);
    ASSERT_TRUE(print_calls == 0);

    app.verbose = 1;
    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_STEP, TASK3_MODE_AI,
                             TASK3_CLASS_RIGHT, 7, UINT64_C(400)) == 0);
    ASSERT_TRUE(print_calls == 1);
    app.verbose = 0;

    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_RESET, TASK3_MODE_FIXED,
                             TASK3_CLASS_CENTER, 0, UINT64_C(450)) == 0);
    ASSERT_TRUE(app.controller.applied_steps == 0);
    ASSERT_TRUE(app.applied_steps == 1);
    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_STEP, TASK3_MODE_FIXED,
                             TASK3_CLASS_RIGHT, 0, UINT64_C(475)) == 0);
    ASSERT_TRUE(app.controller.applied_steps == 1);
    ASSERT_TRUE(app.requests == 2);
    ASSERT_TRUE(app.applied_steps == 2);

    malformed[0] = 2;
    malformed[1] = 99;
    capture.responses = 0;
    ASSERT_TRUE(task3_server_handle_message(&app, RTIPC_MSG_CTRL_CMD, malformed,
                                            sizeof(malformed), 20) == 0);
    ASSERT_TRUE(capture.responses == 1 &&
                capture.message_type == RTIPC_MSG_ERROR_NOTIFY);
    ASSERT_TRUE(task3_decode_error(capture.payload, capture.length, &error) ==
                TASK3_CODEC_OK);
    ASSERT_TRUE(error.category == TASK3_ERROR_CATEGORY_PROTOCOL);
    ASSERT_TRUE(app.controller.applied_steps == applied);
    ASSERT_TRUE(app.requests == 2);
    ASSERT_TRUE(app.applied_steps == 2);

    ASSERT_TRUE(send_control(&app, &capture, TASK3_CMD_STOP, TASK3_MODE_AI,
                             TASK3_CLASS_CENTER, 8, UINT64_C(500)) == 0);
    ASSERT_TRUE(task3_decode_status(capture.payload, capture.length, &first) ==
                TASK3_CODEC_OK);
    ASSERT_TRUE(first.status == TASK3_STATUS_STOPPED);
    ASSERT_TRUE(app.stop_requested);
    ASSERT_TRUE(app.requests == 2);
    ASSERT_TRUE(app.applied_steps == 2);
    ASSERT_TRUE(print_calls == 1);
    puts("test_rtthread_server: PASS");
    return 0;
}
