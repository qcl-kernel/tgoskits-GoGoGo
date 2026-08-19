#include "controller.h"

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

static task3_control_t command(task3_command_t kind, task3_mode_t mode,
                               task3_class_t klass, uint32_t frame_id)
{
    task3_control_t value = {
        .command = kind,
        .mode = mode,
        .klass = klass,
        .confidence_q15 = 30000,
        .frame_id = frame_id,
        .tx_monotonic_ns = UINT64_C(123456789),
    };
    return value;
}

static void test_reset_and_fixed_step(void)
{
    task3_controller_t controller;
    task3_status_t status;
    task3_control_t reset =
        command(TASK3_CMD_RESET, TASK3_MODE_FIXED, TASK3_CLASS_UNKNOWN, 0);
    task3_control_t step =
        command(TASK3_CMD_STEP, TASK3_MODE_FIXED, TASK3_CLASS_RIGHT, 1);

    task3_controller_init(&controller);
    controller.actuator_q15 = 12000;
    controller.applied_steps = 9;
    CHECK(task3_controller_apply(&controller, &reset, &status) == TASK3_APP_OK);
    CHECK(controller.actuator_q15 == 0);
    CHECK(controller.applied_steps == 0);
    CHECK(status.frame_id == 0);
    CHECK(status.pwm == 0);
    CHECK(status.actuator_q15 == 0);

    CHECK(task3_controller_apply(&controller, &step, &status) == TASK3_APP_OK);
    CHECK(status.applied_class == TASK3_CLASS_CENTER);
    CHECK(status.pwm == 0);
    CHECK(status.actuator_q15 == 0);
    CHECK(controller.applied_steps == 1);
}

static void test_ai_mapping_and_limits(void)
{
    task3_controller_t controller;
    task3_status_t status;
    task3_control_t left =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_LEFT, 1);
    task3_control_t center =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_CENTER, 2);
    task3_control_t right =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_RIGHT, 3);

    task3_controller_init(&controller);
    CHECK(task3_controller_apply(&controller, &left, &status) == TASK3_APP_OK);
    CHECK(status.pwm == -1000);
    CHECK(status.actuator_q15 == -4000);
    CHECK(task3_controller_apply(&controller, &center, &status) == TASK3_APP_OK);
    CHECK(status.pwm == 250);
    CHECK(status.actuator_q15 == -3000);
    CHECK(task3_controller_apply(&controller, &right, &status) == TASK3_APP_OK);
    CHECK(status.pwm == 1000);
    CHECK(status.actuator_q15 == 1000);

    controller.actuator_q15 = 32760;
    right.frame_id = 4;
    CHECK(task3_controller_apply(&controller, &right, &status) == TASK3_APP_OK);
    CHECK(status.pwm < 0);
    CHECK(status.actuator_q15 <= 32767);
    controller.actuator_q15 = -32760;
    left.frame_id = 5;
    CHECK(task3_controller_apply(&controller, &left, &status) == TASK3_APP_OK);
    CHECK(status.pwm > 0);
    CHECK(status.actuator_q15 >= -32768);
}

static void test_duplicate_is_idempotent(void)
{
    task3_controller_t controller;
    task3_control_t step =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_RIGHT, 7);
    task3_status_t first;
    task3_status_t duplicate;
    uint64_t applied;

    task3_controller_init(&controller);
    CHECK(task3_controller_apply(&controller, &step, &first) == TASK3_APP_OK);
    applied = controller.applied_steps;
    CHECK(task3_controller_apply(&controller, &step, &duplicate) == TASK3_APP_OK);
    CHECK(controller.applied_steps == applied);
    CHECK((duplicate.flags & TASK3_STATUS_FLAG_DUPLICATE) != 0);
    CHECK(first.actuator_q15 == duplicate.actuator_q15);
    CHECK(first.pwm == duplicate.pwm);
    CHECK(first.frame_id == duplicate.frame_id);
}

static void test_invalid_step_does_not_mutate(void)
{
    task3_controller_t controller;
    task3_controller_t before;
    task3_status_t status;
    task3_control_t invalid =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_UNKNOWN, 1);

    task3_controller_init(&controller);
    before = controller;
    CHECK(task3_controller_apply(&controller, &invalid, &status) ==
          TASK3_APP_INVALID_CLASS);
    CHECK(memcmp(&controller, &before, sizeof(controller)) == 0);

    invalid.klass = TASK3_CLASS_LEFT;
    invalid.mode = (task3_mode_t)99;
    CHECK(task3_controller_apply(&controller, &invalid, &status) ==
          TASK3_APP_INVALID_MODE);
    CHECK(memcmp(&controller, &before, sizeof(controller)) == 0);
}

static void test_stop_blocks_steps_until_reset(void)
{
    task3_controller_t controller;
    task3_status_t status;
    task3_control_t stop =
        command(TASK3_CMD_STOP, TASK3_MODE_FIXED, TASK3_CLASS_UNKNOWN, 1);
    task3_control_t step =
        command(TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_LEFT, 2);
    task3_control_t reset =
        command(TASK3_CMD_RESET, TASK3_MODE_FIXED, TASK3_CLASS_UNKNOWN, 3);

    task3_controller_init(&controller);
    CHECK(task3_controller_apply(&controller, &stop, &status) == TASK3_APP_OK);
    CHECK(status.status == TASK3_STATUS_STOPPED);
    CHECK(task3_controller_apply(&controller, &step, &status) ==
          TASK3_APP_INVALID_STATE);
    CHECK(controller.applied_steps == 0);
    CHECK(task3_controller_apply(&controller, &reset, &status) == TASK3_APP_OK);
    CHECK(task3_controller_apply(&controller, &step, &status) == TASK3_APP_OK);
}

int main(void)
{
    test_reset_and_fixed_step();
    test_ai_mapping_and_limits();
    test_duplicate_is_idempotent();
    test_invalid_step_does_not_mutate();
    test_stop_blocks_steps_until_reset();

    if (failures != 0) {
        fprintf(stderr, "test_controller: %d failure(s)\n", failures);
        return 1;
    }
    puts("test_controller: PASS");
    return 0;
}
