/* RT-IPC protocol C implementation.
 * Ported from the Rust rt-ipc crate. Designed for bare-metal / RTOS use.
 * No dynamic allocation - all buffers are statically sized. */

#include "rt_ipc.h"
#include <string.h>

/* ── Big-endian helpers ──────────────────────────────────── */

static inline void put_be16(uint8_t *buf, uint16_t val) {
    buf[0] = (val >> 8) & 0xFF;
    buf[1] = val & 0xFF;
}

static inline void put_be32(uint8_t *buf, uint32_t val) {
    buf[0] = (val >> 24) & 0xFF;
    buf[1] = (val >> 16) & 0xFF;
    buf[2] = (val >> 8) & 0xFF;
    buf[3] = val & 0xFF;
}

static inline void put_be64(uint8_t *buf, uint64_t val) {
    put_be32(buf, (uint32_t)(val >> 32));
    put_be32(buf + 4, (uint32_t)val);
}

static inline uint16_t get_be16(const uint8_t *buf) {
    return ((uint16_t)buf[0] << 8) | buf[1];
}

static inline uint32_t get_be32(const uint8_t *buf) {
    return ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) |
           ((uint32_t)buf[2] << 8) | buf[3];
}

static inline uint64_t get_be64(const uint8_t *buf) {
    return ((uint64_t)get_be32(buf) << 32) | get_be32(buf + 4);
}

/* ── CRC16-CCITT (poly 0x1021) ───────────────────────────── */

#define CRC16_STEP(value)                                                   \
    ((uint16_t)(((value) & 0x8000U) != 0                                   \
                    ? (((uint16_t)(value) << 1) ^ 0x1021U)                 \
                    : ((uint16_t)(value) << 1)))
#define CRC16_STEP_2(value) CRC16_STEP(CRC16_STEP(value))
#define CRC16_STEP_4(value) CRC16_STEP_2(CRC16_STEP_2(value))
#define CRC16_STEP_8(value) CRC16_STEP_4(CRC16_STEP_4(value))
#define CRC16_ENTRY(byte) CRC16_STEP_8((uint16_t)(byte) << 8)
#define CRC16_ENTRIES_16(base)                                              \
    CRC16_ENTRY((base) + 0), CRC16_ENTRY((base) + 1),                      \
    CRC16_ENTRY((base) + 2), CRC16_ENTRY((base) + 3),                      \
    CRC16_ENTRY((base) + 4), CRC16_ENTRY((base) + 5),                      \
    CRC16_ENTRY((base) + 6), CRC16_ENTRY((base) + 7),                      \
    CRC16_ENTRY((base) + 8), CRC16_ENTRY((base) + 9),                      \
    CRC16_ENTRY((base) + 10), CRC16_ENTRY((base) + 11),                    \
    CRC16_ENTRY((base) + 12), CRC16_ENTRY((base) + 13),                    \
    CRC16_ENTRY((base) + 14), CRC16_ENTRY((base) + 15)
#define CRC16_ENTRIES_64(base)                                              \
    CRC16_ENTRIES_16((base) + 0), CRC16_ENTRIES_16((base) + 16),           \
    CRC16_ENTRIES_16((base) + 32), CRC16_ENTRIES_16((base) + 48)

static const uint16_t crc16_table[256] = {
    CRC16_ENTRIES_64(0),
    CRC16_ENTRIES_64(64),
    CRC16_ENTRIES_64(128),
    CRC16_ENTRIES_64(192),
};

#undef CRC16_ENTRIES_64
#undef CRC16_ENTRIES_16
#undef CRC16_ENTRY
#undef CRC16_STEP_8
#undef CRC16_STEP_4
#undef CRC16_STEP_2
#undef CRC16_STEP

static uint16_t crc16_update(uint16_t crc, const uint8_t *data, size_t len) {
    for (size_t index = 0; index < len; index++) {
        uint8_t table_index = (uint8_t)(crc >> 8) ^ data[index];
        crc = (uint16_t)((crc << 8) ^ crc16_table[table_index]);
    }
    return crc;
}

uint16_t rtipc_crc16(const void *data, size_t len) {
    return crc16_update(0xffff, (const uint8_t *)data, len);
}

uint16_t rtipc_crc16_continue(uint16_t init, const void *data, size_t len) {
    return crc16_update(init, (const uint8_t *)data, len);
}

/* ── Header serialization ────────────────────────────────── */

void rtipc_header_serialize(const rtipc_header_t *hdr, uint8_t *out) {
    out[0] = hdr->version;
    out[1] = hdr->msg_type;
    put_be16(out + 2, hdr->payload_len);
    put_be32(out + 4, hdr->seq_num);
    put_be64(out + 8, hdr->session_id);
    put_be16(out + 16, hdr->error_code);
    put_be16(out + 18, hdr->checksum);
}

int rtipc_header_parse(const uint8_t *buf, size_t len, rtipc_header_t *out) {
    if (len < RTIPC_HEADER_SIZE) return -1;
    out->version     = buf[0];
    out->msg_type    = buf[1];
    out->payload_len = get_be16(buf + 2);
    out->seq_num     = get_be32(buf + 4);
    out->session_id  = get_be64(buf + 8);
    out->error_code  = get_be16(buf + 16);
    out->checksum    = get_be16(buf + 18);
    return 0;
}

/* ── Packet build / verify ───────────────────────────────── */

size_t rtipc_build_packet(rtipc_header_t *hdr,
                          const void *payload, size_t payload_len,
                          uint8_t *out_buf, size_t out_size) {
    if (hdr == NULL || out_buf == NULL || payload_len > RTIPC_MAX_PAYLOAD ||
        (payload_len > 0 && payload == NULL))
        return 0;
    size_t total = RTIPC_HEADER_SIZE + payload_len;
    if (out_size < total) return 0;

    hdr->payload_len = (uint16_t)payload_len;

    /* Compute CRC over header (checksum=0) + payload */
    rtipc_header_t tmp = *hdr;
    tmp.checksum = 0;
    uint8_t hdr_bytes[RTIPC_HEADER_SIZE];
    rtipc_header_serialize(&tmp, hdr_bytes);
    uint16_t crc = rtipc_crc16(hdr_bytes, RTIPC_HEADER_SIZE);
    if (payload_len > 0) {
        crc = rtipc_crc16_continue(crc, payload, payload_len);
    }
    hdr->checksum = crc;

    /* Write to output */
    rtipc_header_serialize(hdr, out_buf);
    if (payload_len > 0) {
        memcpy(out_buf + RTIPC_HEADER_SIZE, payload, payload_len);
    }
    return total;
}

bool rtipc_verify_packet(const rtipc_header_t *hdr, const void *payload, size_t payload_len) {
    rtipc_header_t tmp = *hdr;
    uint16_t received = tmp.checksum;
    tmp.checksum = 0;
    uint8_t hdr_bytes[RTIPC_HEADER_SIZE];
    rtipc_header_serialize(&tmp, hdr_bytes);
    uint16_t crc = rtipc_crc16(hdr_bytes, RTIPC_HEADER_SIZE);
    if (payload_len > 0) {
        crc = rtipc_crc16_continue(crc, payload, payload_len);
    }
    return crc == received;
}

/* ── Config ──────────────────────────────────────────────── */

void rtipc_config_default(rtipc_config_t *cfg) {
    cfg->heartbeat_interval_ms     = 1000;
    cfg->heartbeat_timeout_ms      = 5000;
    cfg->connect_timeout_ms        = 3000;
    cfg->rto_ms                    = 500;
    cfg->max_retries               = 3;
    cfg->send_window               = 64;
    cfg->reorder_buf_size          = 64;
    cfg->auto_reconnect            = false;
    cfg->reconnect_initial_delay_ms = 500;
    cfg->reconnect_max_delay_ms    = 10000;
    cfg->session_id_seed           = 0;
}

/* ── Sequence number helpers ─────────────────────────────── */

/* Returns true if a is "before" b in sequence space. */
static bool seq_before(uint32_t a, uint32_t b) {
    int32_t diff = (int32_t)(b - a);
    return diff > 0;
}

static bool seq_before_or_eq(uint32_t a, uint32_t b) {
    return a == b || seq_before(a, b);
}

static uint32_t later_seq(uint32_t first, uint32_t second) {
    return seq_before(first, second) ? second : first;
}

static void advance_session_floor(rtipc_connection_t *conn,
                                  uint32_t candidate) {
    conn->next_session_seq = later_seq(conn->next_session_seq, candidate);
}

static uint32_t session_end_sequence(const rtipc_connection_t *conn) {
    return conn->session_seq + RTIPC_SESSION_SEQUENCE_SPAN;
}

static bool sequence_available_for_regular_send(
    const rtipc_connection_t *conn, uint32_t sequence) {
    if (!conn->session_seq_valid)
        return true;
    return seq_before(sequence, session_end_sequence(conn) - 1);
}

/* ── Action queue ────────────────────────────────────────── */

static rtipc_action_t *action_reserve(rtipc_connection_t *conn,
                                      uint32_t *slot_out) {
    if (conn->action_count >= RTIPC_ACTION_QUEUE_CAPACITY)
        return NULL;

    uint32_t slot = (conn->action_idx + conn->action_count) %
                    RTIPC_ACTION_QUEUE_CAPACITY;
    rtipc_action_t *a = &conn->actions[slot];
    conn->action_count++;
    memset(a, 0, sizeof(*a));
    if (slot_out != NULL)
        *slot_out = slot;
    return a;
}

static bool defer_lifecycle_action(rtipc_connection_t *conn,
                                   rtipc_action_type_t type,
                                   uint64_t delay_ms) {
    if (conn->deferred_lifecycle_count >=
        RTIPC_LIFECYCLE_ACTION_CAPACITY)
        return false;

    rtipc_action_t *action =
        &conn->deferred_lifecycle[conn->deferred_lifecycle_count++];
    memset(action, 0, sizeof(*action));
    action->type = type;
    action->delay_ms = delay_ms;
    return true;
}

static bool push_lifecycle_action(rtipc_connection_t *conn,
                                  rtipc_action_type_t type,
                                  uint64_t delay_ms) {
    rtipc_action_t *a = action_reserve(conn, NULL);
    if (a == NULL)
        return defer_lifecycle_action(conn, type, delay_ms);
    a->type = type;
    a->delay_ms = delay_ms;
    return true;
}

static bool action_push(rtipc_connection_t *conn,
                        rtipc_action_type_t type) {
    return push_lifecycle_action(conn, type, 0);
}

static bool action_bundle_available(const rtipc_connection_t *conn,
                                    uint32_t send_actions,
                                    uint32_t lifecycle_actions) {
    uint32_t main_free = RTIPC_ACTION_QUEUE_CAPACITY - conn->action_count;
    uint32_t deferred_free = RTIPC_LIFECYCLE_ACTION_CAPACITY -
                             conn->deferred_lifecycle_count;

    if (send_actions > main_free)
        return false;
    main_free -= send_actions;
    return lifecycle_actions <= main_free + deferred_free;
}

static bool push_send_action(rtipc_connection_t *conn, uint8_t *data,
                             size_t data_len) {
    rtipc_action_t *a = action_reserve(conn, NULL);
    if (a == NULL)
        return false;
    a->type = RTIPC_ACTION_SEND;
    a->data = data;
    a->data_len = data_len;
    return true;
}

static void discard_send_actions_for_data(rtipc_connection_t *conn,
                                          const uint8_t *data) {
    uint32_t retained = 0;

    for (uint32_t offset = 0; offset < conn->action_count; offset++) {
        uint32_t source = (conn->action_idx + offset) %
                          RTIPC_ACTION_QUEUE_CAPACITY;
        if (conn->actions[source].type == RTIPC_ACTION_SEND &&
            conn->actions[source].data == data)
            continue;

        uint32_t destination = (conn->action_idx + retained) %
                               RTIPC_ACTION_QUEUE_CAPACITY;
        if (destination != source)
            conn->actions[destination] = conn->actions[source];
        retained++;
    }
    conn->action_count = retained;
}

static bool preserve_session_send_action(
    const rtipc_connection_t *conn, const rtipc_action_t *action,
    const uint8_t *preserved_control_data) {
    if (action->type != RTIPC_ACTION_SEND)
        return true;
    if (preserved_control_data != NULL &&
        action->data == preserved_control_data)
        return true;
    return conn->control_pending.active &&
           action->data == conn->control_pending.data;
}

static void discard_session_send_actions(
    rtipc_connection_t *conn, const uint8_t *preserved_control_data) {
    uint32_t retained = 0;

    for (uint32_t offset = 0; offset < conn->action_count; offset++) {
        uint32_t source = (conn->action_idx + offset) %
                          RTIPC_ACTION_QUEUE_CAPACITY;
        if (!preserve_session_send_action(conn, &conn->actions[source],
                                          preserved_control_data))
            continue;

        uint32_t destination = (conn->action_idx + retained) %
                               RTIPC_ACTION_QUEUE_CAPACITY;
        if (destination != source)
            conn->actions[destination] = conn->actions[source];
        retained++;
    }
    conn->action_count = retained;
}

const rtipc_action_t *rtipc_action_next(rtipc_connection_t *conn) {
    while (conn->deferred_lifecycle_count > 0 &&
           conn->action_count < RTIPC_ACTION_QUEUE_CAPACITY) {
        rtipc_action_t saved = conn->deferred_lifecycle[0];
        rtipc_action_t *action = action_reserve(conn, NULL);
        if (action == NULL)
            break;
        *action = saved;
        conn->deferred_lifecycle_count--;
        if (conn->deferred_lifecycle_count > 0) {
            memmove(&conn->deferred_lifecycle[0],
                    &conn->deferred_lifecycle[1],
                    conn->deferred_lifecycle_count *
                        sizeof(conn->deferred_lifecycle[0]));
        }
    }
    if (conn->action_count == 0)
        return NULL;

    const rtipc_action_t *action = &conn->actions[conn->action_idx];
    conn->action_idx = (conn->action_idx + 1) %
                       RTIPC_ACTION_QUEUE_CAPACITY;
    conn->action_count--;
    return action;
}

bool rtipc_action_defer(rtipc_connection_t *conn,
                        const rtipc_action_t *action) {
    if (action == NULL)
        return false;

    rtipc_action_t saved = *action;
    rtipc_action_t *deferred = action_reserve(conn, NULL);
    if (deferred == NULL)
        return false;
    *deferred = saved;
    return true;
}

void rtipc_action_clear(rtipc_connection_t *conn) {
    /* Integration loops call this only after draining pending actions. Do not
     * clear implicitly in on_recv/tick/send: those calls queue new work and
     * must not erase a DELIVER event that the caller has not consumed yet.
     * This is the sole release point for queued DELIVER backing slots. */
    conn->action_count = 0;
    conn->action_idx = 0;
    conn->deferred_lifecycle_count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (conn->reorder_buf[i].delivery_queued) {
            conn->reorder_buf[i].delivery_queued = false;
            conn->reorder_buf[i].in_use = false;
        }
    }
}

rtipc_stats_t rtipc_connection_stats(const rtipc_connection_t *conn) {
    return conn->stats;
}

/* ── Internal: build and push a control packet ───────────── */

static bool push_control_packet_with_slot(rtipc_connection_t *conn,
                                          rtipc_msg_type_t msg_type,
                                          uint32_t seq,
                                          uint64_t session_id,
                                          uint32_t *slot_out) {
    rtipc_header_t hdr = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .session_id = session_id,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };
    uint32_t slot;
    rtipc_action_t *a = action_reserve(conn, &slot);
    if (a == NULL)
        return false;

    size_t n = rtipc_build_packet(&hdr, NULL, 0,
                                  conn->control_buf[slot],
                                  sizeof(conn->control_buf[slot]));
    if (n == 0) {
        conn->action_count--;
        return false;
    }
    a->type = RTIPC_ACTION_SEND;
    a->data = conn->control_buf[slot];
    a->data_len = n;
    if (slot_out != NULL)
        *slot_out = slot;
    return true;
}

static bool push_control_packet(rtipc_connection_t *conn,
                                rtipc_msg_type_t msg_type, uint32_t seq) {
    return push_control_packet_with_slot(conn, msg_type, seq,
                                         conn->session_id, NULL);
}

static void rewrite_control_packet(rtipc_connection_t *conn, uint32_t slot,
                                   rtipc_msg_type_t msg_type, uint32_t seq) {
    rtipc_header_t header = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .session_id = conn->session_id,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };
    rtipc_build_packet(&header, NULL, 0, conn->control_buf[slot],
                       sizeof(conn->control_buf[slot]));
}

static bool begin_control_pending(rtipc_connection_t *conn,
                                  rtipc_msg_type_t msg_type, uint32_t seq,
                                  uint64_t session_id, uint64_t now_ms) {
    if (conn->control_pending.active)
        return false;

    rtipc_header_t header = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .session_id = session_id,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };
    size_t packet_len = rtipc_build_packet(
        &header, NULL, 0, conn->control_pending.data,
        sizeof(conn->control_pending.data));
    if (packet_len == 0 ||
        !push_send_action(conn, conn->control_pending.data, packet_len))
        return false;

    conn->control_pending.data_len = packet_len;
    conn->control_pending.msg_type = msg_type;
    conn->control_pending.seq = seq;
    conn->control_pending.sent_at_ms = now_ms;
    conn->control_pending.retries = 0;
    conn->control_pending.active = true;
    advance_session_floor(conn, seq + 1);
    return true;
}

static void clear_control_pending(rtipc_connection_t *conn) {
    discard_send_actions_for_data(conn, conn->control_pending.data);
    conn->control_pending.active = false;
}

static bool resend_control_pending(rtipc_connection_t *conn,
                                   uint64_t now_ms, bool consume_retry) {
    if (!conn->control_pending.active ||
        !push_send_action(conn, conn->control_pending.data,
                          conn->control_pending.data_len))
        return false;

    if (consume_retry) {
        conn->control_pending.retries++;
        conn->control_pending.sent_at_ms = now_ms;
        conn->stats.retransmissions++;
    }
    return true;
}

static bool push_next_control_packet(rtipc_connection_t *conn,
                                     rtipc_msg_type_t msg_type,
                                     uint32_t *seq_out) {
    uint32_t seq = conn->control_seq;
    if (!sequence_available_for_regular_send(conn, seq))
        return false;
    if (!push_control_packet(conn, msg_type, seq))
        return false;

    conn->control_seq++;
    advance_session_floor(conn, conn->control_seq);
    if (seq_out != NULL)
        *seq_out = seq;
    return true;
}

/* ── Connection lifecycle ────────────────────────────────── */

void rtipc_connection_init(rtipc_connection_t *conn, const rtipc_config_t *cfg) {
    memset(conn, 0, sizeof(*conn));
    conn->config = *cfg;
    if (conn->config.send_window > RTIPC_SEND_WINDOW)
        conn->config.send_window = RTIPC_SEND_WINDOW;
    if (conn->config.reorder_buf_size > RTIPC_SEND_WINDOW)
        conn->config.reorder_buf_size = RTIPC_SEND_WINDOW;
    conn->state = RTIPC_STATE_CLOSED;
    conn->control_seq = 0x80000000;
    conn->next_session_seq = conn->control_seq;
    conn->next_session_id = conn->config.session_id_seed;
    conn->last_acked = 0xFFFFFFFF;
}

/* Reset protocol state while retaining only the current transition's SEND. */
static void reset_data_session(rtipc_connection_t *conn,
                               const uint8_t *preserved_control_data) {
    /* DELIVER/lifecycle actions survive. SEND actions belong to the old
     * generation unless backed by active control-pending state or explicitly
     * preserved by the transition that admitted them. */
    discard_session_send_actions(conn, preserved_control_data);
    conn->send_seq = 0;
    conn->pending_count = 0;
    conn->last_acked = 0xFFFFFFFF;
    conn->expected_seq = 0;
    conn->reorder_count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++)
        conn->pending[i].in_use = false;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->reorder_buf[i].delivery_queued)
            conn->reorder_buf[i].in_use = false;
    }
}

static void start_data_session(rtipc_connection_t *conn, uint32_t initial_seq,
                               uint64_t session_id,
                               const uint8_t *preserved_control_data) {
    reset_data_session(conn, preserved_control_data);
    conn->send_seq = initial_seq;
    conn->expected_seq = initial_seq;
    conn->session_seq = initial_seq;
    conn->session_seq_valid = true;
    conn->session_id = session_id;
    advance_session_floor(conn, initial_seq + 1);
}

static bool session_id_is_retired(const rtipc_connection_t *conn,
                                  uint64_t session_id) {
    for (uint32_t index = 0; index < conn->retired_session_count; index++) {
        if (conn->retired_session_ids[index] == session_id)
            return true;
    }
    return false;
}

static void retire_current_session(rtipc_connection_t *conn) {
    if (!conn->session_seq_valid ||
        session_id_is_retired(conn, conn->session_id))
        return;

    if (conn->retired_session_count < RTIPC_RETIRED_SESSION_CAPACITY) {
        conn->retired_session_ids[conn->retired_session_count++] =
            conn->session_id;
        return;
    }

    conn->retired_session_ids[conn->retired_session_next] = conn->session_id;
    conn->retired_session_next =
        (conn->retired_session_next + 1) % RTIPC_RETIRED_SESSION_CAPACITY;
}

static bool enter_closed(rtipc_connection_t *conn,
                         const uint8_t *preserved_control_data) {
    if (!action_bundle_available(conn, 0, 1) ||
        !action_push(conn, RTIPC_ACTION_DISCONNECTED))
        return false;
    retire_current_session(conn);
    reset_data_session(conn, preserved_control_data);
    conn->state = RTIPC_STATE_CLOSED;
    return true;
}

void rtipc_connection_reset(rtipc_connection_t *conn) {
    retire_current_session(conn);
    clear_control_pending(conn);
    reset_data_session(conn, NULL);
    memset(&conn->stats, 0, sizeof(conn->stats));
    conn->state = RTIPC_STATE_CLOSED;
    conn->last_hb_sent_ms = 0;
    conn->last_hb_recv_ms = 0;
    conn->connect_attempt_ms = 0;
    conn->reconnect_deadline_ms = 0;
    conn->reconnect_attempts = 0;
    /* Keep control_seq monotonic across an explicit reset so delayed packets
     * from the previous session cannot share the next session's sequence
     * space. connection_init() establishes the initial value. */
    conn->session_seq_valid = false;
    conn->peer_syn_seq_valid = false;
    conn->peer_fin_seq_valid = false;
}

static bool enter_reconnecting_with_actions(
    rtipc_connection_t *conn, uint64_t now_ms,
    const uint8_t *preserved_control_data) {
    uint32_t reconnect_attempts = conn->reconnect_attempts + 1;
    uint64_t base = conn->config.reconnect_initial_delay_ms;
    uint64_t maxd = conn->config.reconnect_max_delay_ms;
    uint32_t shift = reconnect_attempts;
    if (shift > 10) shift = 10;
    uint64_t exp = (uint64_t)1 << shift;
    uint64_t delay = base * exp;
    if (delay > maxd) delay = maxd;
    if (!action_bundle_available(conn, 0, 2))
        return false;

    uint32_t saved_action_count = conn->action_count;
    uint32_t saved_deferred_count = conn->deferred_lifecycle_count;
    if (!action_push(conn, RTIPC_ACTION_DISCONNECTED) ||
        !push_lifecycle_action(conn, RTIPC_ACTION_RECONNECT, delay)) {
        conn->action_count = saved_action_count;
        conn->deferred_lifecycle_count = saved_deferred_count;
        return false;
    }

    retire_current_session(conn);
    reset_data_session(conn, preserved_control_data);
    conn->reconnect_attempts = reconnect_attempts;
    conn->reconnect_deadline_ms = now_ms + delay;
    conn->state = RTIPC_STATE_RECONNECTING;
    return true;
}

void rtipc_connection_connect(rtipc_connection_t *conn, uint64_t now_ms) {
    if (conn->state != RTIPC_STATE_CLOSED && conn->state != RTIPC_STATE_RECONNECTING)
        return;

    uint32_t seq = later_seq(conn->control_seq, conn->next_session_seq);
    uint64_t session_id = conn->next_session_id++;
    if (conn->session_seq_valid) {
        uint32_t isolated_seq = session_end_sequence(conn);
        seq = later_seq(seq, isolated_seq);
    }
    if (!begin_control_pending(conn, RTIPC_MSG_SYN, seq, session_id, now_ms))
        return;
    conn->peer_syn_seq_valid = false;
    conn->peer_fin_seq_valid = false;
    start_data_session(conn, seq, session_id, NULL);
    conn->control_seq = seq + 1;
    conn->connect_attempt_ms = now_ms;
    conn->state = RTIPC_STATE_SYN_SENT;
}

void rtipc_connection_force_disconnect(rtipc_connection_t *conn, uint64_t now_ms) {
    if (conn->state == RTIPC_STATE_CLOSED || conn->state == RTIPC_STATE_RECONNECTING)
        return;
    if (conn->config.auto_reconnect) {
        if (!enter_reconnecting_with_actions(conn, now_ms, NULL))
            return;
    } else {
        if (!enter_closed(conn, NULL))
            return;
    }
    clear_control_pending(conn);
}

void rtipc_connection_disconnect(rtipc_connection_t *conn, uint64_t now_ms) {
    if (conn->state == RTIPC_STATE_CLOSED ||
        conn->state == RTIPC_STATE_SHUTDOWN)
        return;
    uint32_t seq = later_seq(conn->control_seq, conn->next_session_seq);
    if (!begin_control_pending(conn, RTIPC_MSG_FIN, seq, conn->session_id,
                               now_ms))
        return;
    conn->control_seq = seq + 1;
    reset_data_session(conn, NULL);
    conn->state = RTIPC_STATE_SHUTDOWN;
}

bool rtipc_connection_is_connected(const rtipc_connection_t *conn) {
    return conn->state == RTIPC_STATE_CONNECTED;
}

/* ── Sender helpers ──────────────────────────────────────── */

static int sender_find_free(rtipc_connection_t *conn) {
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->pending[i].in_use)
            return i;
    }
    return -1;
}

static bool sender_ack(rtipc_connection_t *conn, uint32_t seq) {
    if (conn->pending_count == 0)
        return false;

    uint32_t highest_sent = conn->send_seq - 1;
    if (seq_before(highest_sent, seq))
        return false;

    bool released = false;
    /* Remove all pending packets with seq <= ack_seq */
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (conn->pending[i].in_use && seq_before_or_eq(conn->pending[i].seq, seq)) {
            conn->pending[i].in_use = false;
            if (conn->pending_count > 0)
                conn->pending_count--;
            released = true;
        }
    }
    if (released)
        conn->last_acked = seq;
    return released;
}

static uint32_t sender_in_flight(const rtipc_connection_t *conn) {
    uint32_t count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++)
        if (conn->pending[i].in_use) count++;
    return count;
}

/* ── Receiver helpers ────────────────────────────────────── */

static int receiver_find_seq(const rtipc_connection_t *conn, uint32_t seq) {
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (conn->reorder_buf[i].in_use &&
            !conn->reorder_buf[i].delivery_queued &&
            conn->reorder_buf[i].seq == seq)
            return i;
    }
    return -1;
}

static int receiver_find_free(const rtipc_connection_t *conn) {
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->reorder_buf[i].in_use)
            return i;
    }
    return -1;
}

static int receiver_find_farthest_future(const rtipc_connection_t *conn) {
    int farthest = -1;

    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->reorder_buf[i].in_use ||
            conn->reorder_buf[i].delivery_queued ||
            conn->reorder_buf[i].seq == conn->expected_seq)
            continue;
        if (farthest < 0 ||
            seq_before(conn->reorder_buf[farthest].seq,
                       conn->reorder_buf[i].seq))
            farthest = i;
    }
    return farthest;
}

static bool queue_delivery(rtipc_connection_t *conn, int slot) {
    rtipc_action_t *a = action_reserve(conn, NULL);
    if (a == NULL)
        return false;

    a->type = RTIPC_ACTION_DELIVER;
    a->payload = conn->reorder_buf[slot].payload;
    a->payload_len = conn->reorder_buf[slot].payload_len;
    a->msg_type = conn->reorder_buf[slot].msg_type;
    conn->reorder_buf[slot].delivery_queued = true;
    if (conn->reorder_count > 0)
        conn->reorder_count--;
    return true;
}

static void receiver_flush_contiguous(rtipc_connection_t *conn) {
    while (true) {
        int slot = receiver_find_seq(conn, conn->expected_seq);
        if (slot < 0 || !queue_delivery(conn, slot))
            return;
        conn->expected_seq++;
    }
}

static void receiver_receive(rtipc_connection_t *conn, uint32_t seq,
                              const uint8_t *payload, size_t payload_len,
                              uint8_t msg_type) {
    /* Duplicate check */
    if (seq_before(seq, conn->expected_seq)) {
        /* Duplicate - still need ACK */
        conn->stats.rx_duplicates++;
        return;
    }

    int existing = receiver_find_seq(conn, seq);
    if (existing >= 0) {
        conn->stats.rx_duplicates++;
        receiver_flush_contiguous(conn);
        return;
    }

    if (seq != conn->expected_seq &&
        conn->reorder_count >= conn->config.reorder_buf_size)
        return;

    int slot = receiver_find_free(conn);
    if (slot < 0) {
        if (seq != conn->expected_seq)
            return;
        slot = receiver_find_farthest_future(conn);
        if (slot < 0)
            return;
        conn->reorder_buf[slot].in_use = false;
        if (conn->reorder_count > 0)
            conn->reorder_count--;
    }

    conn->reorder_buf[slot].seq = seq;
    conn->reorder_buf[slot].payload_len = payload_len;
    conn->reorder_buf[slot].msg_type = msg_type;
    if (payload_len > 0)
        memcpy(conn->reorder_buf[slot].payload, payload, payload_len);
    conn->reorder_buf[slot].in_use = true;
    conn->reorder_buf[slot].delivery_queued = false;
    conn->reorder_count++;

    if (seq != conn->expected_seq)
        conn->stats.rx_out_of_order++;
    receiver_flush_contiguous(conn);
}

/* ── on_recv ─────────────────────────────────────────────── */

static bool valid_msg_type(uint8_t msg_type) {
    switch (msg_type) {
    case RTIPC_MSG_CTRL_CMD:
    case RTIPC_MSG_STATUS_REP:
    case RTIPC_MSG_ERROR_NOTIFY:
    case RTIPC_MSG_ACK:
    case RTIPC_MSG_SYN:
    case RTIPC_MSG_SYNACK:
    case RTIPC_MSG_HEARTBEAT:
    case RTIPC_MSG_HEARTBEAT_ACK:
    case RTIPC_MSG_FIN:
        return true;
    default:
        return false;
    }
}

static bool message_uses_session(uint8_t msg_type) {
    return msg_type != RTIPC_MSG_SYN && msg_type != RTIPC_MSG_SYNACK;
}

static bool sequence_is_in_current_session(const rtipc_connection_t *conn,
                                           uint8_t msg_type,
                                           uint32_t sequence) {
    if (!conn->session_seq_valid)
        return true;
    if (seq_before(sequence, conn->session_seq) ||
        !seq_before(sequence, session_end_sequence(conn)))
        return false;
    if (msg_type != RTIPC_MSG_FIN && msg_type != RTIPC_MSG_ACK &&
        sequence == session_end_sequence(conn) - 1)
        return false;
    return true;
}

void rtipc_connection_on_recv(rtipc_connection_t *conn,
                               const void *data, size_t len, uint64_t now_ms) {
    if (data == NULL || len < RTIPC_HEADER_SIZE) {
        conn->stats.rx_errors++;
        return;
    }

    const uint8_t *buf = (const uint8_t *)data;
    rtipc_header_t hdr;
    if (rtipc_header_parse(buf, len, &hdr) != 0) {
        conn->stats.rx_errors++;
        return;
    }

    size_t plen = hdr.payload_len;
    if (hdr.version != RTIPC_PROTOCOL_VERSION ||
        !valid_msg_type(hdr.msg_type) || plen > RTIPC_MAX_PAYLOAD ||
        len != RTIPC_HEADER_SIZE + plen) {
        conn->stats.rx_errors++;
        return;
    }

    const uint8_t *payload = buf + RTIPC_HEADER_SIZE;
    if (!rtipc_verify_packet(&hdr, payload, plen)) {
        conn->stats.rx_errors++;
        return;
    }
    if (hdr.msg_type != RTIPC_MSG_SYN && conn->session_seq_valid &&
        hdr.session_id != conn->session_id)
        return;
    if (message_uses_session(hdr.msg_type) &&
        !sequence_is_in_current_session(conn, hdr.msg_type, hdr.seq_num))
        return;

    switch (hdr.msg_type) {
    case RTIPC_MSG_SYN: {
        if (session_id_is_retired(conn, hdr.session_id))
            break;
        if (conn->state == RTIPC_STATE_CONNECTED &&
            conn->peer_syn_seq_valid &&
            conn->peer_syn_seq == conn->session_seq &&
            hdr.seq_num == conn->session_seq &&
            hdr.session_id == conn->session_id) {
            push_control_packet(conn, RTIPC_MSG_SYNACK, hdr.seq_num);
            break;
        }
        if (conn->control_pending.active)
            break;
        if (conn->session_seq_valid && hdr.session_id == conn->session_id) {
            if (seq_before(hdr.seq_num, conn->session_seq))
                break;
        }
        bool replaced_connected_session =
            conn->state == RTIPC_STATE_CONNECTED;
        uint32_t lifecycle_actions = replaced_connected_session ? 2 : 1;
        /* The SYN sequence is the data-session initial sequence. SYNACK echoes
         * it so delayed control/data packets remain in the old sequence
         * space and cannot affect a later session. */
        uint32_t synack_slot;
        if (!action_bundle_available(conn, 1, lifecycle_actions))
            break;
        if (!push_control_packet_with_slot(conn, RTIPC_MSG_SYNACK, hdr.seq_num,
                                           hdr.session_id, &synack_slot))
            break;
        const uint8_t *synack = conn->control_buf[synack_slot];
        if (replaced_connected_session)
            retire_current_session(conn);
        start_data_session(conn, hdr.seq_num, hdr.session_id, synack);
        conn->peer_syn_seq = hdr.seq_num;
        conn->peer_syn_seq_valid = true;
        conn->peer_fin_seq_valid = false;
        conn->control_seq = later_seq(conn->control_seq, hdr.seq_num + 1);
        conn->state = RTIPC_STATE_CONNECTED;
        conn->last_hb_sent_ms = now_ms;
        conn->last_hb_recv_ms = now_ms;
        if (replaced_connected_session &&
            !action_push(conn, RTIPC_ACTION_DISCONNECTED))
            break;
        if (!action_push(conn, RTIPC_ACTION_CONNECTED))
            break;
        break;
    }
    case RTIPC_MSG_SYNACK: {
        if (conn->state == RTIPC_STATE_SYN_SENT &&
            conn->session_seq_valid &&
            conn->control_pending.active &&
            conn->control_pending.msg_type == RTIPC_MSG_SYN &&
            hdr.seq_num == conn->control_pending.seq &&
            action_bundle_available(conn, 0, 1) &&
            action_push(conn, RTIPC_ACTION_CONNECTED)) {
            clear_control_pending(conn);
            start_data_session(conn, hdr.seq_num, hdr.session_id, NULL);
            conn->control_seq = later_seq(conn->control_seq,
                                          hdr.seq_num + 1);
            conn->state = RTIPC_STATE_CONNECTED;
            conn->last_hb_recv_ms = now_ms;
            conn->last_hb_sent_ms = now_ms;
            conn->reconnect_attempts = 0;
        }
        break;
    }
    case RTIPC_MSG_HEARTBEAT: {
        if (conn->state != RTIPC_STATE_CONNECTED ||
            !push_control_packet(conn, RTIPC_MSG_HEARTBEAT_ACK,
                                 hdr.seq_num))
            break;
        conn->last_hb_recv_ms = now_ms;
        advance_session_floor(conn, hdr.seq_num + 1);
        break;
    }
    case RTIPC_MSG_HEARTBEAT_ACK: {
        if (conn->state != RTIPC_STATE_CONNECTED)
            break;
        conn->last_hb_recv_ms = now_ms;
        advance_session_floor(conn, hdr.seq_num + 1);
        break;
    }
    case RTIPC_MSG_FIN: {
        if (conn->peer_fin_seq_valid && hdr.seq_num == conn->peer_fin_seq) {
            push_control_packet(conn, RTIPC_MSG_ACK, hdr.seq_num);
            break;
        }
        uint32_t ack_slot;
        uint32_t lifecycle_actions = conn->config.auto_reconnect ? 2 : 1;
        if (conn->state != RTIPC_STATE_CONNECTED ||
            !action_bundle_available(conn, 1, lifecycle_actions) ||
            !push_control_packet_with_slot(conn, RTIPC_MSG_ACK, hdr.seq_num,
                                           conn->session_id, &ack_slot))
            break;
        const uint8_t *fin_ack = conn->control_buf[ack_slot];
        conn->peer_fin_seq = hdr.seq_num;
        conn->peer_fin_seq_valid = true;
        advance_session_floor(conn, hdr.seq_num + 1);
        if (conn->config.auto_reconnect) {
            (void)enter_reconnecting_with_actions(conn, now_ms, fin_ack);
        } else {
            (void)enter_closed(conn, fin_ack);
        }
        break;
    }
    case RTIPC_MSG_ACK: {
        if (conn->state == RTIPC_STATE_SHUTDOWN &&
                   conn->control_pending.active &&
                   conn->control_pending.msg_type == RTIPC_MSG_FIN &&
                   hdr.seq_num == conn->control_pending.seq &&
                   enter_closed(conn, NULL)) {
            clear_control_pending(conn);
            conn->stats.acks_received++;
        } else if (conn->state == RTIPC_STATE_CONNECTED &&
                   sender_ack(conn, hdr.seq_num)) {
            conn->stats.acks_received++;
            advance_session_floor(conn, hdr.seq_num + 1);
        }
        break;
    }
    case RTIPC_MSG_CTRL_CMD:
    case RTIPC_MSG_STATUS_REP:
    case RTIPC_MSG_ERROR_NOTIFY: {
        if (conn->state != RTIPC_STATE_CONNECTED)
            return;
        uint32_t ack_slot;
        if (!push_control_packet_with_slot(conn, RTIPC_MSG_ACK,
                                           conn->expected_seq - 1,
                                           conn->session_id,
                                           &ack_slot))
            return;
        conn->last_hb_recv_ms = now_ms;
        conn->stats.rx_packets++;
        conn->stats.rx_bytes += (uint32_t)plen;
        advance_session_floor(conn, hdr.seq_num + 1);

        /* Process through receiver */
        receiver_receive(conn, hdr.seq_num, payload, plen, hdr.msg_type);

        /* Send ACK with highest contiguously delivered seq (expected - 1) */
        uint32_t ack_seq = conn->expected_seq - 1;
        rewrite_control_packet(conn, ack_slot, RTIPC_MSG_ACK, ack_seq);
        break;
    }
    default:
        break;
    }
}

/* ── send ────────────────────────────────────────────────── */

rtipc_send_result_t rtipc_connection_send(rtipc_connection_t *conn,
                                          rtipc_msg_type_t msg_type,
                                          const void *payload,
                                          size_t payload_len,
                                          uint64_t now_ms) {
    if (conn->state != RTIPC_STATE_CONNECTED) return RTIPC_SEND_INVALID;
    if (sender_in_flight(conn) >= conn->config.send_window)
        return RTIPC_SEND_WOULD_BLOCK;
    if (payload_len > RTIPC_MAX_PAYLOAD) return RTIPC_SEND_INVALID;
    if (conn->action_count >= RTIPC_ACTION_QUEUE_CAPACITY)
        return RTIPC_SEND_WOULD_BLOCK;

    /* Find free pending slot */
    int slot = sender_find_free(conn);
    if (slot < 0) return RTIPC_SEND_WOULD_BLOCK;

    uint32_t seq = conn->send_seq;
    if (!sequence_available_for_regular_send(conn, seq))
        return RTIPC_SEND_WOULD_BLOCK;

    rtipc_header_t hdr = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .session_id = conn->session_id,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };

    size_t n = rtipc_build_packet(&hdr, payload, payload_len,
                                  conn->pending[slot].data,
                                  sizeof(conn->pending[slot].data));
    if (n == 0) return RTIPC_SEND_INVALID;

    conn->send_seq++;
    advance_session_floor(conn, conn->send_seq);
    conn->pending[slot].data_len = n;
    conn->pending[slot].seq = seq;
    conn->pending[slot].sent_at_ms = now_ms;
    conn->pending[slot].retries = 0;
    conn->pending[slot].in_use = true;
    conn->pending_count++;
    conn->stats.tx_packets++;
    conn->stats.tx_bytes += (uint32_t)payload_len;

    push_send_action(conn, conn->pending[slot].data, n);

    return RTIPC_SEND_OK;
}

/* ── tick ────────────────────────────────────────────────── */

static void control_pending_timeout(rtipc_connection_t *conn,
                                    uint64_t now_ms) {
    rtipc_msg_type_t msg_type = conn->control_pending.msg_type;

    bool transitioned;
    if (msg_type == RTIPC_MSG_SYN && conn->config.auto_reconnect)
        transitioned = enter_reconnecting_with_actions(conn, now_ms, NULL);
    else
        transitioned = enter_closed(conn, NULL);
    if (!transitioned)
        return;
    clear_control_pending(conn);
    conn->stats.timeouts++;
}

static void tick_control_pending(rtipc_connection_t *conn, uint64_t now_ms) {
    if (!conn->control_pending.active ||
        (now_ms - conn->control_pending.sent_at_ms) < conn->config.rto_ms)
        return;

    if (conn->control_pending.retries >= conn->config.max_retries) {
        control_pending_timeout(conn, now_ms);
        return;
    }
    resend_control_pending(conn, now_ms, true);
}

void rtipc_connection_tick(rtipc_connection_t *conn, uint64_t now_ms) {
    /* Reconnecting state */
    if (conn->state == RTIPC_STATE_RECONNECTING) {
        if (now_ms >= conn->reconnect_deadline_ms) {
            rtipc_connection_connect(conn, now_ms);
        }
        return;
    }

    /* SYN_SENT timeout */
    if (conn->state == RTIPC_STATE_SYN_SENT) {
        if ((now_ms - conn->connect_attempt_ms) >= conn->config.connect_timeout_ms) {
            bool transitioned;
            if (conn->config.auto_reconnect) {
                transitioned = enter_reconnecting_with_actions(conn, now_ms,
                                                                NULL);
            } else {
                transitioned = enter_closed(conn, NULL);
            }
            if (!transitioned)
                return;
            clear_control_pending(conn);
            conn->stats.timeouts++;
            return;
        }
    }

    if (conn->state == RTIPC_STATE_SYN_SENT ||
        conn->state == RTIPC_STATE_SHUTDOWN) {
        tick_control_pending(conn, now_ms);
        return;
    }

    if (conn->state != RTIPC_STATE_CONNECTED) return;

    /* Heartbeat send */
    if ((now_ms - conn->last_hb_sent_ms) >= conn->config.heartbeat_interval_ms) {
        if (push_next_control_packet(conn, RTIPC_MSG_HEARTBEAT, NULL))
            conn->last_hb_sent_ms = now_ms;
    }

    /* Heartbeat timeout */
    if ((now_ms - conn->last_hb_recv_ms) >= conn->config.heartbeat_timeout_ms) {
        bool transitioned;
        if (conn->config.auto_reconnect) {
            transitioned = enter_reconnecting_with_actions(conn, now_ms, NULL);
        } else {
            transitioned = enter_closed(conn, NULL);
        }
        if (!transitioned)
            return;
        conn->stats.timeouts++;
        return;
    }

    /* A failed packet closes the whole data session. Detect all failures
     * before enqueueing retries that the ensuing reset would discard. Each
     * exhausted packet remains one timeout event, matching prior stats. */
    uint32_t exhausted_count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        const rtipc_pending_t *pkt = &conn->pending[i];
        if (pkt->in_use &&
            (now_ms - pkt->sent_at_ms) >= conn->config.rto_ms &&
            pkt->retries >= conn->config.max_retries)
            exhausted_count++;
    }
    if (exhausted_count > 0) {
        bool transitioned;
        if (conn->config.auto_reconnect) {
            transitioned = enter_reconnecting_with_actions(conn, now_ms, NULL);
        } else {
            transitioned = enter_closed(conn, NULL);
        }
        if (!transitioned)
            return;
        conn->stats.timeouts += exhausted_count;
        return;
    }

    /* Retransmission check */
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->pending[i].in_use)
            continue;
        rtipc_pending_t *pkt = &conn->pending[i];
        if ((now_ms - pkt->sent_at_ms) >= conn->config.rto_ms &&
            push_send_action(conn, pkt->data, pkt->data_len)) {
            pkt->retries++;
            pkt->sent_at_ms = now_ms;
            conn->stats.retransmissions++;
        }
    }
}
