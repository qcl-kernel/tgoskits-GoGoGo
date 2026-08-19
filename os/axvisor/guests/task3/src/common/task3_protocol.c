#include "task3_protocol.h"

#include <limits.h>

static uint16_t read_be16(const uint8_t *wire)
{
    return (uint16_t)((uint16_t)wire[0] << 8) | (uint16_t)wire[1];
}

static uint32_t read_be32(const uint8_t *wire)
{
    return (uint32_t)wire[0] << 24 | (uint32_t)wire[1] << 16 |
           (uint32_t)wire[2] << 8 | (uint32_t)wire[3];
}

static uint64_t read_be64(const uint8_t *wire)
{
    return (uint64_t)read_be32(wire) << 32 | read_be32(wire + 4);
}

static int16_t read_be_i16(const uint8_t *wire)
{
    uint16_t bits = read_be16(wire);

    if (bits <= INT16_MAX) {
        return (int16_t)bits;
    }
    return (int16_t)(-((int32_t)(UINT16_MAX - bits)) - 1);
}

static void write_be16(uint8_t *wire, uint16_t value)
{
    wire[0] = (uint8_t)(value >> 8);
    wire[1] = (uint8_t)value;
}

static void write_be32(uint8_t *wire, uint32_t value)
{
    wire[0] = (uint8_t)(value >> 24);
    wire[1] = (uint8_t)(value >> 16);
    wire[2] = (uint8_t)(value >> 8);
    wire[3] = (uint8_t)value;
}

static void write_be64(uint8_t *wire, uint64_t value)
{
    write_be32(wire, (uint32_t)(value >> 32));
    write_be32(wire + 4, (uint32_t)value);
}

static int valid_command(task3_command_t value)
{
    return value == TASK3_CMD_RESET || value == TASK3_CMD_STEP ||
           value == TASK3_CMD_STOP;
}

static int valid_mode(task3_mode_t value)
{
    return value == TASK3_MODE_FIXED || value == TASK3_MODE_AI;
}

static int valid_class(task3_class_t value)
{
    return value >= TASK3_CLASS_UNKNOWN && value <= TASK3_CLASS_RIGHT;
}

static int valid_status(task3_status_code_t value)
{
    return value == TASK3_STATUS_OK || value == TASK3_STATUS_STOPPED;
}

static int valid_error_category(task3_error_category_t value)
{
    return value == TASK3_ERROR_CATEGORY_PROTOCOL ||
           value == TASK3_ERROR_CATEGORY_APPLICATION;
}

static int valid_error_code(task3_app_error_code_t value)
{
    return value >= TASK3_APP_OK && value <= TASK3_APP_INVALID_STATE;
}

int task3_encode_control(const task3_control_t *value,
                         uint8_t out[TASK3_CTRL_WIRE_SIZE])
{
    if (value == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (!valid_command(value->command) || !valid_mode(value->mode) ||
        !valid_class(value->klass) || value->confidence_q15 > 32767) {
        return TASK3_CODEC_INVALID_FIELD;
    }

    out[0] = TASK3_SCHEMA_VERSION;
    out[1] = (uint8_t)value->command;
    out[2] = (uint8_t)value->mode;
    out[3] = (uint8_t)value->klass;
    write_be16(out + 4, value->confidence_q15);
    write_be16(out + 6, 0);
    write_be32(out + 8, value->frame_id);
    write_be64(out + 12, value->tx_monotonic_ns);
    write_be32(out + 20, 0);
    return TASK3_CODEC_OK;
}

int task3_decode_control(const uint8_t *wire, size_t len,
                         task3_control_t *out)
{
    task3_control_t decoded;

    if (wire == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (len != TASK3_CTRL_WIRE_SIZE) {
        return TASK3_CODEC_INVALID_LENGTH;
    }
    if (wire[0] != TASK3_SCHEMA_VERSION) {
        return TASK3_CODEC_INVALID_VERSION;
    }
    decoded.command = (task3_command_t)wire[1];
    decoded.mode = (task3_mode_t)wire[2];
    decoded.klass = (task3_class_t)wire[3];
    if (!valid_command(decoded.command) || !valid_mode(decoded.mode) ||
        !valid_class(decoded.klass)) {
        return TASK3_CODEC_INVALID_FIELD;
    }
    if (read_be16(wire + 6) != 0 || read_be32(wire + 20) != 0) {
        return TASK3_CODEC_NONZERO_RESERVED;
    }
    decoded.confidence_q15 = read_be16(wire + 4);
    if (decoded.confidence_q15 > 32767) {
        return TASK3_CODEC_INVALID_FIELD;
    }
    decoded.frame_id = read_be32(wire + 8);
    decoded.tx_monotonic_ns = read_be64(wire + 12);
    *out = decoded;
    return TASK3_CODEC_OK;
}

int task3_encode_status(const task3_status_t *value,
                        uint8_t out[TASK3_STATUS_WIRE_SIZE])
{
    if (value == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (!valid_status(value->status) || !valid_class(value->applied_class) ||
        (value->flags & (uint8_t)~TASK3_STATUS_FLAGS_MASK) != 0) {
        return TASK3_CODEC_INVALID_FIELD;
    }

    out[0] = TASK3_SCHEMA_VERSION;
    out[1] = (uint8_t)value->status;
    out[2] = (uint8_t)value->applied_class;
    out[3] = value->flags;
    write_be32(out + 4, value->frame_id);
    write_be16(out + 8, (uint16_t)value->pwm);
    write_be16(out + 10, (uint16_t)value->actuator_q15);
    write_be32(out + 12, value->processing_us);
    write_be64(out + 16, value->echoed_tx_monotonic_ns);
    return TASK3_CODEC_OK;
}

int task3_decode_status(const uint8_t *wire, size_t len,
                        task3_status_t *out)
{
    task3_status_t decoded;

    if (wire == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (len != TASK3_STATUS_WIRE_SIZE) {
        return TASK3_CODEC_INVALID_LENGTH;
    }
    if (wire[0] != TASK3_SCHEMA_VERSION) {
        return TASK3_CODEC_INVALID_VERSION;
    }
    decoded.status = (task3_status_code_t)wire[1];
    decoded.applied_class = (task3_class_t)wire[2];
    decoded.flags = wire[3];
    if (!valid_status(decoded.status) || !valid_class(decoded.applied_class) ||
        (decoded.flags & (uint8_t)~TASK3_STATUS_FLAGS_MASK) != 0) {
        return TASK3_CODEC_INVALID_FIELD;
    }
    decoded.frame_id = read_be32(wire + 4);
    decoded.pwm = read_be_i16(wire + 8);
    decoded.actuator_q15 = read_be_i16(wire + 10);
    decoded.processing_us = read_be32(wire + 12);
    decoded.echoed_tx_monotonic_ns = read_be64(wire + 16);
    *out = decoded;
    return TASK3_CODEC_OK;
}

int task3_encode_error(const task3_error_t *value,
                       uint8_t out[TASK3_ERROR_WIRE_SIZE])
{
    if (value == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (!valid_error_category(value->category) ||
        !valid_error_code(value->code)) {
        return TASK3_CODEC_INVALID_FIELD;
    }

    out[0] = TASK3_SCHEMA_VERSION;
    out[1] = (uint8_t)value->category;
    write_be16(out + 2, (uint16_t)value->code);
    write_be32(out + 4, value->frame_id);
    write_be32(out + 8, value->detail);
    return TASK3_CODEC_OK;
}

int task3_decode_error(const uint8_t *wire, size_t len, task3_error_t *out)
{
    task3_error_t decoded;

    if (wire == NULL || out == NULL) {
        return TASK3_CODEC_NULL_ARGUMENT;
    }
    if (len != TASK3_ERROR_WIRE_SIZE) {
        return TASK3_CODEC_INVALID_LENGTH;
    }
    if (wire[0] != TASK3_SCHEMA_VERSION) {
        return TASK3_CODEC_INVALID_VERSION;
    }
    decoded.category = (task3_error_category_t)wire[1];
    decoded.code = (task3_app_error_code_t)read_be16(wire + 2);
    if (!valid_error_category(decoded.category) ||
        !valid_error_code(decoded.code)) {
        return TASK3_CODEC_INVALID_FIELD;
    }
    decoded.frame_id = read_be32(wire + 4);
    decoded.detail = read_be32(wire + 8);
    *out = decoded;
    return TASK3_CODEC_OK;
}
