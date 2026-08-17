#include "controller.h"

#include <limits.h>
#include <string.h>

enum {
    TASK3_TARGET_LEFT = -20000,
    TASK3_TARGET_CENTER = 0,
    TASK3_TARGET_RIGHT = 20000,
    TASK3_PWM_LIMIT = 1000,
    TASK3_POSITION_STEP = 4,
};

static int valid_mode(task3_mode_t mode)
{
    return mode == TASK3_MODE_FIXED || mode == TASK3_MODE_AI;
}

static int valid_class(task3_class_t klass)
{
    return klass >= TASK3_CLASS_UNKNOWN && klass <= TASK3_CLASS_RIGHT;
}

static int clamp_int(int value, int minimum, int maximum)
{
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static task3_status_t base_status(const task3_controller_t *controller,
                                  const task3_control_t *control)
{
    task3_status_t status;

    memset(&status, 0, sizeof(status));
    status.status = controller->stopped ? TASK3_STATUS_STOPPED : TASK3_STATUS_OK;
    status.applied_class = TASK3_CLASS_CENTER;
    status.frame_id = control->frame_id;
    status.actuator_q15 = controller->actuator_q15;
    status.echoed_tx_monotonic_ns = control->tx_monotonic_ns;
    return status;
}

void task3_controller_init(task3_controller_t *controller)
{
    if (controller != NULL) {
        memset(controller, 0, sizeof(*controller));
    }
}

void task3_controller_reset(task3_controller_t *controller)
{
    task3_controller_init(controller);
}

static int target_for_class(task3_class_t klass)
{
    switch (klass) {
    case TASK3_CLASS_LEFT:
        return TASK3_TARGET_LEFT;
    case TASK3_CLASS_CENTER:
        return TASK3_TARGET_CENTER;
    case TASK3_CLASS_RIGHT:
        return TASK3_TARGET_RIGHT;
    case TASK3_CLASS_UNKNOWN:
    default:
        return TASK3_TARGET_CENTER;
    }
}

static task3_app_error_code_t apply_step(task3_controller_t *controller,
                                         const task3_control_t *control,
                                         task3_status_t *status)
{
    task3_status_t next_status;
    task3_class_t applied_class;
    int target;
    int pwm;
    int position;

    if (controller->stopped) {
        return TASK3_APP_INVALID_STATE;
    }
    if (controller->has_cached_step &&
        control->frame_id == controller->last_frame_id) {
        *status = controller->cached_status;
        status->flags |= TASK3_STATUS_FLAG_DUPLICATE;
        return TASK3_APP_OK;
    }
    if (!valid_mode(control->mode)) {
        return TASK3_APP_INVALID_MODE;
    }
    if (!valid_class(control->klass) ||
        (control->mode == TASK3_MODE_AI &&
         control->klass == TASK3_CLASS_UNKNOWN)) {
        return TASK3_APP_INVALID_CLASS;
    }

    applied_class = control->mode == TASK3_MODE_FIXED ? TASK3_CLASS_CENTER
                                                       : control->klass;
    target = target_for_class(applied_class);
    pwm = clamp_int((target - controller->actuator_q15) / 16,
                    -TASK3_PWM_LIMIT, TASK3_PWM_LIMIT);
    position = clamp_int(controller->actuator_q15 + pwm * TASK3_POSITION_STEP,
                         INT16_MIN, INT16_MAX);

    next_status = base_status(controller, control);
    next_status.applied_class = applied_class;
    next_status.pwm = (int16_t)pwm;
    next_status.actuator_q15 = (int16_t)position;

    controller->actuator_q15 = (int16_t)position;
    controller->applied_steps++;
    controller->last_frame_id = control->frame_id;
    controller->cached_status = next_status;
    controller->has_cached_step = true;
    *status = next_status;
    return TASK3_APP_OK;
}

task3_app_error_code_t task3_controller_apply(
    task3_controller_t *controller, const task3_control_t *control,
    task3_status_t *status)
{
    task3_status_t next_status;

    if (controller == NULL || control == NULL || status == NULL) {
        return TASK3_APP_INVALID_STATE;
    }
    if (!valid_mode(control->mode) || !valid_class(control->klass)) {
        return !valid_mode(control->mode) ? TASK3_APP_INVALID_MODE
                                          : TASK3_APP_INVALID_CLASS;
    }

    switch (control->command) {
    case TASK3_CMD_RESET:
        task3_controller_reset(controller);
        *status = base_status(controller, control);
        return TASK3_APP_OK;
    case TASK3_CMD_STEP:
        return apply_step(controller, control, status);
    case TASK3_CMD_STOP:
        controller->stopped = true;
        next_status = base_status(controller, control);
        next_status.status = TASK3_STATUS_STOPPED;
        *status = next_status;
        return TASK3_APP_OK;
    default:
        return TASK3_APP_INVALID_COMMAND;
    }
}
