#include "metrics.h"

#include <inttypes.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int compare_u64(const void *left, const void *right)
{
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;

    return a > b ? 1 : a < b ? -1 : 0;
}

static size_t nearest_rank(size_t count, size_t percentile)
{
    size_t rank = (count * percentile + 99) / 100;

    return rank == 0 ? 0 : rank - 1;
}

int task3_metric_summarize(const uint64_t *values, size_t count,
                           task3_metric_summary_t *summary)
{
    uint64_t sorted[TASK3_MAX_FRAME_RECORDS];
    uint64_t sum = 0;
    size_t index;

    if (values == NULL || summary == NULL || count == 0 ||
        count > TASK3_MAX_FRAME_RECORDS) {
        return -1;
    }
    memcpy(sorted, values, count * sizeof(sorted[0]));
    qsort(sorted, count, sizeof(sorted[0]), compare_u64);
    for (index = 0; index < count; index++) {
        if (sum > UINT64_MAX - sorted[index]) {
            return -1;
        }
        sum += sorted[index];
    }
    summary->minimum = sorted[0];
    summary->mean = sum / count;
    summary->p50 = sorted[nearest_rank(count, 50)];
    summary->p95 = sorted[nearest_rank(count, 95)];
    summary->p99 = sorted[nearest_rank(count, 99)];
    summary->maximum = sorted[count - 1];
    return 0;
}

int task3_find_settling_frames(const int16_t *targets, const int16_t *positions,
                               size_t count, size_t transition_index,
                               uint16_t tolerance, size_t consecutive,
                               size_t *settling_frames)
{
    size_t in_band = 0;
    size_t index;

    if (targets == NULL || positions == NULL || settling_frames == NULL ||
        transition_index >= count || consecutive == 0) {
        return -1;
    }
    for (index = transition_index; index < count; index++) {
        int32_t error = (int32_t)positions[index] - targets[index];
        uint32_t magnitude = (uint32_t)(error < 0 ? -error : error);

        if (magnitude <= tolerance) {
            in_band++;
            if (in_band == consecutive) {
                *settling_frames = index + 1 - consecutive - transition_index;
                return 0;
            }
        } else {
            in_band = 0;
        }
    }
    return -1;
}

void task3_metrics_init(task3_metrics_t *metrics)
{
    if (metrics != NULL) {
        memset(metrics, 0, sizeof(*metrics));
    }
}

int task3_metrics_append(task3_metrics_t *metrics,
                         const task3_frame_record_t *record)
{
    if (metrics == NULL || record == NULL ||
        metrics->count >= TASK3_MAX_FRAME_RECORDS) {
        return -1;
    }
    metrics->records[metrics->count++] = *record;
    return 0;
}

int task3_metrics_write_header(FILE *stream)
{
    if (stream == NULL) {
        return -1;
    }
    if (fputs("# task3_csv_schema=1\n", stream) == EOF ||
        fputs("mode,frame_id,target_q15,truth_class,predicted_class,"
              "confidence_q15,inference_us,transport_retries,rtos_status,pwm,"
              "actuator_q15,rtos_processing_us,round_trip_us,error_code,"
              "duplicate,recovered\n",
              stream) == EOF) {
        return -1;
    }
    return fflush(stream) == 0 ? 0 : -1;
}

static int write_record(FILE *stream, const char *prefix,
                        const task3_frame_record_t *record)
{
    const char *mode = record->mode == 0 ? "FIXED" : "AI";

    return fprintf(stream,
                   "%s%s,%" PRIu32 ",%d,%u,%u,%u,%" PRIu32 ",%" PRIu32
                   ",%u,%d,%d,%" PRIu32 ",%" PRIu64 ",%u,%u,%u\n",
                   prefix, mode, record->frame_id, record->target_q15,
                   record->truth_class, record->predicted_class,
                   record->confidence_q15, record->inference_us,
                   record->transport_retries, record->rtos_status, record->pwm,
                   record->actuator_q15, record->rtos_processing_us,
                   record->round_trip_us, record->error_code, record->duplicate,
                   record->recovered) < 0
               ? -1
               : 0;
}

int task3_metrics_write_record(FILE *stream,
                               const task3_frame_record_t *record,
                               int emit_serial_marker)
{
    if (stream == NULL || record == NULL || write_record(stream, "", record) != 0 ||
        fflush(stream) != 0) {
        return -1;
    }
    if (emit_serial_marker &&
        (write_record(stdout, "TASK3_FRAME_CSV=", record) != 0 ||
         fflush(stdout) != 0)) {
        return -1;
    }
    return 0;
}
