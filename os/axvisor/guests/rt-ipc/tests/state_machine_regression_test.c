#include <stdio.h>
#include <string.h>

#include "../common/rt_ipc.h"

static size_t build_control_packet_for_session(uint8_t msg_type,
                                               uint32_t sequence,
                                               uint64_t session_id,
                                               uint8_t *packet,
                                               size_t packet_size)
{
    rtipc_header_t header = {0};

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = msg_type;
    header.seq_num = sequence;
    header.session_id = session_id;
    return rtipc_build_packet(&header, NULL, 0, packet, packet_size);
}

static size_t build_control_packet(uint8_t msg_type, uint32_t sequence,
                                   uint8_t *packet, size_t packet_size)
{
    return build_control_packet_for_session(msg_type, sequence, 0, packet,
                                            packet_size);
}

static size_t build_data_packet(uint32_t sequence, uint8_t *packet,
                                size_t packet_size)
{
    static const uint8_t payload[] = "stale";
    rtipc_header_t header = {0};

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = RTIPC_MSG_CTRL_CMD;
    header.seq_num = sequence;
    return rtipc_build_packet(&header, payload, sizeof(payload), packet,
                              packet_size);
}

static void initialize_session(rtipc_connection_t *connection,
                               uint32_t session_sequence)
{
    rtipc_config_t config;

    rtipc_config_default(&config);
    rtipc_connection_init(connection, &config);
    connection->state = RTIPC_STATE_CONNECTED;
    connection->session_seq = session_sequence;
    connection->session_seq_valid = true;
    connection->send_seq = session_sequence;
    connection->expected_seq = session_sequence;
    connection->control_seq = session_sequence + 1;
    connection->next_session_seq = session_sequence + 1;
    connection->last_hb_sent_ms = 11;
    connection->last_hb_recv_ms = 12;
}

static int stale_data_has_no_session_side_effects(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_MAX_PACKET];

    initialize_session(&connection, 100);
    rtipc_stats_t before = connection.stats;
    size_t packet_len = build_data_packet(99, packet, sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 50);

    if (connection.state != RTIPC_STATE_CONNECTED ||
        connection.last_hb_recv_ms != 12 || connection.expected_seq != 100 ||
        connection.action_count != 0 ||
        memcmp(&connection.stats, &before, sizeof(before)) != 0) {
        fprintf(stderr,
                "stale data changed state=%d liveness=%llu expected=%u actions=%u\n",
                connection.state,
                (unsigned long long)connection.last_hb_recv_ms,
                connection.expected_seq, connection.action_count);
        return -1;
    }
    return 0;
}

static int stale_heartbeat_has_no_session_side_effects(void)
{
    static const uint8_t message_types[] = {
        RTIPC_MSG_HEARTBEAT,
        RTIPC_MSG_HEARTBEAT_ACK,
    };

    for (size_t index = 0; index < sizeof(message_types); index++) {
        rtipc_connection_t connection;
        uint8_t packet[RTIPC_HEADER_SIZE];

        initialize_session(&connection, 100);
        rtipc_stats_t before = connection.stats;
        size_t packet_len = build_control_packet(message_types[index], 99,
                                                 packet, sizeof(packet));
        rtipc_connection_on_recv(&connection, packet, packet_len, 50);
        if (connection.state != RTIPC_STATE_CONNECTED ||
            connection.last_hb_recv_ms != 12 || connection.action_count != 0 ||
            memcmp(&connection.stats, &before, sizeof(before)) != 0) {
            fprintf(stderr,
                    "stale heartbeat type=%u changed state=%d liveness=%llu actions=%u\n",
                    message_types[index], connection.state,
                    (unsigned long long)connection.last_hb_recv_ms,
                    connection.action_count);
            return -1;
        }
    }
    return 0;
}

static int stale_fin_and_ack_have_no_session_side_effects(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];

    initialize_session(&connection, 100);
    size_t packet_len = build_control_packet(RTIPC_MSG_FIN, 99, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 50);
    if (connection.state != RTIPC_STATE_CONNECTED ||
        connection.last_hb_recv_ms != 12 || connection.action_count != 0) {
        fprintf(stderr,
                "stale FIN changed state=%d liveness=%llu actions=%u\n",
                connection.state,
                (unsigned long long)connection.last_hb_recv_ms,
                connection.action_count);
        return -1;
    }

    initialize_session(&connection, 100);
    static const uint8_t payload[] = "current";
    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 0) != RTIPC_SEND_OK)
        return -1;
    rtipc_action_clear(&connection);
    rtipc_stats_t before = connection.stats;
    packet_len = build_control_packet(RTIPC_MSG_ACK, 99, packet,
                                      sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 50);
    if (connection.pending_count != 1 || connection.action_count != 0 ||
        memcmp(&connection.stats, &before, sizeof(before)) != 0) {
        fprintf(stderr,
                "stale ACK changed pending=%u ack_stats=%u actions=%u\n",
                connection.pending_count, connection.stats.acks_received,
                connection.action_count);
        return -1;
    }
    return 0;
}

static int reconnect(rtipc_connection_t *connection, uint64_t now_ms)
{
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t syn_header;

    rtipc_connection_force_disconnect(connection, now_ms);
    rtipc_action_clear(connection);
    rtipc_connection_connect(connection, now_ms + 1);
    if (connection->state != RTIPC_STATE_SYN_SENT)
        return -1;

    const rtipc_action_t *action = rtipc_action_next(connection);
    if (action == NULL || action->type != RTIPC_ACTION_SEND ||
        rtipc_header_parse(action->data, action->data_len, &syn_header) != 0 ||
        syn_header.msg_type != RTIPC_MSG_SYN)
        return -1;

    size_t packet_len = build_control_packet_for_session(
        RTIPC_MSG_SYNACK, syn_header.seq_num, syn_header.session_id, packet,
        sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, now_ms + 2);
    rtipc_action_clear(connection);
    return connection->state == RTIPC_STATE_CONNECTED ? 0 : -1;
}

static int stale_ack_does_not_release_new_session_packet(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t old_ack[RTIPC_HEADER_SIZE];
    static const uint8_t old_payload[] = "old";
    static const uint8_t new_payload[] = "new";

    rtipc_config_default(&config);
    rtipc_connection_init(&connection, &config);
    if (reconnect(&connection, 0) != 0)
        return -1;

    for (unsigned packet = 0; packet < 2; packet++) {
        if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, old_payload,
                                  sizeof(old_payload), packet) != 0)
            return -1;
    }
    uint32_t old_sequence = connection.send_seq - 1;
    size_t old_ack_len = build_control_packet(RTIPC_MSG_ACK, old_sequence,
                                              old_ack, sizeof(old_ack));
    rtipc_action_clear(&connection);

    if (reconnect(&connection, 10) != 0)
        return -1;
    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, new_payload,
                              sizeof(new_payload), 20) != 0)
        return -1;

    uint32_t new_sequence = connection.send_seq - 1;
    rtipc_connection_on_recv(&connection, old_ack, old_ack_len, 21);

    if (new_sequence == old_sequence) {
        fprintf(stderr, "data sequence was reused across sessions: %u\n",
                new_sequence);
        return -1;
    }
    if (connection.pending_count != 1) {
        fprintf(stderr, "stale ACK released the new-session packet\n");
        return -1;
    }
    return 0;
}

static int session_reset_discards_stale_send_actions(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    static const uint8_t payload[] = "stale-send";

    rtipc_config_default(&config);
    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;

    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 0) != 0)
        return -1;
    rtipc_connection_force_disconnect(&connection, 1);

    unsigned send_actions = 0;
    unsigned disconnected_actions = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            send_actions++;
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected_actions++;
    }
    rtipc_action_clear(&connection);

    if (send_actions != 0 || disconnected_actions != 1) {
        fprintf(stderr,
                "session reset kept stale actions: send=%u disconnected=%u\n",
                send_actions, disconnected_actions);
        return -1;
    }
    return 0;
}

static void fill_action_queue(rtipc_connection_t *connection)
{
    connection->action_idx = 0;
    connection->action_count = RTIPC_ACTION_QUEUE_CAPACITY;
    for (uint32_t index = 0; index < RTIPC_ACTION_QUEUE_CAPACITY; index++)
        connection->actions[index].type = RTIPC_ACTION_CONNECTED;
}

static void fill_all_action_capacity(rtipc_connection_t *connection)
{
    fill_action_queue(connection);
    connection->deferred_lifecycle_count =
        RTIPC_LIFECYCLE_ACTION_CAPACITY;
    for (uint32_t index = 0;
         index < RTIPC_LIFECYCLE_ACTION_CAPACITY; index++)
        connection->deferred_lifecycle[index].type =
            RTIPC_ACTION_DISCONNECTED;
}

static unsigned drain_action_type(rtipc_connection_t *connection,
                                  rtipc_action_type_t type);

static int full_queue_heartbeat_ack_has_no_side_effects(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];
    const uint32_t session_sequence = 0x80000100U;

    initialize_session(&connection, session_sequence);
    connection.next_session_seq = session_sequence + 1;
    rtipc_stats_t before = connection.stats;
    fill_action_queue(&connection);
    size_t packet_len = build_control_packet(RTIPC_MSG_HEARTBEAT,
                                             session_sequence + 1, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 50);

    if (connection.last_hb_recv_ms != 12 ||
        connection.next_session_seq != session_sequence + 1 ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        memcmp(&connection.stats, &before, sizeof(before)) != 0) {
        fprintf(stderr,
                "failed heartbeat ACK admission changed liveness=%llu floor=%u actions=%u\n",
                (unsigned long long)connection.last_hb_recv_ms,
                connection.next_session_seq, connection.action_count);
        return -1;
    }
    return 0;
}

static int full_queue_data_ack_has_no_side_effects(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_MAX_PACKET];
    const uint32_t session_sequence = 0x80000100U;

    initialize_session(&connection, session_sequence);
    connection.next_session_seq = connection.expected_seq;
    rtipc_stats_t before = connection.stats;
    uint32_t expected_sequence = connection.expected_seq;
    fill_action_queue(&connection);
    size_t packet_len = build_data_packet(expected_sequence, packet,
                                          sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 50);

    if (connection.last_hb_recv_ms != 12 ||
        connection.expected_seq != expected_sequence ||
        connection.reorder_count != 0 ||
        connection.next_session_seq != expected_sequence ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        memcmp(&connection.stats, &before, sizeof(before)) != 0) {
        fprintf(stderr,
                "failed data ACK admission changed live=%llu expected=%u reorder=%u floor=%u rx=%u actions=%u\n",
                (unsigned long long)connection.last_hb_recv_ms,
                connection.expected_seq, connection.reorder_count,
                connection.next_session_seq, connection.stats.rx_packets,
                connection.action_count);
        return -1;
    }
    return 0;
}

static int full_action_queue_does_not_advance_protocol_state(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    rtipc_config_default(&config);
    rtipc_connection_init(&connection, &config);
    uint32_t control_sequence = connection.control_seq;
    fill_action_queue(&connection);

    rtipc_connection_connect(&connection, 123);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.control_seq != control_sequence ||
        connection.connect_attempt_ms != 0 || connection.session_seq_valid) {
        fprintf(stderr,
                "failed SYN enqueue advanced state=%d control=%u timer=%llu session=%d\n",
                connection.state, connection.control_seq,
                (unsigned long long)connection.connect_attempt_ms,
                connection.session_seq_valid);
        return -1;
    }

    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;
    static const uint8_t payload[] = "retry";
    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 0) != 0)
        return -1;
    rtipc_action_clear(&connection);
    fill_action_queue(&connection);

    rtipc_connection_tick(&connection, config.rto_ms);
    if (connection.pending[0].retries != 0 ||
        connection.pending[0].sent_at_ms != 0 ||
        connection.stats.retransmissions != 0) {
        fprintf(stderr,
                "failed retransmit enqueue consumed retry=%u sent_at=%llu retrans=%u\n",
                connection.pending[0].retries,
                (unsigned long long)connection.pending[0].sent_at_ms,
                connection.stats.retransmissions);
        return -1;
    }
    return 0;
}

static int full_queue_syn_does_not_commit_server_session(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];

    rtipc_config_default(&config);
    rtipc_connection_init(&connection, &config);
    uint32_t control_sequence = connection.control_seq;
    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, 100, packet,
                                             sizeof(packet));
    fill_action_queue(&connection);
    rtipc_connection_on_recv(&connection, packet, packet_len, 10);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.session_seq_valid || connection.peer_syn_seq_valid ||
        connection.control_seq != control_sequence ||
        connection.last_hb_recv_ms != 0 || connection.last_hb_sent_ms != 0) {
        fprintf(stderr,
                "full-queue SYN committed state=%d session=%d peer=%d control=%u recv=%llu\n",
                connection.state, connection.session_seq_valid,
                connection.peer_syn_seq_valid, connection.control_seq,
                (unsigned long long)connection.last_hb_recv_ms);
        return -1;
    }

    rtipc_action_clear(&connection);
    rtipc_connection_on_recv(&connection, packet, packet_len, 20);
    const rtipc_action_t *action = rtipc_action_next(&connection);
    rtipc_header_t header;
    if (action == NULL || action->type != RTIPC_ACTION_SEND ||
        rtipc_header_parse(action->data, action->data_len, &header) != 0 ||
        header.msg_type != RTIPC_MSG_SYNACK || header.seq_num < 100 ||
        connection.state != RTIPC_STATE_CONNECTED ||
        !connection.session_seq_valid || !connection.peer_syn_seq_valid ||
        connection.last_hb_recv_ms != 20) {
        fprintf(stderr,
                "retried SYN did not queue SYNACK before commit: state=%d actions=%u\n",
                connection.state, connection.action_count);
        return -1;
    }
    return 0;
}

static int full_queue_lifecycle_actions_are_eventually_visible(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    rtipc_config_default(&config);
    config.auto_reconnect = true;
    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;
    fill_action_queue(&connection);
    rtipc_connection_force_disconnect(&connection, 10);

    unsigned disconnected = 0;
    unsigned reconnect_actions = 0;
    uint64_t reconnect_delay = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected++;
        if (action->type == RTIPC_ACTION_RECONNECT) {
            reconnect_actions++;
            reconnect_delay = action->delay_ms;
        }
    }
    if (disconnected != 1 || reconnect_actions != 1 || reconnect_delay == 0) {
        fprintf(stderr,
                "full queue lost lifecycle actions: disconnected=%u reconnect=%u delay=%llu\n",
                disconnected, reconnect_actions,
                (unsigned long long)reconnect_delay);
        return -1;
    }

    rtipc_connection_init(&connection, &config);
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_connection_connect(&connection, 1);
    rtipc_action_clear(&connection);
    fill_action_queue(&connection);
    for (uint32_t index = 0; index < RTIPC_ACTION_QUEUE_CAPACITY; index++)
        connection.actions[index].type = RTIPC_ACTION_NONE;
    size_t packet_len = build_control_packet(RTIPC_MSG_SYNACK,
                                      connection.control_pending.seq, packet,
                                      sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 2);
    unsigned connected = drain_action_type(&connection,
                                           RTIPC_ACTION_CONNECTED);
    if (connection.state != RTIPC_STATE_CONNECTED || connected != 1) {
        fprintf(stderr,
                "full queue lost CONNECTED action: state=%d connected=%u\n",
                connection.state, connected);
        return -1;
    }

    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;
    fill_action_queue(&connection);
    rtipc_connection_force_disconnect(&connection, 10);
    rtipc_action_clear(&connection);
    if (rtipc_action_next(&connection) != NULL) {
        fprintf(stderr, "action_clear retained deferred lifecycle event\n");
        return -1;
    }
    return 0;
}

static int saturated_lifecycle_capacity_blocks_state_transitions(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];

    rtipc_config_default(&config);

    rtipc_connection_init(&connection, &config);
    uint32_t initial_control_sequence = connection.control_seq;
    fill_all_action_capacity(&connection);
    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, 100, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 1);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.session_seq_valid || connection.peer_syn_seq_valid ||
        connection.control_seq != initial_control_sequence ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        connection.deferred_lifecycle_count !=
            RTIPC_LIFECYCLE_ACTION_CAPACITY) {
        fprintf(stderr,
                "saturated SYN committed state=%d session=%d peer=%d main=%u deferred=%u\n",
                connection.state, connection.session_seq_valid,
                connection.peer_syn_seq_valid, connection.action_count,
                connection.deferred_lifecycle_count);
        return -1;
    }

    rtipc_connection_init(&connection, &config);
    rtipc_connection_connect(&connection, 0);
    rtipc_action_clear(&connection);
    uint32_t syn_sequence = connection.control_pending.seq;
    fill_all_action_capacity(&connection);
    packet_len = build_control_packet(RTIPC_MSG_SYNACK, syn_sequence, packet,
                                      sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 1);
    if (connection.state != RTIPC_STATE_SYN_SENT ||
        !connection.control_pending.active ||
        connection.control_pending.msg_type != RTIPC_MSG_SYN ||
        connection.control_pending.seq != syn_sequence ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        connection.deferred_lifecycle_count !=
            RTIPC_LIFECYCLE_ACTION_CAPACITY) {
        fprintf(stderr,
                "saturated SYNACK committed state=%d pending=%d main=%u deferred=%u\n",
                connection.state, connection.control_pending.active,
                connection.action_count,
                connection.deferred_lifecycle_count);
        return -1;
    }

    rtipc_connection_init(&connection, &config);
    connection.config.connect_timeout_ms = 10;
    connection.config.rto_ms = 100;
    rtipc_connection_connect(&connection, 0);
    rtipc_action_clear(&connection);
    fill_all_action_capacity(&connection);
    rtipc_connection_tick(&connection, 10);
    if (connection.state != RTIPC_STATE_SYN_SENT ||
        !connection.control_pending.active || connection.stats.timeouts != 0 ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        connection.deferred_lifecycle_count !=
            RTIPC_LIFECYCLE_ACTION_CAPACITY) {
        fprintf(stderr,
                "saturated timeout committed state=%d pending=%d timeouts=%u main=%u deferred=%u\n",
                connection.state, connection.control_pending.active,
                connection.stats.timeouts, connection.action_count,
                connection.deferred_lifecycle_count);
        return -1;
    }

    initialize_session(&connection, 100);
    fill_all_action_capacity(&connection);
    packet_len = build_control_packet(RTIPC_MSG_FIN, 101, packet,
                                      sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 1);
    if (connection.state != RTIPC_STATE_CONNECTED ||
        connection.peer_fin_seq_valid ||
        connection.action_count != RTIPC_ACTION_QUEUE_CAPACITY ||
        connection.deferred_lifecycle_count !=
            RTIPC_LIFECYCLE_ACTION_CAPACITY) {
        fprintf(stderr,
                "saturated FIN committed state=%d peer_fin=%d main=%u deferred=%u\n",
                connection.state, connection.peer_fin_seq_valid,
                connection.action_count,
                connection.deferred_lifecycle_count);
        return -1;
    }
    return 0;
}

static int new_syn_reports_disconnected_old_session(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];

    initialize_session(&connection, 100);
    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, 200, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 10);

    unsigned sends = 0;
    unsigned disconnected = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            sends++;
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected++;
    }
    if (connection.state != RTIPC_STATE_CONNECTED || sends != 1 ||
        disconnected != 1) {
        fprintf(stderr,
                "new SYN lifecycle state=%d sends=%u disconnected=%u\n",
                connection.state, sends, disconnected);
        return -1;
    }
    return 0;
}

static void configure_heartbeat(rtipc_connection_t *connection,
                                bool auto_reconnect)
{
    connection->config.heartbeat_interval_ms = 10;
    connection->config.heartbeat_timeout_ms = UINT64_MAX;
    connection->config.auto_reconnect = auto_reconnect;
    connection->last_hb_sent_ms = 0;
    connection->last_hb_recv_ms = 0;
    connection->control_seq = connection->session_seq + 1;
    connection->next_session_seq = connection->control_seq;
}

static int queued_heartbeat_is_dropped_on_force_disconnect(void)
{
    rtipc_connection_t connection;

    initialize_session(&connection, 0x80000100U);
    configure_heartbeat(&connection, false);
    rtipc_connection_tick(&connection, 10);
    rtipc_connection_force_disconnect(&connection, 11);

    unsigned sends = 0;
    unsigned disconnected = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            sends++;
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected++;
    }
    if (connection.state != RTIPC_STATE_CLOSED || sends != 0 ||
        disconnected != 1) {
        fprintf(stderr,
                "force disconnect leaked old control: state=%d sends=%u disconnected=%u\n",
                connection.state, sends, disconnected);
        return -1;
    }
    return 0;
}

static int queued_heartbeat_is_dropped_on_reconnect(void)
{
    rtipc_connection_t connection;

    initialize_session(&connection, 0x80000100U);
    configure_heartbeat(&connection, true);
    rtipc_connection_tick(&connection, 10);
    rtipc_connection_force_disconnect(&connection, 11);

    unsigned sends = 0;
    unsigned disconnected = 0;
    unsigned reconnect_actions = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            sends++;
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected++;
        if (action->type == RTIPC_ACTION_RECONNECT)
            reconnect_actions++;
    }
    if (connection.state != RTIPC_STATE_RECONNECTING || sends != 0 ||
        disconnected != 1 || reconnect_actions != 1) {
        fprintf(stderr,
                "reconnect leaked old control: state=%d sends=%u disconnected=%u reconnect=%u\n",
                connection.state, sends, disconnected, reconnect_actions);
        return -1;
    }
    return 0;
}

static int new_syn_drops_previous_session_control_actions(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_MAX_PACKET];

    initialize_session(&connection, 0x80000100U);
    configure_heartbeat(&connection, false);
    rtipc_connection_tick(&connection, 10);
    size_t packet_len = build_data_packet(connection.expected_seq + 1,
                                          packet, sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 10);

    packet_len = build_control_packet(RTIPC_MSG_SYN, 0x80000300U, packet,
                                      sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 11);

    unsigned heartbeats = 0;
    unsigned ordinary_acks = 0;
    unsigned synacks = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type != RTIPC_ACTION_SEND)
            continue;
        rtipc_header_t header;
        if (rtipc_header_parse(action->data, action->data_len, &header) != 0)
            return -1;
        if (header.msg_type == RTIPC_MSG_HEARTBEAT)
            heartbeats++;
        if (header.msg_type == RTIPC_MSG_ACK)
            ordinary_acks++;
        if (header.msg_type == RTIPC_MSG_SYNACK)
            synacks++;
    }
    if (connection.state != RTIPC_STATE_CONNECTED || heartbeats != 0 ||
        ordinary_acks != 0 || synacks != 1) {
        fprintf(stderr,
                "new SYN leaked controls: state=%d heartbeat=%u ack=%u synack=%u\n",
                connection.state, heartbeats, ordinary_acks, synacks);
        return -1;
    }
    return 0;
}

static int copy_next_send(rtipc_connection_t *connection, uint8_t *packet,
                          size_t packet_size, rtipc_header_t *header)
{
    const rtipc_action_t *action;

    while ((action = rtipc_action_next(connection)) != NULL) {
        if (action->type != RTIPC_ACTION_SEND)
            continue;
        if (action->data_len > packet_size ||
            rtipc_header_parse(action->data, action->data_len, header) != 0)
            return -1;
        memcpy(packet, action->data, action->data_len);
        return (int)action->data_len;
    }
    return -1;
}

static unsigned drain_action_type(rtipc_connection_t *connection,
                                  rtipc_action_type_t type)
{
    unsigned count = 0;
    const rtipc_action_t *action;

    while ((action = rtipc_action_next(connection)) != NULL) {
        if (action->type == type)
            count++;
    }
    rtipc_action_clear(connection);
    return count;
}

static int v1_old_client_uses_syn_sequence_for_first_data(void)
{
    rtipc_config_t config;
    rtipc_connection_t server;
    uint8_t packet[RTIPC_MAX_PACKET];
    rtipc_header_t header;
    const uint32_t sequence = 0x80001000U;

    rtipc_config_default(&config);
    rtipc_connection_init(&server, &config);

    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, sequence, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&server, packet, packet_len, 1);
    int synack_len = copy_next_send(&server, packet, sizeof(packet), &header);
    rtipc_action_clear(&server);
    if (synack_len != RTIPC_HEADER_SIZE ||
        header.msg_type != RTIPC_MSG_SYNACK || header.seq_num != sequence ||
        server.state != RTIPC_STATE_CONNECTED) {
        fprintf(stderr,
                "v1 server did not connect on SYNACK admission: state=%d\n",
                server.state);
        return -1;
    }

    packet_len = build_data_packet(sequence, packet, sizeof(packet));
    rtipc_connection_on_recv(&server, packet, packet_len, 2);
    unsigned deliveries = drain_action_type(&server, RTIPC_ACTION_DELIVER);
    if (deliveries != 1 || server.expected_seq != sequence + 1 ||
        server.stats.rx_packets != 1) {
        fprintf(stderr,
                "v1 old client first data S rejected: delivered=%u expected=%u rx=%u\n",
                deliveries, server.expected_seq, server.stats.rx_packets);
        return -1;
    }
    return 0;
}

static int v1_new_client_uses_syn_sequence_for_first_data(void)
{
    rtipc_config_t config;
    rtipc_connection_t client;
    uint8_t packet[RTIPC_MAX_PACKET];
    rtipc_header_t header;
    static const uint8_t payload[] = "v1";

    rtipc_config_default(&config);
    rtipc_connection_init(&client, &config);
    rtipc_connection_connect(&client, 0);
    int packet_len = copy_next_send(&client, packet, sizeof(packet), &header);
    rtipc_action_clear(&client);
    if (packet_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN)
        return -1;
    uint32_t sequence = header.seq_num;

    size_t synack_len = build_control_packet(RTIPC_MSG_SYNACK, sequence,
                                             packet, sizeof(packet));
    rtipc_connection_on_recv(&client, packet, synack_len, 1);
    rtipc_action_clear(&client);
    if (client.state != RTIPC_STATE_CONNECTED || client.send_seq != sequence) {
        fprintf(stderr,
                "v1 new client starts after S: session=%u send=%u\n",
                sequence, client.send_seq);
        return -1;
    }

    if (rtipc_connection_send(&client, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 2) != RTIPC_SEND_OK)
        return -1;
    packet_len = copy_next_send(&client, packet, sizeof(packet), &header);
    if (packet_len <= 0 || header.msg_type != RTIPC_MSG_CTRL_CMD ||
        header.seq_num != sequence) {
        fprintf(stderr,
                "v1 new client first data sequence=%u wanted=%u\n",
                header.seq_num, sequence);
        return -1;
    }
    return 0;
}

static int v1_server_echoes_exact_syn_above_local_floors(void)
{
    rtipc_config_t config;
    rtipc_connection_t server;
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t header;
    const uint32_t sequence = 0x80001000U;
    const uint32_t local_floor = sequence + 100;

    rtipc_config_default(&config);
    rtipc_connection_init(&server, &config);
    server.control_seq = local_floor;
    server.next_session_seq = local_floor;

    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, sequence, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&server, packet, packet_len, 10);
    int synack_len = copy_next_send(&server, packet, sizeof(packet), &header);
    if (synack_len != RTIPC_HEADER_SIZE ||
        header.msg_type != RTIPC_MSG_SYNACK || header.seq_num != sequence ||
        server.state != RTIPC_STATE_CONNECTED ||
        server.session_seq != sequence || server.send_seq != sequence ||
        server.expected_seq != sequence ||
        server.control_pending.active ||
        server.control_seq != local_floor) {
        fprintf(stderr,
                "v1 server rewrote SYN: wire=%u session=%u send=%u expected=%u pending=%d control=%u\n",
                header.seq_num, server.session_seq, server.send_seq,
                server.expected_seq, server.control_pending.active,
                server.control_seq);
        return -1;
    }
    return 0;
}

static int v1_client_rejects_shifted_synack_without_side_effects(void)
{
    rtipc_config_t config;
    rtipc_connection_t client;
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t header;

    rtipc_config_default(&config);
    rtipc_connection_init(&client, &config);
    rtipc_connection_connect(&client, 7);
    int syn_len = copy_next_send(&client, packet, sizeof(packet), &header);
    rtipc_action_clear(&client);
    if (syn_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN)
        return -1;

    uint32_t sequence = header.seq_num;
    uint32_t control_sequence = client.control_seq;
    uint32_t next_session_sequence = client.next_session_seq;
    rtipc_stats_t stats = client.stats;
    size_t shifted_len = build_control_packet(RTIPC_MSG_SYNACK, sequence + 1,
                                              packet, sizeof(packet));
    rtipc_connection_on_recv(&client, packet, shifted_len, 99);

    if (client.state != RTIPC_STATE_SYN_SENT ||
        client.session_seq != sequence || client.send_seq != sequence ||
        client.expected_seq != sequence ||
        client.control_seq != control_sequence ||
        client.next_session_seq != next_session_sequence ||
        client.last_hb_recv_ms != 0 || client.last_hb_sent_ms != 0 ||
        !client.control_pending.active ||
        client.control_pending.msg_type != RTIPC_MSG_SYN ||
        client.control_pending.seq != sequence || client.action_count != 0 ||
        memcmp(&client.stats, &stats, sizeof(stats)) != 0) {
        fprintf(stderr,
                "shifted SYNACK mutated client: state=%d session=%u send=%u expected=%u control=%u live=%llu/%llu pending=%d actions=%u\n",
                client.state, client.session_seq, client.send_seq,
                client.expected_seq, client.control_seq,
                (unsigned long long)client.last_hb_recv_ms,
                (unsigned long long)client.last_hb_sent_ms,
                client.control_pending.active, client.action_count);
        return -1;
    }
    return 0;
}

static int stale_peer_syn_is_not_reused_after_local_connect(void)
{
    static const struct {
        uint32_t peer_sequence;
        uint32_t local_sequence;
    } cases[] = {
        {0x80000100U, 0x80000200U},
        {0xfffffff0U, 0x00000010U},
    };

    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        rtipc_config_t config;
        rtipc_connection_t connection;
        uint8_t packet[RTIPC_HEADER_SIZE];
        rtipc_header_t header;

        rtipc_config_default(&config);
        rtipc_connection_init(&connection, &config);
        size_t packet_len = build_control_packet(
            RTIPC_MSG_SYN, cases[index].peer_sequence, packet,
            sizeof(packet));
        rtipc_connection_on_recv(&connection, packet, packet_len, 1);
        rtipc_action_clear(&connection);
        if (connection.state != RTIPC_STATE_CONNECTED ||
            !connection.peer_syn_seq_valid)
            return -1;

        rtipc_connection_force_disconnect(&connection, 2);
        rtipc_action_clear(&connection);
        connection.control_seq = cases[index].local_sequence;
        connection.next_session_seq = cases[index].local_sequence;
        rtipc_connection_connect(&connection, 3);
        int syn_len = copy_next_send(&connection, packet, sizeof(packet),
                                     &header);
        rtipc_action_clear(&connection);
        uint32_t local_session = cases[index].peer_sequence +
                                 RTIPC_SESSION_SEQUENCE_SPAN;
        if (syn_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN ||
            header.seq_num != local_session)
            return -1;

        packet_len = build_control_packet(RTIPC_MSG_SYNACK,
                                          local_session,
                                          packet, sizeof(packet));
        rtipc_connection_on_recv(&connection, packet, packet_len, 4);
        rtipc_action_clear(&connection);
        if (connection.state != RTIPC_STATE_CONNECTED)
            return -1;

        uint64_t last_receive = connection.last_hb_recv_ms;
        rtipc_stats_t stats = connection.stats;
        packet_len = build_control_packet(RTIPC_MSG_SYN,
                                          cases[index].peer_sequence,
                                          packet, sizeof(packet));
        rtipc_connection_on_recv(&connection, packet, packet_len, 5);
        const rtipc_action_t *action = rtipc_action_next(&connection);
        if (action != NULL || connection.peer_syn_seq_valid ||
            connection.session_seq != local_session ||
            connection.last_hb_recv_ms != last_receive ||
            memcmp(&connection.stats, &stats, sizeof(stats)) != 0) {
            uint32_t emitted_sequence = 0;
            if (action != NULL && action->type == RTIPC_ACTION_SEND &&
                rtipc_header_parse(action->data, action->data_len, &header) == 0)
                emitted_sequence = header.seq_num;
            fprintf(stderr,
                    "stale peer SYN reused role case=%zu peer=%u local=%u emitted=%u valid=%d\n",
                    index, cases[index].peer_sequence,
                    cases[index].local_sequence, emitted_sequence,
                    connection.peer_syn_seq_valid);
            return -1;
        }
        rtipc_action_clear(&connection);
    }
    return 0;
}

static int establish_role_switched_session(rtipc_connection_t *connection,
                                           uint32_t old_sequence,
                                           uint32_t *new_sequence)
{
    static const uint32_t isolation_span = 0x40000000U;
    rtipc_config_t config;
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t header;

    rtipc_config_default(&config);
    rtipc_connection_init(connection, &config);
    size_t packet_len = build_control_packet(RTIPC_MSG_SYN, old_sequence,
                                             packet, sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 1);
    rtipc_action_clear(connection);
    if (connection->state != RTIPC_STATE_CONNECTED)
        return -1;

    rtipc_connection_force_disconnect(connection, 2);
    rtipc_action_clear(connection);
    rtipc_connection_connect(connection, 3);
    int syn_len = copy_next_send(connection, packet, sizeof(packet), &header);
    rtipc_action_clear(connection);
    if (syn_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN ||
        header.seq_num != old_sequence + isolation_span) {
        fprintf(stderr,
                "role switch reused old range: old=%u new=%u wanted=%u\n",
                old_sequence, header.seq_num,
                old_sequence + isolation_span);
        return -1;
    }
    *new_sequence = header.seq_num;

    packet_len = build_control_packet(RTIPC_MSG_SYNACK, *new_sequence,
                                      packet, sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 4);
    rtipc_action_clear(connection);
    return connection->state == RTIPC_STATE_CONNECTED ? 0 : -1;
}

static int role_switch_isolates_delayed_old_session_packets(void)
{
    static const uint32_t old_sessions[] = {
        0x80001000U,
        0xe0001000U,
    };
    static const uint8_t delayed_types[] = {
        RTIPC_MSG_CTRL_CMD,
        RTIPC_MSG_ACK,
        RTIPC_MSG_FIN,
        RTIPC_MSG_HEARTBEAT,
        RTIPC_MSG_HEARTBEAT_ACK,
    };

    for (size_t session = 0;
         session < sizeof(old_sessions) / sizeof(old_sessions[0]);
         session++) {
        for (size_t type = 0;
             type < sizeof(delayed_types) / sizeof(delayed_types[0]);
             type++) {
            rtipc_connection_t connection;
            uint8_t packet[RTIPC_MAX_PACKET];
            uint32_t new_sequence;

            if (establish_role_switched_session(
                    &connection, old_sessions[session],
                    &new_sequence) != 0)
                return -1;

            static const uint8_t payload[] = "new-session-pending";
            if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD,
                                      payload, sizeof(payload), 5) !=
                RTIPC_SEND_OK)
                return -1;
            rtipc_action_clear(&connection);

            rtipc_stats_t stats = connection.stats;
            uint64_t last_receive = connection.last_hb_recv_ms;
            uint32_t old_delayed_sequence = old_sessions[session] + 1;
            size_t packet_len;
            if (delayed_types[type] == RTIPC_MSG_CTRL_CMD) {
                packet_len = build_data_packet(old_delayed_sequence, packet,
                                               sizeof(packet));
            } else {
                packet_len = build_control_packet(delayed_types[type],
                                                  old_delayed_sequence,
                                                  packet, sizeof(packet));
            }
            rtipc_connection_on_recv(&connection, packet, packet_len, 6);

            if (connection.state != RTIPC_STATE_CONNECTED ||
                connection.session_seq != new_sequence ||
                connection.expected_seq != new_sequence ||
                connection.last_hb_recv_ms != last_receive ||
                connection.pending_count != 1 ||
                connection.action_count != 0 ||
                memcmp(&connection.stats, &stats, sizeof(stats)) != 0) {
                fprintf(stderr,
                        "old packet crossed role switch: case=%zu type=%u old=%u new=%u state=%d pending=%u actions=%u\n",
                        session, delayed_types[type], old_delayed_sequence,
                        new_sequence, connection.state,
                        connection.pending_count, connection.action_count);
                return -1;
            }
        }
    }
    return 0;
}

static int session_sequence_domain_is_bounded(void)
{
    static const uint32_t isolation_span = 0x40000000U;
    const uint32_t session_sequence = 0xe0000000U;
    const uint32_t session_end = session_sequence + isolation_span;
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_MAX_PACKET];
    rtipc_header_t header;

    initialize_session(&connection, session_sequence);
    rtipc_stats_t stats = connection.stats;
    size_t packet_len = build_data_packet(session_end, packet,
                                          sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 1);
    if (connection.action_count != 0 ||
        connection.expected_seq != session_sequence ||
        memcmp(&connection.stats, &stats, sizeof(stats)) != 0) {
        fprintf(stderr,
                "packet beyond session domain admitted: actions=%u expected=%u rx=%u\n",
                connection.action_count, connection.expected_seq,
                connection.stats.rx_packets);
        return -1;
    }

    initialize_session(&connection, session_sequence);
    connection.send_seq = session_end - 1;
    static const uint8_t payload[] = "domain-end";
    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 2) !=
            RTIPC_SEND_WOULD_BLOCK ||
        connection.action_count != 0 || connection.pending_count != 0) {
        fprintf(stderr,
                "data consumed FIN-reserved sequence: send=%u actions=%u pending=%u\n",
                connection.send_seq, connection.action_count,
                connection.pending_count);
        return -1;
    }

    connection.control_seq = session_end - 1;
    connection.next_session_seq = session_end - 1;
    rtipc_connection_disconnect(&connection, 3);
    int fin_len = copy_next_send(&connection, packet, sizeof(packet), &header);
    if (fin_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_FIN ||
        header.seq_num != session_end - 1) {
        fprintf(stderr,
                "FIN did not use reserved sequence: len=%d type=%u seq=%u\n",
                fin_len, header.msg_type, header.seq_num);
        return -1;
    }
    return 0;
}

static int client_restart_uses_a_new_session_incarnation(void)
{
    rtipc_config_t first_config;
    rtipc_config_t second_config;
    rtipc_config_t server_config;
    rtipc_connection_t first_client;
    rtipc_connection_t second_client;
    rtipc_connection_t server;
    uint8_t packet[RTIPC_MAX_PACKET];
    uint8_t reply[RTIPC_MAX_PACKET];
    uint8_t stale_packet[RTIPC_MAX_PACKET];
    size_t stale_packet_len;
    rtipc_header_t header;

    rtipc_config_default(&first_config);
    rtipc_config_default(&second_config);
    rtipc_config_default(&server_config);
    first_config.session_id_seed = UINT64_C(0x1111222233334444);
    second_config.session_id_seed = UINT64_C(0x5555666677778888);
    rtipc_connection_init(&first_client, &first_config);
    rtipc_connection_init(&second_client, &second_config);
    rtipc_connection_init(&server, &server_config);

    rtipc_connection_connect(&first_client, 1);
    int packet_len = copy_next_send(&first_client, packet, sizeof(packet),
                                    &header);
    rtipc_action_clear(&first_client);
    if (packet_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN)
        return -1;
    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 2);
    int reply_len = copy_next_send(&server, reply, sizeof(reply), &header);
    rtipc_action_clear(&server);
    if (reply_len != RTIPC_HEADER_SIZE ||
        header.msg_type != RTIPC_MSG_SYNACK)
        return -1;
    rtipc_connection_on_recv(&first_client, reply, (size_t)reply_len, 3);
    rtipc_action_clear(&first_client);

    static const uint8_t first_payload[] = "first-incarnation";
    if (rtipc_connection_send(&first_client, RTIPC_MSG_CTRL_CMD,
                              first_payload, sizeof(first_payload), 4) !=
        RTIPC_SEND_OK)
        return -1;
    packet_len = copy_next_send(&first_client, packet, sizeof(packet), &header);
    rtipc_action_clear(&first_client);
    if (packet_len <= 0)
        return -1;
    stale_packet_len = (size_t)packet_len;
    memcpy(stale_packet, packet, stale_packet_len);
    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 5);
    rtipc_action_clear(&server);

    rtipc_connection_connect(&second_client, 6);
    packet_len = copy_next_send(&second_client, packet, sizeof(packet),
                                &header);
    rtipc_action_clear(&second_client);
    if (packet_len != RTIPC_HEADER_SIZE || header.msg_type != RTIPC_MSG_SYN)
        return -1;
    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 7);
    reply_len = copy_next_send(&server, reply, sizeof(reply), &header);
    rtipc_action_clear(&server);
    if (reply_len != RTIPC_HEADER_SIZE ||
        header.msg_type != RTIPC_MSG_SYNACK)
        return -1;
    rtipc_connection_on_recv(&second_client, reply, (size_t)reply_len, 8);
    rtipc_action_clear(&second_client);

    static const uint8_t second_payload[] = "second-incarnation";
    if (rtipc_connection_send(&second_client, RTIPC_MSG_CTRL_CMD,
                              second_payload, sizeof(second_payload), 9) !=
        RTIPC_SEND_OK)
        return -1;
    packet_len = copy_next_send(&second_client, packet, sizeof(packet),
                                &header);
    rtipc_action_clear(&second_client);
    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 10);

    unsigned deliveries = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&server)) != NULL) {
        if (action->type == RTIPC_ACTION_DELIVER &&
            action->payload_len == sizeof(second_payload) &&
            memcmp(action->payload, second_payload,
                   sizeof(second_payload)) == 0)
            deliveries++;
    }
    rtipc_action_clear(&server);
    if (deliveries != 1) {
        fprintf(stderr,
                "restarted client first request deliveries=%u state=%d expected=%u\n",
                deliveries, server.state, server.expected_seq);
        return -1;
    }

    rtipc_stats_t stats = server.stats;
    rtipc_connection_on_recv(&server, stale_packet, stale_packet_len, 11);
    if (rtipc_action_next(&server) != NULL ||
        memcmp(&server.stats, &stats, sizeof(stats)) != 0) {
        fputs("old incarnation packet crossed into restarted session\n",
              stderr);
        rtipc_action_clear(&server);
        return -1;
    }
    rtipc_action_clear(&server);
    return 0;
}

static int delayed_old_syn_cannot_restore_retired_session(void)
{
    const uint64_t old_session = UINT64_C(0x1111222233334444);
    const uint64_t new_session = UINT64_C(0x5555666677778888);
    rtipc_config_t config;
    rtipc_connection_t server;
    uint8_t old_syn[RTIPC_HEADER_SIZE];
    uint8_t packet[RTIPC_HEADER_SIZE];

    rtipc_config_default(&config);
    config.auto_reconnect = false;
    rtipc_connection_init(&server, &config);

    size_t packet_len = build_control_packet_for_session(
        RTIPC_MSG_SYN, 100, old_session, old_syn, sizeof(old_syn));
    rtipc_connection_on_recv(&server, old_syn, packet_len, 1);
    rtipc_action_clear(&server);
    if (server.state != RTIPC_STATE_CONNECTED ||
        server.session_id != old_session)
        return -1;

    packet_len = build_control_packet_for_session(
        RTIPC_MSG_FIN, 101, old_session, packet, sizeof(packet));
    rtipc_connection_on_recv(&server, packet, packet_len, 2);
    rtipc_action_clear(&server);
    if (server.state != RTIPC_STATE_CLOSED)
        return -1;

    packet_len = build_control_packet_for_session(
        RTIPC_MSG_SYN, 200, new_session, packet, sizeof(packet));
    rtipc_connection_on_recv(&server, packet, packet_len, 3);
    rtipc_action_clear(&server);
    if (server.state != RTIPC_STATE_CONNECTED ||
        server.session_id != new_session || server.session_seq != 200)
        return -1;

    rtipc_connection_on_recv(&server, old_syn, sizeof(old_syn), 4);
    if (server.state != RTIPC_STATE_CONNECTED ||
        server.session_id != new_session || server.session_seq != 200 ||
        server.action_count != 0) {
        fprintf(stderr,
                "delayed old SYN restored session=%llx seq=%u state=%d actions=%u\n",
                (unsigned long long)server.session_id, server.session_seq,
                server.state, server.action_count);
        rtipc_action_clear(&server);
        return -1;
    }
    return 0;
}

static int syn_rto_retransmits_without_queue_budget_loss(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t first[RTIPC_HEADER_SIZE];
    uint8_t retransmit[RTIPC_HEADER_SIZE];
    rtipc_header_t first_header;
    rtipc_header_t retransmit_header;

    rtipc_config_default(&config);
    config.rto_ms = 10;
    config.max_retries = 2;
    config.connect_timeout_ms = 1000;
    rtipc_connection_init(&connection, &config);
    rtipc_connection_connect(&connection, 0);
    int first_len = copy_next_send(&connection, first, sizeof(first),
                                   &first_header);
    rtipc_action_clear(&connection);
    if (first_len != RTIPC_HEADER_SIZE || first_header.msg_type != RTIPC_MSG_SYN)
        return -1;

    rtipc_connection_tick(&connection, 10);
    int retransmit_len = copy_next_send(&connection, retransmit,
                                        sizeof(retransmit),
                                        &retransmit_header);
    if (retransmit_len != first_len ||
        memcmp(first, retransmit, (size_t)first_len) != 0 ||
        connection.stats.retransmissions != 1) {
        fprintf(stderr,
                "lost SYN was not retransmitted at RTO: len=%d retrans=%u\n",
                retransmit_len, connection.stats.retransmissions);
        return -1;
    }
    rtipc_action_clear(&connection);

    fill_action_queue(&connection);
    rtipc_connection_tick(&connection, 20);
    if (connection.stats.retransmissions != 1) {
        fprintf(stderr, "full queue consumed SYN retry budget: retrans=%u\n",
                connection.stats.retransmissions);
        return -1;
    }
    while (rtipc_action_next(&connection) != NULL) {
    }
    rtipc_action_clear(&connection);

    rtipc_connection_tick(&connection, 20);
    retransmit_len = copy_next_send(&connection, retransmit,
                                    sizeof(retransmit), &retransmit_header);
    if (retransmit_len != first_len ||
        retransmit_header.seq_num != first_header.seq_num ||
        connection.stats.retransmissions != 2) {
        fprintf(stderr,
                "SYN retry did not resume after queue drain: len=%d retrans=%u\n",
                retransmit_len, connection.stats.retransmissions);
        return -1;
    }
    rtipc_action_clear(&connection);

    rtipc_connection_tick(&connection, 30);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.stats.timeouts != 1 ||
        connection.stats.retransmissions != 2) {
        fprintf(stderr,
                "SYN retry exhaustion state=%d timeouts=%u retrans=%u\n",
                connection.state, connection.stats.timeouts,
                connection.stats.retransmissions);
        return -1;
    }
    return 0;
}

static int synack_ack_loss_recovers_idempotently(void)
{
    rtipc_config_t config;
    rtipc_connection_t client;
    rtipc_connection_t server;
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t header;

    rtipc_config_default(&config);
    config.rto_ms = 10;
    config.connect_timeout_ms = 1000;
    rtipc_connection_init(&client, &config);
    rtipc_connection_init(&server, &config);

    rtipc_connection_connect(&client, 0);
    int packet_len = copy_next_send(&client, packet, sizeof(packet), &header);
    rtipc_action_clear(&client);
    if (packet_len < 0)
        return -1;
    uint8_t syn[RTIPC_HEADER_SIZE];
    memcpy(syn, packet, (size_t)packet_len);
    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 1);
    uint32_t session_sequence = server.session_seq;
    uint32_t control_sequence = server.control_seq;
    rtipc_action_clear(&server); /* Drop the first SYNACK. */
    if (server.state != RTIPC_STATE_CONNECTED ||
        server.session_seq != session_sequence ||
        server.control_seq != control_sequence ||
        server.stats.retransmissions != 0) {
        fprintf(stderr, "first SYN changed unexpected server state\n");
        return -1;
    }

    rtipc_connection_tick(&client, 10);
    packet_len = copy_next_send(&client, packet, sizeof(packet), &header);
    rtipc_action_clear(&client);
    if (packet_len < 0 || header.msg_type != RTIPC_MSG_SYN ||
        header.seq_num != session_sequence ||
        client.stats.retransmissions != 1) {
        fprintf(stderr,
                "client did not retransmit lost-SYNACK SYN: len=%d type=%u seq=%u retrans=%u\n",
                packet_len, header.msg_type, header.seq_num,
                client.stats.retransmissions);
        return -1;
    }

    rtipc_connection_on_recv(&server, packet, (size_t)packet_len, 11);
    packet_len = copy_next_send(&server, packet, sizeof(packet), &header);
    rtipc_action_clear(&server);
    if (packet_len < 0 || header.msg_type != RTIPC_MSG_SYNACK ||
        header.seq_num != session_sequence ||
        server.stats.retransmissions != 0 ||
        server.state != RTIPC_STATE_CONNECTED) {
        fprintf(stderr, "duplicate SYN did not regenerate exact SYNACK\n");
        return -1;
    }

    rtipc_connection_on_recv(&client, packet, (size_t)packet_len, 12);
    unsigned sends = 0;
    unsigned client_connected = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&client)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            sends++;
        if (action->type == RTIPC_ACTION_CONNECTED)
            client_connected++;
    }
    rtipc_action_clear(&client);
    if (sends != 0 || client_connected != 1 ||
        client.state != RTIPC_STATE_CONNECTED) {
        fprintf(stderr,
                "two-packet SYNACK completion sends=%u events=%u state=%d\n",
                sends, client_connected, client.state);
        return -1;
    }

    rtipc_connection_on_recv(&client, packet, (size_t)packet_len, 13);
    if (client.state != RTIPC_STATE_CONNECTED || client.action_count != 0) {
        fprintf(stderr, "duplicate SYNACK changed connected client\n");
        return -1;
    }
    return 0;
}

static int fin_ack_loss_recovers_idempotently(void)
{
    rtipc_config_t config;
    rtipc_connection_t client;
    rtipc_connection_t server;
    uint8_t fin[RTIPC_HEADER_SIZE];
    uint8_t ack[RTIPC_HEADER_SIZE];
    rtipc_header_t header;

    rtipc_config_default(&config);
    config.rto_ms = 10;
    initialize_session(&client, 100);
    initialize_session(&server, 100);
    client.config = config;
    server.config = config;
    client.control_seq = 101;
    server.control_seq = 101;

    rtipc_connection_disconnect(&client, 0);
    int fin_len = copy_next_send(&client, fin, sizeof(fin), &header);
    rtipc_action_clear(&client);
    if (fin_len < 0 || header.msg_type != RTIPC_MSG_FIN ||
        client.state != RTIPC_STATE_SHUTDOWN)
        return -1;
    rtipc_connection_on_recv(&server, fin, (size_t)fin_len, 1);
    int ack_len = copy_next_send(&server, ack, sizeof(ack), &header);
    unsigned server_disconnected = drain_action_type(
        &server, RTIPC_ACTION_DISCONNECTED);
    if (ack_len < 0 || header.msg_type != RTIPC_MSG_ACK ||
        server.state != RTIPC_STATE_CLOSED || server_disconnected != 1) {
        fprintf(stderr,
                "FIN did not queue ACK before close: ack=%d state=%d events=%u\n",
                ack_len, server.state, server_disconnected);
        return -1;
    }

    rtipc_connection_tick(&client, 10);
    fin_len = copy_next_send(&client, fin, sizeof(fin), &header);
    rtipc_action_clear(&client);
    if (fin_len < 0 || header.msg_type != RTIPC_MSG_FIN ||
        client.stats.retransmissions != 1)
        return -1;
    rtipc_connection_on_recv(&server, fin, (size_t)fin_len, 11);
    uint8_t recovered_ack[RTIPC_HEADER_SIZE];
    ack_len = copy_next_send(&server, recovered_ack, sizeof(recovered_ack),
                             &header);
    server_disconnected = drain_action_type(&server,
                                            RTIPC_ACTION_DISCONNECTED);
    if (ack_len < 0 || memcmp(ack, recovered_ack, (size_t)ack_len) != 0 ||
        server_disconnected != 0 || server.state != RTIPC_STATE_CLOSED) {
        fprintf(stderr,
                "duplicate FIN did not recover ACK idempotently: ack=%d events=%u state=%d\n",
                ack_len, server_disconnected, server.state);
        return -1;
    }

    rtipc_connection_on_recv(&client, recovered_ack, (size_t)ack_len, 12);
    unsigned client_disconnected = drain_action_type(
        &client, RTIPC_ACTION_DISCONNECTED);
    if (client.state != RTIPC_STATE_CLOSED || client_disconnected != 1 ||
        client.stats.timeouts != 0) {
        fprintf(stderr,
                "FIN ACK did not complete close: state=%d events=%u timeouts=%u\n",
                client.state, client_disconnected, client.stats.timeouts);
        return -1;
    }
    return 0;
}

static int fin_sequence_does_not_collide_with_delayed_data_ack(void)
{
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_MAX_PACKET];
    uint8_t ack[RTIPC_HEADER_SIZE];
    rtipc_header_t header;
    static const uint8_t payload[] = "delayed-data-ack";

    initialize_session(&connection, 100);
    connection.control_seq = 100;
    if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), 0) != RTIPC_SEND_OK)
        return -1;
    int packet_len = copy_next_send(&connection, packet, sizeof(packet),
                                    &header);
    rtipc_action_clear(&connection);
    if (packet_len < 0 || header.seq_num != 100)
        return -1;

    rtipc_connection_disconnect(&connection, 1);
    packet_len = copy_next_send(&connection, packet, sizeof(packet), &header);
    rtipc_action_clear(&connection);
    if (packet_len < 0 || header.msg_type != RTIPC_MSG_FIN ||
        header.seq_num == 100 || connection.state != RTIPC_STATE_SHUTDOWN) {
        fprintf(stderr,
                "FIN collided with data seq: len=%d type=%u data=100 fin=%u state=%d\n",
                packet_len, header.msg_type, header.seq_num, connection.state);
        return -1;
    }
    uint32_t fin_sequence = header.seq_num;

    size_t ack_len = build_control_packet(RTIPC_MSG_ACK, 100, ack,
                                          sizeof(ack));
    rtipc_connection_on_recv(&connection, ack, ack_len, 2);
    if (connection.state != RTIPC_STATE_SHUTDOWN ||
        !connection.control_pending.active ||
        connection.control_pending.seq != fin_sequence) {
        fprintf(stderr,
                "delayed data ACK closed FIN: state=%d pending=%d seq=%u fin=%u\n",
                connection.state, connection.control_pending.active,
                connection.control_pending.seq, fin_sequence);
        return -1;
    }

    ack_len = build_control_packet(RTIPC_MSG_ACK, fin_sequence, ack,
                                   sizeof(ack));
    rtipc_connection_on_recv(&connection, ack, ack_len, 3);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.control_pending.active) {
        fprintf(stderr, "FIN ACK did not close: state=%d pending=%d\n",
                connection.state, connection.control_pending.active);
        return -1;
    }
    return 0;
}

static int fin_retry_exhaustion_times_out_once(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];
    rtipc_header_t header;

    rtipc_config_default(&config);
    config.rto_ms = 10;
    config.max_retries = 1;
    initialize_session(&connection, 100);
    connection.config = config;
    connection.control_seq = 101;
    rtipc_connection_disconnect(&connection, 0);
    if (copy_next_send(&connection, packet, sizeof(packet), &header) < 0)
        return -1;
    rtipc_action_clear(&connection);

    rtipc_connection_tick(&connection, 10);
    if (copy_next_send(&connection, packet, sizeof(packet), &header) < 0 ||
        connection.stats.retransmissions != 1)
        return -1;
    rtipc_action_clear(&connection);
    rtipc_connection_tick(&connection, 20);
    rtipc_connection_tick(&connection, 30);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.stats.retransmissions != 1 ||
        connection.stats.timeouts != 1 ||
        drain_action_type(&connection, RTIPC_ACTION_DISCONNECTED) != 1) {
        fprintf(stderr,
                "FIN exhaustion was not a single timeout: state=%d retrans=%u timeouts=%u\n",
                connection.state, connection.stats.retransmissions,
                connection.stats.timeouts);
        return -1;
    }
    return 0;
}

static int exhausted_packet_preempts_later_retransmission(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    static const uint8_t payload[] = "mixed-retry";

    rtipc_config_default(&config);
    config.heartbeat_interval_ms = UINT64_MAX;
    config.heartbeat_timeout_ms = UINT64_MAX;
    config.rto_ms = 10;
    config.max_retries = 1;
    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;

    for (unsigned index = 0; index < 2; index++) {
        if (rtipc_connection_send(&connection, RTIPC_MSG_CTRL_CMD, payload,
                                  sizeof(payload), 0) != RTIPC_SEND_OK)
            return -1;
        rtipc_action_clear(&connection);
    }
    uint32_t first_sequence = connection.pending[0].seq;

    fill_action_queue(&connection);
    connection.action_count = RTIPC_ACTION_QUEUE_CAPACITY - 1;
    rtipc_connection_tick(&connection, 10);

    unsigned first_sends = 0;
    uint32_t retransmitted_sequence = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND) {
            rtipc_header_t header;
            if (rtipc_header_parse(action->data, action->data_len,
                                   &header) != 0)
                return -1;
            first_sends++;
            retransmitted_sequence = header.seq_num;
        }
    }
    rtipc_action_clear(&connection);
    if (first_sends != 1 || retransmitted_sequence != first_sequence ||
        connection.pending[0].retries != 1 ||
        connection.pending[1].retries != 0 ||
        connection.stats.retransmissions != 1) {
        fprintf(stderr,
                "mixed retry setup failed: sends=%u seq=%u retries=%u/%u retrans=%u\n",
                first_sends, retransmitted_sequence,
                connection.pending[0].retries,
                connection.pending[1].retries,
                connection.stats.retransmissions);
        return -1;
    }

    rtipc_connection_tick(&connection, 20);
    unsigned sends = 0;
    unsigned disconnected = 0;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_SEND)
            sends++;
        if (action->type == RTIPC_ACTION_DISCONNECTED)
            disconnected++;
    }
    if (connection.state != RTIPC_STATE_CLOSED || sends != 0 ||
        disconnected != 1 || connection.stats.retransmissions != 1 ||
        connection.stats.timeouts != 1) {
        fprintf(stderr,
                "exhausted A counted discarded B retry: state=%d sends=%u disconnected=%u retrans=%u timeouts=%u\n",
                connection.state, sends, disconnected,
                connection.stats.retransmissions, connection.stats.timeouts);
        return -1;
    }
    return 0;
}

static int connect_timeout_is_counted_once(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    rtipc_config_default(&config);
    config.connect_timeout_ms = 10;
    config.rto_ms = 100;
    rtipc_connection_init(&connection, &config);
    rtipc_connection_connect(&connection, 0);
    rtipc_action_clear(&connection);
    rtipc_connection_tick(&connection, 10);
    rtipc_connection_tick(&connection, 20);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.stats.timeouts != 1) {
        fprintf(stderr, "connect timeout state=%d count=%u\n",
                connection.state, connection.stats.timeouts);
        return -1;
    }
    return 0;
}

static int heartbeat_timeout_is_counted_once(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    rtipc_config_default(&config);
    config.heartbeat_interval_ms = UINT64_MAX;
    config.heartbeat_timeout_ms = 10;
    rtipc_connection_init(&connection, &config);
    connection.state = RTIPC_STATE_CONNECTED;
    rtipc_connection_tick(&connection, 10);
    rtipc_connection_tick(&connection, 20);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.stats.timeouts != 1) {
        fprintf(stderr, "heartbeat timeout state=%d count=%u\n",
                connection.state, connection.stats.timeouts);
        return -1;
    }
    return 0;
}

static int configuration_is_limited_to_static_capacity(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    rtipc_config_default(&config);
    config.send_window = UINT32_MAX;
    config.reorder_buf_size = UINT32_MAX;
    rtipc_connection_init(&connection, &config);
    if (connection.config.send_window != RTIPC_SEND_WINDOW ||
        connection.config.reorder_buf_size != RTIPC_SEND_WINDOW) {
        fprintf(stderr, "unsafe capacities send=%u reorder=%u\n",
                connection.config.send_window,
                connection.config.reorder_buf_size);
        return -1;
    }
    return 0;
}

static void initialize_connected(rtipc_connection_t *connection,
                                 rtipc_config_t *config)
{
    rtipc_config_default(config);
    config->heartbeat_interval_ms = UINT64_MAX;
    config->heartbeat_timeout_ms = UINT64_MAX;
    rtipc_connection_init(connection, config);
    connection->state = RTIPC_STATE_CONNECTED;
}

static int add_pending(rtipc_connection_t *connection, uint64_t now_ms)
{
    static const uint8_t payload[] = "pending";
    if (rtipc_connection_send(connection, RTIPC_MSG_CTRL_CMD, payload,
                              sizeof(payload), now_ms) != RTIPC_SEND_OK)
        return -1;
    rtipc_action_clear(connection);
    return 0;
}

static int closed_state_clears_data_session(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;
    uint8_t packet[RTIPC_HEADER_SIZE];

    initialize_connected(&connection, &config);
    if (add_pending(&connection, 0) != 0)
        return -1;
    size_t packet_len = build_control_packet(RTIPC_MSG_FIN, 1, packet,
                                             sizeof(packet));
    rtipc_connection_on_recv(&connection, packet, packet_len, 1);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.pending_count != 0 || connection.expected_seq != 0) {
        fprintf(stderr, "FIN left data state pending=%u expected=%u\n",
                connection.pending_count, connection.expected_seq);
        return -1;
    }

    initialize_connected(&connection, &config);
    config.heartbeat_timeout_ms = 10;
    connection.config = config;
    if (add_pending(&connection, 0) != 0)
        return -1;
    rtipc_connection_tick(&connection, 10);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.pending_count != 0) {
        fprintf(stderr, "heartbeat close left %u pending packets\n",
                connection.pending_count);
        return -1;
    }

    initialize_connected(&connection, &config);
    connection.config.rto_ms = 10;
    connection.config.max_retries = 0;
    if (add_pending(&connection, 0) != 0 || add_pending(&connection, 9) != 0)
        return -1;
    rtipc_connection_tick(&connection, 10);
    if (connection.state != RTIPC_STATE_CLOSED ||
        connection.pending_count != 0) {
        fprintf(stderr, "retry close left %u pending packets\n",
                connection.pending_count);
        return -1;
    }
    return 0;
}

static void receive_data(rtipc_connection_t *connection, uint32_t sequence)
{
    rtipc_header_t header = {0};
    uint8_t packet[RTIPC_MAX_PACKET];
    static const uint8_t payload[] = "data";

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = RTIPC_MSG_CTRL_CMD;
    header.seq_num = sequence;
    size_t packet_len = rtipc_build_packet(&header, payload,
                                           sizeof(payload), packet,
                                           sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 0);
}

static void receive_numbered_data(rtipc_connection_t *connection,
                                  uint32_t sequence)
{
    rtipc_header_t header = {0};
    uint8_t packet[RTIPC_MAX_PACKET];
    uint8_t payload[4] = {
        (uint8_t)(sequence >> 24),
        (uint8_t)(sequence >> 16),
        (uint8_t)(sequence >> 8),
        (uint8_t)sequence,
    };

    header.version = RTIPC_PROTOCOL_VERSION;
    header.msg_type = RTIPC_MSG_CTRL_CMD;
    header.seq_num = sequence;
    size_t packet_len = rtipc_build_packet(&header, payload, sizeof(payload),
                                           packet, sizeof(packet));
    rtipc_connection_on_recv(connection, packet, packet_len, 0);
}

static int full_reorder_prioritizes_missing_expected_packet(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    initialize_connected(&connection, &config);
    for (uint32_t sequence = 1; sequence <= RTIPC_SEND_WINDOW; sequence++) {
        receive_numbered_data(&connection, sequence);
        rtipc_action_clear(&connection);
    }
    if (connection.expected_seq != 0 ||
        connection.reorder_count != RTIPC_SEND_WINDOW)
        return -1;

    receive_numbered_data(&connection, 0);
    unsigned deliveries = 0;
    bool ordered_prefix = true;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type != RTIPC_ACTION_DELIVER)
            continue;
        if (action->payload_len != 4) {
            ordered_prefix = false;
            continue;
        }
        uint32_t delivered_sequence =
            ((uint32_t)action->payload[0] << 24) |
            ((uint32_t)action->payload[1] << 16) |
            ((uint32_t)action->payload[2] << 8) |
            action->payload[3];
        if (delivered_sequence != deliveries)
            ordered_prefix = false;
        deliveries++;
    }
    if (connection.expected_seq != RTIPC_SEND_WINDOW ||
        deliveries != RTIPC_SEND_WINDOW || !ordered_prefix) {
        fprintf(stderr,
                "full reorder rejected expected packet: expected=%u reorder=%u delivered=%u ordered=%d\n",
                connection.expected_seq, connection.reorder_count,
                deliveries, ordered_prefix);
        return -1;
    }
    rtipc_action_clear(&connection);

    receive_numbered_data(&connection, RTIPC_SEND_WINDOW);
    deliveries = 0;
    uint32_t delivered_sequence = 0;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type != RTIPC_ACTION_DELIVER)
            continue;
        deliveries++;
        if (action->payload_len == 4) {
            delivered_sequence =
                ((uint32_t)action->payload[0] << 24) |
                ((uint32_t)action->payload[1] << 16) |
                ((uint32_t)action->payload[2] << 8) |
                action->payload[3];
        }
    }
    if (connection.expected_seq != RTIPC_SEND_WINDOW + 1 ||
        deliveries != 1 || delivered_sequence != RTIPC_SEND_WINDOW) {
        fprintf(stderr,
                "evicted future retransmit did not complete: expected=%u delivered=%u seq=%u\n",
                connection.expected_seq, deliveries, delivered_sequence);
        return -1;
    }
    return 0;
}

static int configured_reorder_limit_is_enforced(void)
{
    rtipc_config_t config;
    rtipc_connection_t connection;

    initialize_connected(&connection, &config);
    connection.config.reorder_buf_size = 0;
    receive_data(&connection, 1);
    if (connection.reorder_count != 0) {
        fprintf(stderr, "zero reorder limit buffered %u packets\n",
                connection.reorder_count);
        return -1;
    }
    rtipc_action_clear(&connection);
    receive_data(&connection, 0);
    unsigned deliveries = 0;
    const rtipc_action_t *action;
    while ((action = rtipc_action_next(&connection)) != NULL) {
        if (action->type == RTIPC_ACTION_DELIVER)
            deliveries++;
    }
    rtipc_action_clear(&connection);
    if (deliveries != 1 || connection.expected_seq != 1) {
        fprintf(stderr,
                "zero reorder limit recovered dropped future packet: delivered=%u expected=%u\n",
                deliveries, connection.expected_seq);
        return -1;
    }

    initialize_connected(&connection, &config);
    connection.config.reorder_buf_size = 1;
    receive_data(&connection, 2);
    rtipc_action_clear(&connection);
    receive_data(&connection, 1);
    rtipc_action_clear(&connection);
    if (connection.reorder_count != 1) {
        fprintf(stderr, "reorder limit 1 retained %u packets\n",
                connection.reorder_count);
        return -1;
    }
    return 0;
}

static int run_named_test(const char *name)
{
    if (strcmp(name, "stale_data") == 0)
        return stale_data_has_no_session_side_effects();
    if (strcmp(name, "stale_heartbeat") == 0)
        return stale_heartbeat_has_no_session_side_effects();
    if (strcmp(name, "stale_fin_ack") == 0)
        return stale_fin_and_ack_have_no_session_side_effects();
    if (strcmp(name, "full_queue_syn") == 0)
        return full_queue_syn_does_not_commit_server_session();
    if (strcmp(name, "full_queue_heartbeat_ack") == 0)
        return full_queue_heartbeat_ack_has_no_side_effects();
    if (strcmp(name, "full_queue_data_ack") == 0)
        return full_queue_data_ack_has_no_side_effects();
    if (strcmp(name, "full_queue_lifecycle") == 0)
        return full_queue_lifecycle_actions_are_eventually_visible();
    if (strcmp(name, "saturated_lifecycle") == 0)
        return saturated_lifecycle_capacity_blocks_state_transitions();
    if (strcmp(name, "new_syn_lifecycle") == 0)
        return new_syn_reports_disconnected_old_session();
    if (strcmp(name, "force_disconnect_drops_control") == 0)
        return queued_heartbeat_is_dropped_on_force_disconnect();
    if (strcmp(name, "reconnect_drops_control") == 0)
        return queued_heartbeat_is_dropped_on_reconnect();
    if (strcmp(name, "new_syn_drops_control") == 0)
        return new_syn_drops_previous_session_control_actions();
    if (strcmp(name, "v1_old_client_first_data") == 0)
        return v1_old_client_uses_syn_sequence_for_first_data();
    if (strcmp(name, "v1_new_client_first_data") == 0)
        return v1_new_client_uses_syn_sequence_for_first_data();
    if (strcmp(name, "v1_server_exact_syn") == 0)
        return v1_server_echoes_exact_syn_above_local_floors();
    if (strcmp(name, "v1_client_rejects_shifted_synack") == 0)
        return v1_client_rejects_shifted_synack_without_side_effects();
    if (strcmp(name, "stale_peer_syn_role") == 0)
        return stale_peer_syn_is_not_reused_after_local_connect();
    if (strcmp(name, "role_switch_isolation") == 0)
        return role_switch_isolates_delayed_old_session_packets();
    if (strcmp(name, "session_sequence_bound") == 0)
        return session_sequence_domain_is_bounded();
    if (strcmp(name, "client_restart_session") == 0)
        return client_restart_uses_a_new_session_incarnation();
    if (strcmp(name, "retired_syn_replay") == 0)
        return delayed_old_syn_cannot_restore_retired_session();
    if (strcmp(name, "syn_rto") == 0)
        return syn_rto_retransmits_without_queue_budget_loss();
    if (strcmp(name, "synack_ack_loss") == 0)
        return synack_ack_loss_recovers_idempotently();
    if (strcmp(name, "fin_ack_loss") == 0)
        return fin_ack_loss_recovers_idempotently();
    if (strcmp(name, "fin_sequence_collision") == 0)
        return fin_sequence_does_not_collide_with_delayed_data_ack();
    if (strcmp(name, "fin_retry_exhaustion") == 0)
        return fin_retry_exhaustion_times_out_once();
    if (strcmp(name, "mixed_retry_exhaustion") == 0)
        return exhausted_packet_preempts_later_retransmission();
    if (strcmp(name, "connect_timeout_stats") == 0)
        return connect_timeout_is_counted_once();
    if (strcmp(name, "heartbeat_timeout_stats") == 0)
        return heartbeat_timeout_is_counted_once();
    if (strcmp(name, "config_capacity_limits") == 0)
        return configuration_is_limited_to_static_capacity();
    if (strcmp(name, "full_reorder_expected") == 0)
        return full_reorder_prioritizes_missing_expected_packet();
    if (strcmp(name, "stale_ack_new_session") == 0)
        return stale_ack_does_not_release_new_session_packet();
    if (strcmp(name, "session_reset_actions") == 0)
        return session_reset_discards_stale_send_actions();
    if (strcmp(name, "full_action_queue") == 0)
        return full_action_queue_does_not_advance_protocol_state();
    if (strcmp(name, "closed_state") == 0)
        return closed_state_clears_data_session();
    if (strcmp(name, "configured_reorder_limit") == 0)
        return configured_reorder_limit_is_enforced();
    return -2;
}

int main(int argc, char **argv)
{
    if (argc == 2) {
        int result = run_named_test(argv[1]);
        if (result == -2) {
            fprintf(stderr, "unknown test: %s\n", argv[1]);
            return 2;
        }
        if (result == 0)
            printf("PASS: %s\n", argv[1]);
        return result == 0 ? 0 : 1;
    }

    if (stale_data_has_no_session_side_effects() != 0)
        return 1;
    if (stale_heartbeat_has_no_session_side_effects() != 0)
        return 1;
    if (stale_fin_and_ack_have_no_session_side_effects() != 0)
        return 1;
    if (full_queue_syn_does_not_commit_server_session() != 0)
        return 1;
    if (full_queue_heartbeat_ack_has_no_side_effects() != 0)
        return 1;
    if (full_queue_data_ack_has_no_side_effects() != 0)
        return 1;
    if (full_queue_lifecycle_actions_are_eventually_visible() != 0)
        return 1;
    if (saturated_lifecycle_capacity_blocks_state_transitions() != 0)
        return 1;
    if (new_syn_reports_disconnected_old_session() != 0)
        return 1;
    if (queued_heartbeat_is_dropped_on_force_disconnect() != 0)
        return 1;
    if (queued_heartbeat_is_dropped_on_reconnect() != 0)
        return 1;
    if (new_syn_drops_previous_session_control_actions() != 0)
        return 1;
    if (v1_old_client_uses_syn_sequence_for_first_data() != 0)
        return 1;
    if (v1_new_client_uses_syn_sequence_for_first_data() != 0)
        return 1;
    if (v1_server_echoes_exact_syn_above_local_floors() != 0)
        return 1;
    if (v1_client_rejects_shifted_synack_without_side_effects() != 0)
        return 1;
    if (stale_peer_syn_is_not_reused_after_local_connect() != 0)
        return 1;
    if (role_switch_isolates_delayed_old_session_packets() != 0)
        return 1;
    if (session_sequence_domain_is_bounded() != 0)
        return 1;
    if (client_restart_uses_a_new_session_incarnation() != 0)
        return 1;
    if (delayed_old_syn_cannot_restore_retired_session() != 0)
        return 1;
    if (syn_rto_retransmits_without_queue_budget_loss() != 0)
        return 1;
    if (synack_ack_loss_recovers_idempotently() != 0)
        return 1;
    if (fin_ack_loss_recovers_idempotently() != 0)
        return 1;
    if (fin_sequence_does_not_collide_with_delayed_data_ack() != 0)
        return 1;
    if (fin_retry_exhaustion_times_out_once() != 0)
        return 1;
    if (exhausted_packet_preempts_later_retransmission() != 0)
        return 1;
    if (connect_timeout_is_counted_once() != 0)
        return 1;
    if (heartbeat_timeout_is_counted_once() != 0)
        return 1;
    if (configuration_is_limited_to_static_capacity() != 0)
        return 1;
    if (stale_ack_does_not_release_new_session_packet() != 0)
        return 1;
    if (session_reset_discards_stale_send_actions() != 0)
        return 1;
    if (full_action_queue_does_not_advance_protocol_state() != 0)
        return 1;
    if (closed_state_clears_data_session() != 0)
        return 1;
    if (full_reorder_prioritizes_missing_expected_packet() != 0)
        return 1;
    if (configured_reorder_limit_is_enforced() != 0)
        return 1;

    puts("PASS: RT-IPC state-machine regressions");
    return 0;
}
