#include <stdio.h>
#include <string.h>

#include "../common/rt_ipc.h"
#include "../rtthread/rtipc_echo_responder.h"
#include "../rtthread/rtipc_server_status.h"

#define CAPTURE_CAPACITY (RTIPC_SEND_WINDOW + 1)

typedef struct {
    uint8_t packets[CAPTURE_CAPACITY][RTIPC_MAX_PACKET];
    size_t lengths[CAPTURE_CAPACITY];
    size_t count;
} capture_t;

typedef struct {
    capture_t capture;
    bool fail_status_once;
} flaky_capture_t;

static int capture_packet(const uint8_t *data, size_t len, void *context)
{
    capture_t *capture = context;
    if (capture->count >= CAPTURE_CAPACITY || len > RTIPC_MAX_PACKET)
        return -1;

    memcpy(capture->packets[capture->count], data, len);
    capture->lengths[capture->count] = len;
    capture->count++;
    return 0;
}

static int flaky_capture_packet(const uint8_t *data, size_t len,
                                void *context)
{
    flaky_capture_t *capture = context;
    rtipc_header_t header;

    if (rtipc_header_parse(data, len, &header) == 0 &&
        header.msg_type == RTIPC_MSG_STATUS_REP &&
        capture->fail_status_once) {
        capture->fail_status_once = false;
        return -1;
    }
    return capture_packet(data, len, &capture->capture);
}

static void receive_command(rtipc_connection_t *connection, uint32_t sequence,
                            const uint8_t *payload, size_t payload_len)
{
    rtipc_header_t header = {0};
    uint8_t packet[RTIPC_MAX_PACKET];

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = RTIPC_MSG_CTRL_CMD;
    header.seq_num = sequence;
    size_t packet_len = rtipc_build_packet(&header, payload, payload_len,
                                           packet, sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 0);
}

static void receive_ack(rtipc_connection_t *connection, uint32_t sequence)
{
    rtipc_header_t header = {0};
    uint8_t packet[RTIPC_HEADER_SIZE];

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = RTIPC_MSG_ACK;
    header.seq_num = sequence;
    size_t packet_len = rtipc_build_packet(&header, NULL, 0, packet,
                                           sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 0);
}

static size_t count_status_packets(const capture_t *capture)
{
    size_t count = 0;

    for (size_t index = 0; index < capture->count; index++) {
        rtipc_header_t header;
        if (rtipc_header_parse(capture->packets[index],
                               capture->lengths[index], &header) == 0 &&
            header.msg_type == RTIPC_MSG_STATUS_REP)
            count++;
    }
    return count;
}

static void capture_status(const char *text, void *context)
{
    char *output = context;
    size_t used = strlen(output);
    size_t available = 128 - used - 1;

    strncat(output, text, available);
}

int main(void)
{
    char failure_output[128] = {0};
    rtipc_server_report_no_network(capture_status, failure_output);
    if (strstr(failure_output,
               "RTIPC_FAILURE reason=no_network_device") == NULL ||
        strstr(failure_output, "ALL TESTS COMPLETE") != NULL) {
        fprintf(stderr, "no-network output falsely reported success: %s\n",
                failure_output);
        return 1;
    }

    rtipc_config_t config;
    rtipc_config_default(&config);

    static rtipc_connection_t connection;
    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;

    static const uint8_t first[] = "first";
    static const uint8_t second[] = "second";
    static capture_t capture;

    receive_command(&connection, 1, second, sizeof(second));
    rtipc_echo_result_t result = rtipc_echo_process_actions(
        &connection, 0, capture_packet, &capture);
    if (result.delivered_messages != 0 || result.send_errors != 0) {
        fprintf(stderr, "unexpected result while buffering sequence 1\n");
        return 1;
    }

    memset(&capture, 0, sizeof(capture));
    receive_command(&connection, 0, first, sizeof(first));
    result = rtipc_echo_process_actions(&connection, 1,
                                        capture_packet, &capture);

    size_t status_count = 0;
    const uint8_t *expected_payloads[] = {first, second};
    const size_t expected_lengths[] = {sizeof(first), sizeof(second)};
    for (size_t i = 0; i < capture.count; i++) {
        rtipc_header_t header;
        if (rtipc_header_parse(capture.packets[i], capture.lengths[i],
                               &header) != 0) {
            fprintf(stderr, "captured malformed packet\n");
            return 1;
        }
        if (header.msg_type != RTIPC_MSG_STATUS_REP)
            continue;

        if (status_count >= 2 ||
            header.payload_len != expected_lengths[status_count] ||
            memcmp(capture.packets[i] + RTIPC_HEADER_SIZE,
                   expected_payloads[status_count],
                   expected_lengths[status_count]) != 0) {
            fprintf(stderr, "STATUS_REP payload order mismatch\n");
            return 1;
        }
        status_count++;
    }

    if (result.delivered_messages != 2 || result.response_errors != 0 ||
        result.send_errors != 0 || status_count != 2) {
        fprintf(stderr,
                "expected two replies, delivered=%u status=%zu response_errors=%u send_errors=%u\n",
                result.delivered_messages, status_count,
                result.response_errors, result.send_errors);
        return 1;
    }

    static rtipc_connection_t full_window_connection;
    rtipc_connection_init(&full_window_connection, &config);
    full_window_connection.state = RTIPC_STATE_CONNECTED;

    for (uint32_t sequence = 1; sequence < RTIPC_SEND_WINDOW; sequence++) {
        uint8_t payload[4] = {
            (uint8_t)(sequence >> 24), (uint8_t)(sequence >> 16),
            (uint8_t)(sequence >> 8), (uint8_t)sequence
        };
        receive_command(&full_window_connection, sequence, payload,
                        sizeof(payload));
        memset(&capture, 0, sizeof(capture));
        result = rtipc_echo_process_actions(&full_window_connection, 0,
                                             capture_packet, &capture);
        if (result.delivered_messages != 0 || result.response_errors != 0 ||
            result.send_errors != 0) {
            fprintf(stderr, "unexpected result while filling reorder window\n");
            return 1;
        }
    }

    static const uint8_t zero_payload[4] = {0, 0, 0, 0};
    memset(&capture, 0, sizeof(capture));
    receive_command(&full_window_connection, 0, zero_payload,
                    sizeof(zero_payload));
    result = rtipc_echo_process_actions(&full_window_connection, 1,
                                         capture_packet, &capture);

    size_t full_status_count = 0;
    size_t ack_count = 0;
    for (size_t i = 0; i < capture.count; i++) {
        rtipc_header_t header;
        if (rtipc_header_parse(capture.packets[i], capture.lengths[i],
                               &header) != 0) {
            fprintf(stderr, "captured malformed full-window packet\n");
            return 1;
        }
        if (header.msg_type == RTIPC_MSG_ACK) {
            if (header.seq_num != RTIPC_SEND_WINDOW - 1) {
                fprintf(stderr, "full-window ACK sequence mismatch\n");
                return 1;
            }
            ack_count++;
            continue;
        }
        if (header.msg_type != RTIPC_MSG_STATUS_REP)
            continue;

        uint32_t sequence = (uint32_t)full_status_count;
        uint8_t expected[4] = {
            (uint8_t)(sequence >> 24), (uint8_t)(sequence >> 16),
            (uint8_t)(sequence >> 8), (uint8_t)sequence
        };
        if (header.payload_len != sizeof(expected) ||
            memcmp(capture.packets[i] + RTIPC_HEADER_SIZE, expected,
                   sizeof(expected)) != 0) {
            fprintf(stderr, "full-window STATUS_REP payload mismatch\n");
            return 1;
        }
        full_status_count++;
    }

    if (result.delivered_messages != RTIPC_SEND_WINDOW ||
        result.response_errors != 0 || result.send_errors != 0 ||
        full_status_count != RTIPC_SEND_WINDOW || ack_count != 1) {
        fprintf(stderr,
                "expected 64 replies, delivered=%u status=%zu ack=%zu response_errors=%u send_errors=%u\n",
                result.delivered_messages, full_status_count, ack_count,
                result.response_errors, result.send_errors);
        return 1;
    }

    static rtipc_connection_t backpressured_connection;
    rtipc_connection_init(&backpressured_connection, &config);
    backpressured_connection.state = RTIPC_STATE_CONNECTED;
    static const uint8_t occupied[] = "occupied";
    for (uint32_t sequence = 0; sequence < RTIPC_SEND_WINDOW; sequence++) {
        if (rtipc_connection_send(&backpressured_connection,
                                  RTIPC_MSG_STATUS_REP, occupied,
                                  sizeof(occupied), 0) != 0) {
            fprintf(stderr, "failed to fill response window\n");
            return 1;
        }
        rtipc_action_clear(&backpressured_connection);
    }

    static const uint8_t deferred_payload[] = "deferred-response";
    memset(&capture, 0, sizeof(capture));
    receive_command(&backpressured_connection, 0, deferred_payload,
                    sizeof(deferred_payload));
    result = rtipc_echo_process_actions(&backpressured_connection, 1,
                                        capture_packet, &capture);
    if (result.response_errors != 0 ||
        backpressured_connection.action_count == 0) {
        fprintf(stderr,
                "full response window discarded request: errors=%u queued=%u\n",
                result.response_errors,
                backpressured_connection.action_count);
        return 1;
    }

    receive_ack(&backpressured_connection, 0);
    memset(&capture, 0, sizeof(capture));
    result = rtipc_echo_process_actions(&backpressured_connection, 2,
                                        capture_packet, &capture);
    if (result.delivered_messages != 1 || result.response_errors != 0 ||
        count_status_packets(&capture) != 1) {
        fprintf(stderr,
                "deferred request was not answered: delivered=%u errors=%u status=%zu\n",
                result.delivered_messages, result.response_errors,
                count_status_packets(&capture));
        return 1;
    }

    static rtipc_connection_t send_retry_connection;
    flaky_capture_t flaky_capture = {0};
    rtipc_connection_init(&send_retry_connection, &config);
    send_retry_connection.state = RTIPC_STATE_CONNECTED;
    receive_command(&send_retry_connection, 0, deferred_payload,
                    sizeof(deferred_payload));
    flaky_capture.fail_status_once = true;
    result = rtipc_echo_process_actions(&send_retry_connection, 1,
                                        flaky_capture_packet, &flaky_capture);
    if (result.send_errors != 1 || result.delivered_messages != 1) {
        fprintf(stderr,
                "expected one transient response send failure: errors=%u delivered=%u\n",
                result.send_errors, result.delivered_messages);
        return 1;
    }
    memset(&flaky_capture.capture, 0, sizeof(flaky_capture.capture));
    result = rtipc_echo_process_actions(&send_retry_connection, 2,
                                        flaky_capture_packet, &flaky_capture);
    if (result.send_errors != 0 || result.delivered_messages != 0 ||
        count_status_packets(&flaky_capture.capture) != 1) {
        fprintf(stderr,
                "transient response send failure was not retried: errors=%u delivered=%u status=%zu\n",
                result.send_errors, result.delivered_messages,
                count_status_packets(&flaky_capture.capture));
        return 1;
    }

    puts("PASS: reordered commands and full window produce one response per delivery");
    return 0;
}
