#ifndef TASK3_PROTOCOL_H
#define TASK3_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TASK3_SCHEMA_VERSION UINT8_C(1)
#define TASK3_CTRL_WIRE_SIZE 24U
#define TASK3_STATUS_WIRE_SIZE 24U
#define TASK3_ERROR_WIRE_SIZE 12U

typedef enum {
    TASK3_CODEC_OK = 0,
    TASK3_CODEC_NULL_ARGUMENT = -1,
    TASK3_CODEC_INVALID_LENGTH = -2,
    TASK3_CODEC_INVALID_VERSION = -3,
    TASK3_CODEC_INVALID_FIELD = -4,
    TASK3_CODEC_NONZERO_RESERVED = -5,
} task3_codec_result_t;

typedef enum {
    TASK3_CMD_RESET = 1,
    TASK3_CMD_STEP = 2,
    TASK3_CMD_STOP = 3,
} task3_command_t;

typedef enum {
    TASK3_MODE_FIXED = 0,
    TASK3_MODE_AI = 1,
} task3_mode_t;

typedef enum {
    TASK3_CLASS_UNKNOWN = 0,
    TASK3_CLASS_LEFT = 1,
    TASK3_CLASS_CENTER = 2,
    TASK3_CLASS_RIGHT = 3,
} task3_class_t;

typedef enum {
    TASK3_STATUS_OK = 0,
    TASK3_STATUS_STOPPED = 1,
} task3_status_code_t;

enum {
    TASK3_STATUS_FLAG_DUPLICATE = 1U << 0,
    TASK3_STATUS_FLAGS_MASK = TASK3_STATUS_FLAG_DUPLICATE,
};

typedef enum {
    TASK3_ERROR_CATEGORY_PROTOCOL = 1,
    TASK3_ERROR_CATEGORY_APPLICATION = 2,
} task3_error_category_t;

typedef enum {
    TASK3_APP_OK = 0,
    TASK3_APP_INVALID_COMMAND = 1,
    TASK3_APP_INVALID_MODE = 2,
    TASK3_APP_INVALID_CLASS = 3,
    TASK3_APP_INVALID_STATE = 4,
} task3_app_error_code_t;

typedef struct {
    task3_command_t command;
    task3_mode_t mode;
    task3_class_t klass;
    uint16_t confidence_q15;
    uint32_t frame_id;
    uint64_t tx_monotonic_ns;
} task3_control_t;

typedef struct {
    task3_status_code_t status;
    task3_class_t applied_class;
    uint8_t flags;
    uint32_t frame_id;
    int16_t pwm;
    int16_t actuator_q15;
    uint32_t processing_us;
    uint64_t echoed_tx_monotonic_ns;
} task3_status_t;

typedef struct {
    task3_error_category_t category;
    task3_app_error_code_t code;
    uint32_t frame_id;
    uint32_t detail;
} task3_error_t;

int task3_encode_control(const task3_control_t *value,
                         uint8_t out[TASK3_CTRL_WIRE_SIZE]);
int task3_decode_control(const uint8_t *wire, size_t len,
                         task3_control_t *out);
int task3_encode_status(const task3_status_t *value,
                        uint8_t out[TASK3_STATUS_WIRE_SIZE]);
int task3_decode_status(const uint8_t *wire, size_t len,
                        task3_status_t *out);
int task3_encode_error(const task3_error_t *value,
                       uint8_t out[TASK3_ERROR_WIRE_SIZE]);
int task3_decode_error(const uint8_t *wire, size_t len, task3_error_t *out);

#ifdef __cplusplus
}
#endif

#endif
