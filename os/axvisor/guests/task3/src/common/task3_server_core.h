#ifndef TASK3_SERVER_H
#define TASK3_SERVER_H

#include <stddef.h>
#include <stdint.h>

#include "controller.h"
#include "rt_ipc.h"

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

void task3_server_app_init(task3_server_app_t *app,
                           task3_server_reply_fn send_reply,
                           void *reply_context);
int task3_server_handle_message(task3_server_app_t *app, uint8_t message_type,
                                const uint8_t *payload, size_t length,
                                uint64_t now_ms);
uint64_t task3_server_high_resolution_us(void);
void task3_server_print_status(const task3_status_t *status,
                               const task3_control_t *control);

#endif
