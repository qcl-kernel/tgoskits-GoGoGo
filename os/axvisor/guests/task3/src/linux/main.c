#define _GNU_SOURCE

#include "cnn.h"
#include "metrics.h"
#include "rtipc_client.h"
#include "task3_protocol.h"
#include "y4m.h"

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    TASK3_DEFAULT_PORT = 9877,
    TASK3_DEFAULT_FRAMES = 600,
    TASK3_MAX_FRAMES_PER_MODE = 600,
    TASK3_CONNECT_TIMEOUT_MS = 60000,
    TASK3_SETTLING_TOLERANCE_Q15 = 100,
    TASK3_SETTLING_CONSECUTIVE = 3,
};

typedef struct {
    uint32_t frame_id;
    int16_t target_q15;
    uint8_t klass;
} truth_row_t;

typedef struct {
    const char *video_path;
    const char *truth_path;
    const char *peer_ipv4;
    const char *csv_path;
    uint16_t peer_port;
    uint32_t frames;
    uint64_t drop_tx_sequence;
    int duplicate_frame_once;
    int malformed_once;
} options_t;

static void print_usage(FILE *stream, const char *program)
{
    fprintf(stream,
            "Usage: %s [options]\n"
            "  --video PATH        Y4M input (default /opt/task3/line-follow.y4m)\n"
            "  --truth PATH        truth CSV (default /opt/task3/truth.csv)\n"
            "  --peer IPV4         RT-Thread peer (default 192.168.77.30)\n"
            "  --port PORT         UDP peer port (default 9877)\n"
            "  --frames N          frames per mode, 1..600 (default 600)\n"
            "  --csv PATH          result CSV (default /tmp/task3-frames.csv)\n"
            "  --drop-tx-seq N     drop the Nth CTRL_CMD transmit attempt\n"
            "  --duplicate-frame-once  resend one AI frame transaction\n"
            "  --malformed-once    exercise schema, length, and CRC rejection\n"
            "  --help              show this help\n",
            program);
}

static int parse_u64(const char *text, uint64_t *value)
{
    char *end;
    unsigned long long parsed;

    if (text == NULL || *text == '\0' || *text == '-') {
        return -1;
    }
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || *end != '\0') {
        return -1;
    }
    *value = (uint64_t)parsed;
    return 0;
}

static int parse_options(int argc, char **argv, options_t *options)
{
    static const struct option long_options[] = {
        {"video", required_argument, NULL, 'v'},
        {"truth", required_argument, NULL, 't'},
        {"peer", required_argument, NULL, 'p'},
        {"port", required_argument, NULL, 'P'},
        {"frames", required_argument, NULL, 'n'},
        {"csv", required_argument, NULL, 'c'},
        {"drop-tx-seq", required_argument, NULL, 'd'},
        {"duplicate-frame-once", no_argument, NULL, 'D'},
        {"malformed-once", no_argument, NULL, 'M'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };
    int option;

    memset(options, 0, sizeof(*options));
    options->video_path = "/opt/task3/line-follow.y4m";
    options->truth_path = "/opt/task3/truth.csv";
    options->peer_ipv4 = "192.168.77.30";
    options->csv_path = "/tmp/task3-frames.csv";
    options->peer_port = TASK3_DEFAULT_PORT;
    options->frames = TASK3_DEFAULT_FRAMES;
    opterr = 0;
    while ((option = getopt_long(argc, argv, "", long_options, NULL)) != -1) {
        uint64_t parsed;

        switch (option) {
        case 'v':
            options->video_path = optarg;
            break;
        case 't':
            options->truth_path = optarg;
            break;
        case 'p':
            options->peer_ipv4 = optarg;
            break;
        case 'P':
            if (parse_u64(optarg, &parsed) != 0 || parsed == 0 ||
                parsed > UINT16_MAX) {
                return -1;
            }
            options->peer_port = (uint16_t)parsed;
            break;
        case 'n':
            if (parse_u64(optarg, &parsed) != 0 || parsed == 0 ||
                parsed > TASK3_MAX_FRAMES_PER_MODE) {
                return -1;
            }
            options->frames = (uint32_t)parsed;
            break;
        case 'c':
            options->csv_path = optarg;
            break;
        case 'd':
            if (parse_u64(optarg, &options->drop_tx_sequence) != 0) {
                return -1;
            }
            break;
        case 'D':
            options->duplicate_frame_once = 1;
            break;
        case 'M':
            options->malformed_once = 1;
            break;
        case 'h':
            print_usage(stdout, argv[0]);
            return 1;
        default:
            return -1;
        }
    }
    return optind == argc ? 0 : -1;
}

static int load_video(const char *path, uint32_t frame_count,
                      uint8_t (*pixels)[TASK3_Y4M_FRAME_BYTES],
                      uint32_t *fps_numerator, uint32_t *fps_denominator)
{
    y4m_reader_t reader;
    y4m_result_t result;
    uint32_t index;

    result = y4m_reader_open(&reader, path);
    if (result != Y4M_OK) {
        fprintf(stderr, "cannot open video: %s\n", path);
        return -1;
    }
    *fps_numerator = reader.fps_numerator;
    *fps_denominator = reader.fps_denominator;
    for (index = 0; index < frame_count; index++) {
        uint32_t frame_id;

        result = y4m_reader_next(&reader, pixels[index],
                                 TASK3_Y4M_FRAME_BYTES, &frame_id);
        if (result != Y4M_OK || frame_id != index) {
            fprintf(stderr, "video has fewer or invalid requested frames\n");
            y4m_reader_close(&reader);
            return -1;
        }
    }
    y4m_reader_close(&reader);
    return 0;
}

static int trim_line(char *line)
{
    size_t length = strlen(line);

    if (length == 0 || line[length - 1] != '\n') {
        return -1;
    }
    line[--length] = '\0';
    if (length > 0 && line[length - 1] == '\r') {
        line[length - 1] = '\0';
    }
    return 0;
}

static int load_truth(const char *path, uint32_t frame_count,
                      truth_row_t *rows)
{
    char line[256];
    FILE *stream = fopen(path, "r");
    uint32_t index;

    if (stream == NULL) {
        fprintf(stderr, "cannot open truth: %s\n", path);
        return -1;
    }
    if (fgets(line, sizeof(line), stream) == NULL || trim_line(line) != 0 ||
        strcmp(line, "frame_id,target_q15,class") != 0) {
        fprintf(stderr, "invalid truth header\n");
        fclose(stream);
        return -1;
    }
    for (index = 0; index < frame_count; index++) {
        unsigned frame_id;
        unsigned klass;
        long target;
        int consumed = 0;

        if (fgets(line, sizeof(line), stream) == NULL) {
            fprintf(stderr, "truth row count does not match frames\n");
            fclose(stream);
            return -1;
        }
        if (trim_line(line) != 0 ||
            sscanf(line, "%u,%ld,%u%n", &frame_id, &target, &klass,
                   &consumed) != 3 || line[consumed] != '\0' ||
            frame_id != index || target < INT16_MIN || target > INT16_MAX ||
            klass < TASK3_CLASS_LEFT || klass > TASK3_CLASS_RIGHT) {
            fprintf(stderr, "invalid truth row: %u\n", index);
            fclose(stream);
            return -1;
        }
        rows[index].frame_id = frame_id;
        rows[index].target_q15 = (int16_t)target;
        rows[index].klass = (uint8_t)klass;
    }
    if (ferror(stream)) {
        fprintf(stderr, "cannot read truth: %s\n", path);
        fclose(stream);
        return -1;
    }
    fclose(stream);
    return 0;
}

static int sleep_frame_deadline(const struct timespec *phase_start,
                                uint32_t frame_id, uint32_t fps_numerator,
                                uint32_t fps_denominator)
{
    struct timespec deadline = *phase_start;
    uint64_t offset_ns = (uint64_t)frame_id * fps_denominator *
                         UINT64_C(1000000000) / fps_numerator;
    int result;

    deadline.tv_sec += (time_t)(offset_ns / UINT64_C(1000000000));
    deadline.tv_nsec += (long)(offset_ns % UINT64_C(1000000000));
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    do {
        result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline,
                                 NULL);
    } while (result == EINTR);
    return result == 0 ? 0 : -1;
}

static int send_reset(task3_client_t *client, task3_mode_t mode)
{
    task3_control_t control;
    task3_client_reply_t transaction;

    memset(&control, 0, sizeof(control));
    control.command = TASK3_CMD_RESET;
    control.mode = mode;
    control.klass = TASK3_CLASS_CENTER;
    control.frame_id = 0;
    return task3_client_transact(client, &control, &transaction);
}

static int run_phase(task3_client_t *client, task3_mode_t mode,
                     uint8_t (*pixels)[TASK3_Y4M_FRAME_BYTES],
                     const truth_row_t *truth, uint32_t frame_count,
                     uint32_t fps_numerator, uint32_t fps_denominator,
                     task3_metrics_t *metrics, FILE *csv,
                     int duplicate_frame_once)
{
    struct timespec phase_start;
    uint32_t index;

    if (send_reset(client, mode) != 0 ||
        clock_gettime(CLOCK_MONOTONIC, &phase_start) != 0) {
        return -1;
    }
    for (index = 0; index < frame_count; index++) {
        task3_client_reply_t transaction;
        task3_frame_record_t record;
        task3_control_t control;
        cnn_result_t inference;
        uint64_t inference_start;
        uint64_t inference_end;

        if (sleep_frame_deadline(&phase_start, index, fps_numerator,
                                 fps_denominator) != 0) {
            return -1;
        }
        inference_start = task3_monotonic_raw_ns();
        if (inference_start == 0 ||
            cnn_infer_32x32(pixels[index], &inference) != 0) {
            return -1;
        }
        inference_end = task3_monotonic_raw_ns();
        if (inference_end < inference_start) {
            return -1;
        }
        memset(&control, 0, sizeof(control));
        control.command = TASK3_CMD_STEP;
        control.mode = mode;
        control.klass = (task3_class_t)inference.klass;
        control.confidence_q15 = inference.confidence_q15;
        control.frame_id = truth[index].frame_id;
        if (task3_client_transact(client, &control, &transaction) != 0) {
            return -1;
        }
        if (duplicate_frame_once && mode == TASK3_MODE_AI && index == 0) {
            task3_client_reply_t duplicate;
            int16_t actuator_before = transaction.status.actuator_q15;

            if (task3_client_transact(client, &control, &duplicate) != 0 ||
                (duplicate.status.flags & TASK3_STATUS_FLAG_DUPLICATE) == 0 ||
                duplicate.status.actuator_q15 != actuator_before) {
                return -1;
            }
            printf("TASK3_FAULT_DUPLICATE frame=%u duplicate=1 "
                   "actuator_before=%d actuator_after=%d applied_delta=0\n",
                   control.frame_id, actuator_before,
                   duplicate.status.actuator_q15);
        }
        memset(&record, 0, sizeof(record));
        record.mode = (uint8_t)mode;
        record.frame_id = truth[index].frame_id;
        record.target_q15 = truth[index].target_q15;
        record.truth_class = truth[index].klass;
        record.predicted_class = inference.klass;
        record.confidence_q15 = inference.confidence_q15;
        record.inference_us = inference_end - inference_start >
                                      (uint64_t)UINT32_MAX * UINT64_C(1000)
                                  ? UINT32_MAX
                                  : (uint32_t)((inference_end -
                                                inference_start) /
                                               UINT64_C(1000));
        record.transport_retries = transaction.transport_retries;
        record.rtos_status = (uint8_t)transaction.status.status;
        record.pwm = transaction.status.pwm;
        record.actuator_q15 = transaction.status.actuator_q15;
        record.rtos_processing_us = transaction.status.processing_us;
        record.round_trip_us = transaction.round_trip_us;
        record.error_code = transaction.application_error
                                ? (uint16_t)transaction.error.code
                                : 0;
        record.duplicate =
            (transaction.status.flags & TASK3_STATUS_FLAG_DUPLICATE) != 0;
        record.recovered = transaction.recovered;
        if (task3_metrics_append(metrics, &record) != 0 ||
            task3_metrics_write_record(csv, &record, 1) != 0) {
            return -1;
        }
    }
    return 0;
}

static uint64_t absolute_error(int16_t target, int16_t position)
{
    int32_t difference = (int32_t)position - target;

    return (uint64_t)(difference < 0 ? -difference : difference);
}

static void print_metric_summary(const task3_metric_summary_t *summary)
{
    printf("{\"min\":%" PRIu64 ",\"mean\":%" PRIu64
           ",\"p50\":%" PRIu64 ",\"p95\":%" PRIu64
           ",\"p99\":%" PRIu64 ",\"max\":%" PRIu64 "}",
           summary->minimum, summary->mean, summary->p50, summary->p95,
           summary->p99, summary->maximum);
}

typedef struct {
    uint64_t direction_changes;
    uint64_t successes;
    uint64_t mean_frames;
    uint64_t maximum_frames;
} settling_summary_t;

static int summarize_settling(const task3_frame_record_t *records,
                              uint32_t frame_count,
                              settling_summary_t *summary)
{
    int16_t targets[TASK3_MAX_FRAME_RECORDS / 2];
    int16_t positions[TASK3_MAX_FRAME_RECORDS / 2];
    uint64_t total_frames = 0;
    uint32_t index;

    if (records == NULL || summary == NULL || frame_count == 0 ||
        frame_count > TASK3_MAX_FRAME_RECORDS / 2) {
        return -1;
    }
    memset(summary, 0, sizeof(*summary));
    for (index = 0; index < frame_count; index++) {
        targets[index] = records[index].target_q15;
        positions[index] = records[index].actuator_q15;
    }
    for (index = 1; index < frame_count; index++) {
        uint32_t segment_end;
        size_t settling_frames;

        if (records[index].truth_class == records[index - 1].truth_class) {
            continue;
        }
        summary->direction_changes++;
        segment_end = index + 1;
        while (segment_end < frame_count &&
               records[segment_end].truth_class == records[index].truth_class) {
            segment_end++;
        }
        if (task3_find_settling_frames(
                targets, positions, segment_end, index,
                TASK3_SETTLING_TOLERANCE_Q15, TASK3_SETTLING_CONSECUTIVE,
                &settling_frames) == 0) {
            summary->successes++;
            total_frames += settling_frames;
            if (settling_frames > summary->maximum_frames) {
                summary->maximum_frames = settling_frames;
            }
        }
    }
    if (summary->successes != 0) {
        summary->mean_frames = total_frames / summary->successes;
    }
    return 0;
}

static int emit_summary(const task3_metrics_t *metrics,
                        const task3_client_t *client,
                        uint32_t frames_per_mode, uint64_t elapsed_us)
{
    uint64_t inference[TASK3_MAX_FRAME_RECORDS];
    uint64_t round_trip[TASK3_MAX_FRAME_RECORDS];
    uint64_t fixed_error[TASK3_MAX_FRAME_RECORDS / 2];
    uint64_t ai_error[TASK3_MAX_FRAME_RECORDS / 2];
    uint64_t confusion[3][3] = {{0}};
    task3_metric_summary_t inference_summary;
    task3_metric_summary_t round_trip_summary;
    task3_metric_summary_t fixed_error_summary;
    task3_metric_summary_t ai_error_summary;
    settling_summary_t fixed_settling;
    settling_summary_t ai_settling;
    uint64_t retries = 0;
    uint64_t duplicates = 0;
    uint64_t recovered = 0;
    uint64_t correct = 0;
    uint64_t throughput;
    size_t index;

    if (metrics == NULL || client == NULL || frames_per_mode == 0 ||
        metrics->count != (size_t)frames_per_mode * 2 || elapsed_us == 0) {
        return -1;
    }
    for (index = 0; index < metrics->count; index++) {
        const task3_frame_record_t *record = &metrics->records[index];

        inference[index] = record->inference_us;
        round_trip[index] = record->round_trip_us;
        retries += record->transport_retries;
        duplicates += record->duplicate;
        recovered += record->recovered;
        if (record->mode == TASK3_MODE_FIXED && index < frames_per_mode) {
            fixed_error[index] = absolute_error(record->target_q15,
                                                record->actuator_q15);
        } else if (record->mode == TASK3_MODE_AI &&
                   index >= frames_per_mode &&
                   record->truth_class >= TASK3_CLASS_LEFT &&
                   record->truth_class <= TASK3_CLASS_RIGHT &&
                   record->predicted_class >= TASK3_CLASS_LEFT &&
                   record->predicted_class <= TASK3_CLASS_RIGHT) {
            size_t ai_index = index - frames_per_mode;

            ai_error[ai_index] = absolute_error(record->target_q15,
                                                record->actuator_q15);
            confusion[record->truth_class - 1][record->predicted_class - 1]++;
            correct += record->truth_class == record->predicted_class;
        } else {
            return -1;
        }
    }
    if (task3_metric_summarize(inference, metrics->count,
                               &inference_summary) != 0 ||
        task3_metric_summarize(round_trip, metrics->count,
                               &round_trip_summary) != 0 ||
        task3_metric_summarize(fixed_error, frames_per_mode,
                               &fixed_error_summary) != 0 ||
        task3_metric_summarize(ai_error, frames_per_mode,
                               &ai_error_summary) != 0 ||
        summarize_settling(metrics->records, frames_per_mode,
                           &fixed_settling) != 0 ||
        summarize_settling(metrics->records + frames_per_mode,
                           frames_per_mode, &ai_settling) != 0) {
        return -1;
    }
    throughput = (uint64_t)frames_per_mode * 2 * TASK3_CTRL_WIRE_SIZE *
                 UINT64_C(1000000) / elapsed_us;
    fputs("TASK3_SUMMARY_JSON={\"schema\":1", stdout);
    printf(",\"frames_per_mode\":%u,\"records\":%zu", frames_per_mode,
           metrics->count);
    printf(",\"elapsed_us\":%" PRIu64, elapsed_us);
    printf(",\"requests\":%zu,\"successes\":%zu,\"success_rate\":%.6f,"
           "\"application_errors\":0",
           metrics->count, metrics->count,
           (double)metrics->count / metrics->count);
    printf(",\"application_timeouts\":%" PRIu64
           ",\"transport_retries\":%" PRIu64
           ",\"duplicates\":%" PRIu64 ",\"recovered\":%" PRIu64,
           client->application_timeouts, retries, duplicates, recovered);
    printf(",\"reconnects\":%" PRIu64 ",\"injected_drops\":%" PRIu64,
           client->session.counters.reconnects, client->injected_drops);
    printf(",\"classification\":{\"correct\":%" PRIu64
           ",\"total\":%u,\"accuracy\":%.6f,\"confusion_matrix\":["
           "[%" PRIu64 ",%" PRIu64 ",%" PRIu64 "],"
           "[%" PRIu64 ",%" PRIu64 ",%" PRIu64 "],"
           "[%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]]}",
           correct, frames_per_mode, (double)correct / frames_per_mode,
           confusion[0][0], confusion[0][1], confusion[0][2], confusion[1][0],
           confusion[1][1], confusion[1][2], confusion[2][0], confusion[2][1],
           confusion[2][2]);
    fputs(",\"inference_us\":", stdout);
    print_metric_summary(&inference_summary);
    fputs(",\"round_trip_us\":", stdout);
    print_metric_summary(&round_trip_summary);
    fputs(",\"tracking_error_q15\":{\"fixed\":", stdout);
    print_metric_summary(&fixed_error_summary);
    fputs(",\"ai\":", stdout);
    print_metric_summary(&ai_error_summary);
    printf("},\"settling\":{\"fixed\":{\"direction_changes\":%" PRIu64
           ",\"successes\":%" PRIu64 ",\"mean_frames\":%" PRIu64
           ",\"max_frames\":%" PRIu64 "},\"ai\":{\"direction_changes\":%"
           PRIu64 ",\"successes\":%" PRIu64 ",\"mean_frames\":%" PRIu64
           ",\"max_frames\":%" PRIu64 "}},"
           "\"effective_payload_bytes_per_second\":%" PRIu64 "}\n",
           fixed_settling.direction_changes, fixed_settling.successes,
           fixed_settling.mean_frames, fixed_settling.maximum_frames,
           ai_settling.direction_changes, ai_settling.successes,
           ai_settling.mean_frames, ai_settling.maximum_frames, throughput);
    return fflush(stdout) == 0 ? 0 : -1;
}

int main(int argc, char **argv)
{
    options_t options;
    uint8_t (*pixels)[TASK3_Y4M_FRAME_BYTES] = NULL;
    truth_row_t *truth = NULL;
    task3_client_t client;
    task3_metrics_t metrics;
    FILE *csv = NULL;
    uint32_t fps_numerator = 0;
    uint32_t fps_denominator = 0;
    uint64_t experiment_start = 0;
    uint64_t experiment_end = 0;
    int client_open = 0;
    int result = EXIT_FAILURE;
    int parsed = parse_options(argc, argv, &options);

    if (parsed == 1) {
        return EXIT_SUCCESS;
    }
    if (parsed != 0) {
        fprintf(stderr, "invalid command line\n");
        print_usage(stderr, argv[0]);
        return EXIT_FAILURE;
    }
    if (task3_client_validate_ipv4(options.peer_ipv4) != 0) {
        fprintf(stderr, "invalid peer IPv4 address: %s\n", options.peer_ipv4);
        return EXIT_FAILURE;
    }
    pixels = calloc(options.frames, sizeof(*pixels));
    truth = calloc(options.frames, sizeof(*truth));
    if (pixels == NULL || truth == NULL) {
        fprintf(stderr, "cannot allocate input buffers\n");
        goto cleanup;
    }
    if (load_video(options.video_path, options.frames, pixels, &fps_numerator,
                   &fps_denominator) != 0 ||
        load_truth(options.truth_path, options.frames, truth) != 0) {
        goto cleanup;
    }
    csv = fopen(options.csv_path, "w");
    if (csv == NULL || task3_metrics_write_header(csv) != 0) {
        fprintf(stderr, "cannot create CSV: %s\n", options.csv_path);
        goto cleanup;
    }

    /* All fallible input validation above intentionally precedes socket(). */
    if (task3_client_open(&client, options.peer_ipv4, options.peer_port,
                          options.drop_tx_sequence) != 0) {
        fprintf(stderr, "cannot create UDP client\n");
        goto cleanup;
    }
    client_open = 1;
    if (task3_client_connect(&client, TASK3_CONNECT_TIMEOUT_MS) != 0) {
        fprintf(stderr, "cannot connect RT-IPC session\n");
        goto cleanup;
    }
    if (options.malformed_once) {
        int16_t actuator_before;
        int16_t actuator_after;
        uint32_t rejected;

        if (task3_client_run_malformed_probe(&client, &actuator_before,
                                             &actuator_after, &rejected) != 0 ||
            actuator_before != actuator_after) {
            fprintf(stderr, "malformed packet probe failed\n");
            goto cleanup;
        }
        printf("TASK3_FAULT_MALFORMED schema2=rejected short=rejected "
               "crc=rejected rejected=%u actuator_before=%d "
               "actuator_after=%d applied_delta=0\n",
               rejected, actuator_before, actuator_after);
    }
    task3_metrics_init(&metrics);
    experiment_start = task3_monotonic_raw_ns();
    if (experiment_start == 0 ||
        run_phase(&client, TASK3_MODE_FIXED, pixels, truth, options.frames,
                  fps_numerator, fps_denominator, &metrics, csv, 0) != 0 ||
        run_phase(&client, TASK3_MODE_AI, pixels, truth, options.frames,
                  fps_numerator, fps_denominator, &metrics, csv,
                  options.duplicate_frame_once) != 0) {
        fprintf(stderr, "experiment transaction failed\n");
        goto cleanup;
    }
    if (task3_client_send_stop(&client, TASK3_MODE_AI, options.frames) != 0) {
        fprintf(stderr, "cannot stop RT-Thread service cleanly\n");
        goto cleanup;
    }
    experiment_end = task3_monotonic_raw_ns();
    if (experiment_end <= experiment_start ||
        emit_summary(&metrics, &client, options.frames,
                     (experiment_end - experiment_start) / UINT64_C(1000)) !=
            0) {
        fprintf(stderr, "cannot validate or emit experiment summary\n");
        goto cleanup;
    }
    result = EXIT_SUCCESS;

cleanup:
    if (client_open) {
        task3_client_close(&client);
    }
    if (csv != NULL) {
        fclose(csv);
    }
    free(truth);
    free(pixels);
    return result;
}
