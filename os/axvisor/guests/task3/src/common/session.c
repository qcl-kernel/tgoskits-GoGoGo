#include "session.h"

#include "task3_protocol.h"

#include <string.h>

typedef struct {
    bool connected;
    bool disconnected;
    bool delivered;
    uint8_t message_type;
    size_t payload_length;
    uint8_t payload[RTIPC_MAX_PAYLOAD];
} pump_result_t;

static uint64_t retry_count(const rtipc_connection_t *connection)
{
    uint64_t count = 0;
    int index;

    for (index = 0; index < RTIPC_SEND_WINDOW; index++) {
        if (connection->pending[index].in_use) {
            count += connection->pending[index].retries;
        }
    }
    return count;
}

static bool is_valid_syn(const uint8_t *bytes, size_t length)
{
    rtipc_header_t header;

    if (length != RTIPC_HEADER_SIZE ||
        rtipc_header_parse(bytes, length, &header) != 0) {
        return false;
    }
    return header.version == RTIPC_PROTOCOL_VERSION &&
           header.msg_type == RTIPC_MSG_SYN && header.payload_len == 0 &&
           rtipc_verify_packet(&header, bytes + RTIPC_HEADER_SIZE, 0);
}

static bool is_valid_datagram(const uint8_t *bytes, size_t length)
{
    rtipc_header_t header;

    if (length < RTIPC_HEADER_SIZE ||
        rtipc_header_parse(bytes, length, &header) != 0 ||
        header.version != RTIPC_PROTOCOL_VERSION ||
        header.payload_len > RTIPC_MAX_PAYLOAD ||
        length != RTIPC_HEADER_SIZE + (size_t)header.payload_len) {
        return false;
    }
    return rtipc_verify_packet(&header, bytes + RTIPC_HEADER_SIZE,
                               header.payload_len);
}

static bool is_data_message(uint8_t message_type)
{
    return message_type == RTIPC_MSG_CTRL_CMD ||
           message_type == RTIPC_MSG_STATUS_REP ||
           message_type == RTIPC_MSG_ERROR_NOTIFY;
}

static int pump_actions(task3_session_t *session, uint64_t now_ms,
                        uint64_t retries_before)
{
    const rtipc_action_t *action;
    pump_result_t result = {0};
    uint64_t retries_after;
    int status = 0;

    while ((action = rtipc_action_next(&session->connection)) != NULL) {
        switch (action->type) {
        case RTIPC_ACTION_SEND:
            session->counters.datagrams_sent++;
            if (session->send_datagram(session->callback_context, action->data,
                                       action->data_len) != 0) {
                session->counters.send_errors++;
                status = -1;
            }
            break;
        case RTIPC_ACTION_CONNECTED:
            result.connected = true;
            break;
        case RTIPC_ACTION_DISCONNECTED:
            result.disconnected = true;
            break;
        case RTIPC_ACTION_DELIVER:
            if (result.delivered || action->payload_len > sizeof(result.payload)) {
                session->counters.delivery_errors++;
                status = -1;
                break;
            }
            memcpy(result.payload, action->payload, action->payload_len);
            result.payload_length = action->payload_len;
            result.message_type = action->msg_type;
            result.delivered = true;
            break;
        default:
            break;
        }
    }
    retries_after = retry_count(&session->connection);
    if (retries_after > retries_before) {
        session->counters.transport_retries += retries_after - retries_before;
    }
    rtipc_action_clear(&session->connection);

    if (result.disconnected) {
        session->counters.disconnects++;
    }
    if (result.connected) {
        session->counters.connects++;
        if (session->connected_once) {
            session->counters.reconnects++;
        }
        session->connected_once = true;
    }
    if (result.delivered) {
        if (result.message_type == RTIPC_MSG_STATUS_REP && session->outstanding) {
            task3_status_t reply;
            if (task3_decode_status(result.payload, result.payload_length, &reply) ==
                    TASK3_APP_OK &&
                reply.frame_id == session->outstanding_frame_id) {
                session->outstanding = false;
                session->outstanding_length = 0;
            }
        }
        if (session->deliver_message(session->callback_context, result.message_type,
                                     result.payload, result.payload_length,
                                     now_ms) != 0) {
            session->counters.delivery_errors++;
            status = -1;
        }
    }
    if (result.connected && session->role == TASK3_SESSION_CLIENT &&
        session->outstanding) {
        if (task3_session_send(session, RTIPC_MSG_CTRL_CMD,
                               session->outstanding_control,
                               session->outstanding_length, now_ms) != 0) {
            status = -1;
        }
    }
    return status;
}

void task3_session_init(task3_session_t *session, task3_session_role_t role,
                        task3_session_send_fn send_datagram,
                        task3_session_deliver_fn deliver_message,
                        void *callback_context)
{
    rtipc_config_t configuration;

    memset(session, 0, sizeof(*session));
    rtipc_config_default(&configuration);
    configuration.rto_ms = 50;
    configuration.max_retries = 5;
    configuration.heartbeat_interval_ms = 1000;
    configuration.heartbeat_timeout_ms = 5000;
    configuration.connect_timeout_ms = 500;
    configuration.auto_reconnect = true;
    session->role = role;
    session->send_datagram = send_datagram;
    session->deliver_message = deliver_message;
    session->callback_context = callback_context;
    rtipc_connection_init(&session->connection, &configuration);
}

int task3_session_connect(task3_session_t *session, uint64_t now_ms)
{
    if (session == NULL || session->role != TASK3_SESSION_CLIENT ||
        session->send_datagram == NULL || session->deliver_message == NULL) {
        return -1;
    }
    rtipc_connection_connect(&session->connection, now_ms);
    return pump_actions(session, now_ms, retry_count(&session->connection));
}

int task3_session_on_datagram(task3_session_t *session, const uint8_t *bytes,
                              size_t length, uint64_t now_ms)
{
    uint64_t retries_before;

    if (session == NULL || bytes == NULL || length == 0 ||
        session->send_datagram == NULL || session->deliver_message == NULL) {
        return -1;
    }
    if (!is_valid_datagram(bytes, length)) {
        return -1;
    }
    {
        rtipc_header_t header;

        if (rtipc_header_parse(bytes, length, &header) != 0) {
            return -1;
        }
        if (is_data_message(header.msg_type) &&
            (int32_t)(header.seq_num - session->connection.expected_seq) > 0) {
            return 0;
        }
    }
    if (session->role == TASK3_SESSION_SERVER &&
        rtipc_connection_is_connected(&session->connection) &&
        is_valid_syn(bytes, length)) {
        rtipc_connection_reset(&session->connection);
    }
    retries_before = retry_count(&session->connection);
    rtipc_connection_on_recv(&session->connection, bytes, length, now_ms);
    return pump_actions(session, now_ms, retries_before);
}

int task3_session_tick(task3_session_t *session, uint64_t now_ms)
{
    uint64_t retries_before;

    if (session == NULL || session->send_datagram == NULL ||
        session->deliver_message == NULL) {
        return -1;
    }
    retries_before = retry_count(&session->connection);
    rtipc_connection_tick(&session->connection, now_ms);
    return pump_actions(session, now_ms, retries_before);
}

int task3_session_send(task3_session_t *session, rtipc_msg_type_t message_type,
                       const uint8_t *payload, size_t length, uint64_t now_ms)
{
    int result;

    if (session == NULL || (payload == NULL && length != 0) ||
        session->send_datagram == NULL || session->deliver_message == NULL) {
        return -1;
    }
    result = rtipc_connection_send(&session->connection, message_type, payload,
                                   length, now_ms);
    if (result != 0) {
        return result;
    }
    return pump_actions(session, now_ms, retry_count(&session->connection));
}

int task3_session_submit_control(task3_session_t *session, const uint8_t *payload,
                                 size_t length, uint32_t frame_id,
                                 uint64_t now_ms)
{
    if (session == NULL || session->role != TASK3_SESSION_CLIENT ||
        payload == NULL || length == 0 || length > RTIPC_MAX_PAYLOAD ||
        session->outstanding) {
        return -1;
    }
    memcpy(session->outstanding_control, payload, length);
    session->outstanding_length = length;
    session->outstanding_frame_id = frame_id;
    session->outstanding = true;
    if (task3_session_send(session, RTIPC_MSG_CTRL_CMD, payload, length, now_ms) !=
        0) {
        session->outstanding = false;
        session->outstanding_length = 0;
        return -1;
    }
    return 0;
}

void task3_session_force_disconnect(task3_session_t *session, uint64_t now_ms)
{
    if (session != NULL) {
        rtipc_connection_force_disconnect(&session->connection, now_ms);
        (void)pump_actions(session, now_ms, retry_count(&session->connection));
    }
}

bool task3_session_is_connected(const task3_session_t *session)
{
    return session != NULL && rtipc_connection_is_connected(&session->connection);
}

bool task3_session_has_outstanding(const task3_session_t *session)
{
    return session != NULL && session->outstanding;
}
