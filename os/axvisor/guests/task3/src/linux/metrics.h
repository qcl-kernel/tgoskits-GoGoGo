#ifndef TASK3_METRICS_H
#define TASK3_METRICS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { TASK3_MAX_FRAME_RECORDS = 1200 };

typedef struct {
    uint64_t minimum;
    uint64_t mean;
    uint64_t p50;
    uint64_t p95;
    uint64_t p99;
    uint64_t maximum;
} task3_metric_summary_t;

typedef struct {
    uint8_t mode;
    uint32_t frame_id;
    int16_t target_q15;
    uint8_t truth_class;
    uint8_t predicted_class;
    uint16_t confidence_q15;
    uint32_t inference_us;
    uint32_t transport_retries;
    uint8_t rtos_status;
    int16_t pwm;
    int16_t actuator_q15;
    uint32_t rtos_processing_us;
    uint64_t round_trip_us;
    uint16_t error_code;
    uint8_t duplicate;
    uint8_t recovered;
} task3_frame_record_t;

typedef struct {
    task3_frame_record_t records[TASK3_MAX_FRAME_RECORDS];
    size_t count;
} task3_metrics_t;

int task3_metric_summarize(const uint64_t *values, size_t count,
                           task3_metric_summary_t *summary);
int task3_find_settling_frames(const int16_t *targets, const int16_t *positions,
                               size_t count, size_t transition_index,
                               uint16_t tolerance, size_t consecutive,
                               size_t *settling_frames);
void task3_metrics_init(task3_metrics_t *metrics);
int task3_metrics_append(task3_metrics_t *metrics,
                         const task3_frame_record_t *record);
int task3_metrics_write_header(FILE *stream);
int task3_metrics_write_record(FILE *stream,
                               const task3_frame_record_t *record,
                               int emit_serial_marker);

#ifdef __cplusplus
}
#endif

#endif
