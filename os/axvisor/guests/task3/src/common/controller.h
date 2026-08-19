#ifndef TASK3_CONTROLLER_H
#define TASK3_CONTROLLER_H

#include "task3_protocol.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int16_t actuator_q15;
    uint64_t applied_steps;
    uint32_t last_frame_id;
    task3_status_t cached_status;
    bool has_cached_step;
    bool stopped;
} task3_controller_t;

void task3_controller_init(task3_controller_t *controller);
void task3_controller_reset(task3_controller_t *controller);
task3_app_error_code_t task3_controller_apply(
    task3_controller_t *controller, const task3_control_t *control,
    task3_status_t *status);

#ifdef __cplusplus
}
#endif

#endif
