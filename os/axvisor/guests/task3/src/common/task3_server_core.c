#include "controller.h"
#include "task3_server_core.h"
#include "rt_ipc.h"
#include "task3_protocol.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef __weak
#if defined(__GNUC__) || defined(__clang__)
#define __weak __attribute__((weak))
#else
#define __weak
#endif
#endif

#ifdef TASK3_HOST_TEST
uint64_t task3_server_high_resolution_us(void)
{
    return 0;
}
#else
uint64_t task3_server_high_resolution_us(void)
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
    if (message_type != RTIPC_MSG_CTRL_CMD) {
        return send_error(app, payload, length, TASK3_CODEC_INVALID_FIELD,
                          now_ms);
    }
    result = task3_decode_control(payload, length, &control);
    if (result != TASK3_CODEC_OK) {
        return send_error(app, payload, length, result, now_ms);
    }
    started = task3_server_high_resolution_us();
    result = task3_controller_apply(&app->controller, &control, &status);
    finished = task3_server_high_resolution_us();
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
    if (control.command == TASK3_CMD_STEP &&
        (status.flags & TASK3_STATUS_FLAG_DUPLICATE) == 0) {
        app->requests++;
        app->applied_steps++;
    }
    if (control.command == TASK3_CMD_STOP) {
        app->stop_requested = 1;
    }
    if (app->verbose)
        task3_server_print_status(&status, &control);
    if (task3_encode_status(&status, wire) != TASK3_CODEC_OK) {
        return -1;
    }
    return app->send_reply(app->reply_context, RTIPC_MSG_STATUS_REP, wire,
                           sizeof(wire), now_ms);
}

__weak void task3_server_print_status(const task3_status_t *status,
                                      const task3_control_t *control)
{
    (void)status;
    (void)control;
}
