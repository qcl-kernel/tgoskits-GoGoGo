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

static inline uint16_t get_be16(const uint8_t *buf) {
    return ((uint16_t)buf[0] << 8) | buf[1];
}

static inline uint32_t get_be32(const uint8_t *buf) {
    return ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16) |
           ((uint32_t)buf[2] << 8) | buf[3];
}

/* ── CRC16-CCITT lookup table (poly 0x1021) ──────────────── */

static uint16_t crc16_table[256];
static int crc16_table_inited = 0;

static void init_crc16_table(void) {
    if (crc16_table_inited) return;
    for (int i = 0; i < 256; i++) {
        uint16_t crc = (uint16_t)i << 8;
        for (int j = 0; j < 8; j++) {
            if (crc & 0x8000)
                crc = (crc << 1) ^ 0x1021;
            else
                crc <<= 1;
        }
        crc16_table[i] = crc;
    }
    crc16_table_inited = 1;
}

uint16_t rtipc_crc16(const void *data, size_t len) {
    init_crc16_table();
    const uint8_t *p = (const uint8_t *)data;
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        uint8_t idx = (uint8_t)(crc >> 8) ^ p[i];
        crc = (crc << 8) ^ crc16_table[idx];
    }
    return crc;
}

uint16_t rtipc_crc16_continue(uint16_t init, const void *data, size_t len) {
    init_crc16_table();
    const uint8_t *p = (const uint8_t *)data;
    uint16_t crc = init;
    for (size_t i = 0; i < len; i++) {
        uint8_t idx = (uint8_t)(crc >> 8) ^ p[i];
        crc = (crc << 8) ^ crc16_table[idx];
    }
    return crc;
}

/* ── Header serialization ────────────────────────────────── */

void rtipc_header_serialize(const rtipc_header_t *hdr, uint8_t *out) {
    out[0] = hdr->version;
    out[1] = hdr->msg_type;
    put_be16(out + 2, hdr->payload_len);
    put_be32(out + 4, hdr->seq_num);
    put_be16(out + 8, hdr->error_code);
    put_be16(out + 10, hdr->checksum);
}

int rtipc_header_parse(const uint8_t *buf, size_t len, rtipc_header_t *out) {
    if (len < RTIPC_HEADER_SIZE) return -1;
    out->version     = buf[0];
    out->msg_type    = buf[1];
    out->payload_len = get_be16(buf + 2);
    out->seq_num     = get_be32(buf + 4);
    out->error_code  = get_be16(buf + 8);
    out->checksum    = get_be16(buf + 10);
    return 0;
}

/* ── Packet build / verify ───────────────────────────────── */

size_t rtipc_build_packet(rtipc_header_t *hdr,
                          const void *payload, size_t payload_len,
                          uint8_t *out_buf, size_t out_size) {
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
    cfg->rto_ms                    = 20;
    cfg->max_retries               = 3;
    cfg->send_window               = 64;
    cfg->reorder_buf_size          = 64;
    cfg->auto_reconnect            = false;
    cfg->reconnect_initial_delay_ms = 500;
    cfg->reconnect_max_delay_ms    = 10000;
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

/* ── Action queue ────────────────────────────────────────── */

static void action_push(rtipc_connection_t *conn, rtipc_action_type_t type) {
    if (conn->action_count >= RTIPC_MAX_ACTIONS) return;
    rtipc_action_t *a = &conn->actions[conn->action_count++];
    memset(a, 0, sizeof(*a));
    a->type = type;
}

const rtipc_action_t *rtipc_action_next(rtipc_connection_t *conn) {
    if (conn->action_idx >= conn->action_count) return NULL;
    return &conn->actions[conn->action_idx++];
}

void rtipc_action_clear(rtipc_connection_t *conn) {
    conn->action_count = 0;
    conn->action_idx = 0;
}

/* ── Internal: build and push a control packet ───────────── */

static void push_control_packet(rtipc_connection_t *conn, rtipc_msg_type_t msg_type,
                                 uint32_t seq) {
    rtipc_header_t hdr = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };
    /* Find a temporary slot to store the serialized packet */
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->pending[i].in_use) {
            size_t n = rtipc_build_packet(&hdr, NULL, 0,
                                          conn->pending[i].data,
                                          sizeof(conn->pending[i].data));
            if (n > 0 && conn->action_count < RTIPC_MAX_ACTIONS) {
                rtipc_action_t *a = &conn->actions[conn->action_count++];
                a->type = RTIPC_ACTION_SEND;
                a->data = conn->pending[i].data;
                a->data_len = n;
            }
            return;
        }
    }
}

static uint32_t next_control_seq(rtipc_connection_t *conn) {
    uint32_t s = conn->control_seq;
    conn->control_seq++;
    return s;
}

/* ── Connection lifecycle ────────────────────────────────── */

void rtipc_connection_init(rtipc_connection_t *conn, const rtipc_config_t *cfg) {
    memset(conn, 0, sizeof(*conn));
    conn->config = *cfg;
    conn->state = RTIPC_STATE_CLOSED;
    conn->control_seq = 0x80000000;
    conn->last_acked = 0xFFFFFFFF;
}

void rtipc_connection_reset(rtipc_connection_t *conn) {
    rtipc_config_t cfg = conn->config;
    rtipc_connection_init(conn, &cfg);
}

static void enter_reconnecting(rtipc_connection_t *conn, uint64_t now_ms) {
    conn->reconnect_attempts++;
    uint64_t base = conn->config.reconnect_initial_delay_ms;
    uint64_t maxd = conn->config.reconnect_max_delay_ms;
    uint32_t shift = conn->reconnect_attempts;
    if (shift > 10) shift = 10;
    uint64_t exp = (uint64_t)1 << shift;
    uint64_t delay = base * exp;
    if (delay > maxd) delay = maxd;
    conn->reconnect_deadline_ms = now_ms + delay;
    conn->state = RTIPC_STATE_RECONNECTING;

    /* Clear sender/receiver state */
    conn->send_seq = 0;
    conn->pending_count = 0;
    conn->last_acked = 0xFFFFFFFF;
    conn->expected_seq = 0;
    conn->reorder_count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++)
        conn->pending[i].in_use = false;
    for (int i = 0; i < 64; i++)
        conn->reorder_buf[i].in_use = false;
}

void rtipc_connection_connect(rtipc_connection_t *conn, uint64_t now_ms) {
    rtipc_action_clear(conn);
    if (conn->state != RTIPC_STATE_CLOSED && conn->state != RTIPC_STATE_RECONNECTING)
        return;

    uint32_t seq = next_control_seq(conn);
    push_control_packet(conn, RTIPC_MSG_SYN, seq);
    conn->connect_attempt_ms = now_ms;
    conn->state = RTIPC_STATE_SYN_SENT;
}

void rtipc_connection_force_disconnect(rtipc_connection_t *conn, uint64_t now_ms) {
    rtipc_action_clear(conn);
    if (conn->state == RTIPC_STATE_CLOSED || conn->state == RTIPC_STATE_RECONNECTING)
        return;
    if (conn->config.auto_reconnect) {
        enter_reconnecting(conn, now_ms);
        action_push(conn, RTIPC_ACTION_DISCONNECTED);

        /* Push reconnect delay action */
        uint64_t base = conn->config.reconnect_initial_delay_ms;
        uint64_t maxd = conn->config.reconnect_max_delay_ms;
        uint32_t shift = conn->reconnect_attempts;
        if (shift > 10) shift = 10;
        uint64_t exp = (uint64_t)1 << shift;
        uint64_t delay = base * exp;
        if (delay > maxd) delay = maxd;

        if (conn->action_count < RTIPC_MAX_ACTIONS) {
            rtipc_action_t *a = &conn->actions[conn->action_count++];
            a->type = RTIPC_ACTION_RECONNECT;
            a->delay_ms = delay;
        }
    } else {
        conn->state = RTIPC_STATE_CLOSED;
        action_push(conn, RTIPC_ACTION_DISCONNECTED);
    }
}

void rtipc_connection_disconnect(rtipc_connection_t *conn, uint64_t now_ms) {
    rtipc_action_clear(conn);
    if (conn->state == RTIPC_STATE_CLOSED) return;
    uint32_t seq = next_control_seq(conn);
    push_control_packet(conn, RTIPC_MSG_FIN, seq);
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

static void sender_ack(rtipc_connection_t *conn, uint32_t seq) {
    conn->last_acked = seq;
    /* Remove all pending packets with seq <= ack_seq */
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (conn->pending[i].in_use && seq_before_or_eq(conn->pending[i].seq, seq)) {
            conn->pending[i].in_use = false;
            if (conn->pending_count > 0)
                conn->pending_count--;
        }
    }
}

static uint32_t sender_in_flight(const rtipc_connection_t *conn) {
    uint32_t count = 0;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++)
        if (conn->pending[i].in_use) count++;
    return count;
}

/* ── Receiver helpers ────────────────────────────────────── */

static void deliver_data(rtipc_connection_t *conn, const uint8_t *data, size_t len, uint8_t msg_type) {
    if (len > RTIPC_MAX_PAYLOAD) len = RTIPC_MAX_PAYLOAD;
    if (conn->action_count >= RTIPC_MAX_ACTIONS) return;
    memcpy(conn->deliver_buf, data, len);
    rtipc_action_t *a = &conn->actions[conn->action_count++];
    a->type = RTIPC_ACTION_DELIVER;
    a->payload = conn->deliver_buf;
    a->payload_len = len;
    a->msg_type = msg_type;
}

static void receiver_receive(rtipc_connection_t *conn, uint32_t seq,
                              const uint8_t *payload, size_t payload_len,
                              uint8_t msg_type) {
    /* Duplicate check */
    if (seq_before(seq, conn->expected_seq)) {
        /* Duplicate - still need ACK */
        return;
    }

    /* Check reorder buffer for existing entry */
    for (int i = 0; i < 64; i++) {
        if (conn->reorder_buf[i].in_use && conn->reorder_buf[i].seq == seq)
            return; /* duplicate in reorder buffer */
    }

    if (seq == conn->expected_seq) {
        /* In-order delivery */
        deliver_data(conn, payload, payload_len, msg_type);
        conn->expected_seq++;

        /* Check reorder buffer for subsequent packets */
        bool found = true;
        while (found) {
            found = false;
            for (int i = 0; i < 64; i++) {
                if (conn->reorder_buf[i].in_use &&
                    conn->reorder_buf[i].seq == conn->expected_seq) {
                    deliver_data(conn, conn->reorder_buf[i].payload,
                                conn->reorder_buf[i].payload_len, msg_type);
                    conn->reorder_buf[i].in_use = false;
                    conn->expected_seq++;
                    found = true;
                    break;
                }
            }
        }
    } else {
        /* Out of order - store in reorder buffer */
        for (int i = 0; i < 64; i++) {
            if (!conn->reorder_buf[i].in_use) {
                conn->reorder_buf[i].seq = seq;
                conn->reorder_buf[i].payload_len = payload_len;
                if (payload_len > 0)
                    memcpy(conn->reorder_buf[i].payload, payload, payload_len);
                conn->reorder_buf[i].in_use = true;
                conn->reorder_count++;
                return;
            }
        }
    }
}

/* ── on_recv ─────────────────────────────────────────────── */

void rtipc_connection_on_recv(rtipc_connection_t *conn,
                               const void *data, size_t len, uint64_t now_ms) {
    rtipc_action_clear(conn);

    if (len < RTIPC_HEADER_SIZE) return;

    const uint8_t *buf = (const uint8_t *)data;
    rtipc_header_t hdr;
    if (rtipc_header_parse(buf, len, &hdr) != 0) return;

    size_t plen = hdr.payload_len;
    if (RTIPC_HEADER_SIZE + plen > len) return;

    const uint8_t *payload = buf + RTIPC_HEADER_SIZE;
    if (!rtipc_verify_packet(&hdr, payload, plen)) return;

    switch (hdr.msg_type) {
    case RTIPC_MSG_SYN: {
        /* Server side: accept connection */
        if (conn->state == RTIPC_STATE_CONNECTED) {
            /* Already connected - just reply with SYNACK */
            push_control_packet(conn, RTIPC_MSG_SYNACK, next_control_seq(conn));
        } else {
            conn->expected_seq = 0;
            push_control_packet(conn, RTIPC_MSG_SYNACK, next_control_seq(conn));
            conn->state = RTIPC_STATE_CONNECTED;
            conn->last_hb_sent_ms = now_ms;
            action_push(conn, RTIPC_ACTION_CONNECTED);
        }
        conn->last_hb_recv_ms = now_ms;
        break;
    }
    case RTIPC_MSG_SYNACK: {
        if (conn->state == RTIPC_STATE_SYN_SENT) {
            conn->state = RTIPC_STATE_CONNECTED;
            conn->last_hb_recv_ms = now_ms;
            conn->last_hb_sent_ms = now_ms;
            conn->reconnect_attempts = 0;
            action_push(conn, RTIPC_ACTION_CONNECTED);
        }
        break;
    }
    case RTIPC_MSG_HEARTBEAT: {
        conn->last_hb_recv_ms = now_ms;
        push_control_packet(conn, RTIPC_MSG_HEARTBEAT_ACK, hdr.seq_num);
        break;
    }
    case RTIPC_MSG_HEARTBEAT_ACK: {
        conn->last_hb_recv_ms = now_ms;
        break;
    }
    case RTIPC_MSG_FIN: {
        if (conn->config.auto_reconnect) {
            enter_reconnecting(conn, now_ms);
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        } else {
            conn->state = RTIPC_STATE_CLOSED;
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        }
        break;
    }
    case RTIPC_MSG_ACK: {
        sender_ack(conn, hdr.seq_num);
        break;
    }
    case RTIPC_MSG_CTRL_CMD:
    case RTIPC_MSG_STATUS_REP:
    case RTIPC_MSG_ERROR_NOTIFY: {
        /* Update heartbeat timer on any data reception */
        conn->last_hb_recv_ms = now_ms;
        if (conn->state != RTIPC_STATE_CONNECTED) return;

        /* Process through receiver */
        receiver_receive(conn, hdr.seq_num, payload, plen, hdr.msg_type);

        /* Send ACK with highest contiguously delivered seq (expected - 1) */
        uint32_t ack_seq = conn->expected_seq - 1;
        push_control_packet(conn, RTIPC_MSG_ACK, ack_seq);
        break;
    }
    default:
        break;
    }
}

/* ── send ────────────────────────────────────────────────── */

int rtipc_connection_send(rtipc_connection_t *conn,
                          rtipc_msg_type_t msg_type,
                          const void *payload, size_t payload_len,
                          uint64_t now_ms) {
    rtipc_action_clear(conn);

    if (conn->state != RTIPC_STATE_CONNECTED) return -1;
    if (sender_in_flight(conn) >= conn->config.send_window) return -2;
    if (payload_len > RTIPC_MAX_PAYLOAD) return -1;

    uint32_t seq = conn->send_seq++;

    /* Find free pending slot */
    int slot = sender_find_free(conn);
    if (slot < 0) return -2;

    rtipc_header_t hdr = {
        .version = RTIPC_PROTOCOL_VERSION,
        .msg_type = msg_type,
        .payload_len = 0,
        .seq_num = seq,
        .error_code = RTIPC_ERR_OK,
        .checksum = 0,
    };

    size_t n = rtipc_build_packet(&hdr, payload, payload_len,
                                  conn->pending[slot].data,
                                  sizeof(conn->pending[slot].data));
    if (n == 0) return -1;

    conn->pending[slot].data_len = n;
    conn->pending[slot].seq = seq;
    conn->pending[slot].sent_at_ms = now_ms;
    conn->pending[slot].retries = 0;
    conn->pending[slot].in_use = true;
    conn->pending_count++;

    /* Push send action */
    if (conn->action_count < RTIPC_MAX_ACTIONS) {
        rtipc_action_t *a = &conn->actions[conn->action_count++];
        a->type = RTIPC_ACTION_SEND;
        a->data = conn->pending[slot].data;
        a->data_len = n;
    }

    return 0;
}

/* ── tick ────────────────────────────────────────────────── */

void rtipc_connection_tick(rtipc_connection_t *conn, uint64_t now_ms) {
    rtipc_action_clear(conn);

    /* Reconnecting state */
    if (conn->state == RTIPC_STATE_RECONNECTING) {
        if (now_ms >= conn->reconnect_deadline_ms) {
            /* Initiate new SYN */
            uint32_t seq = next_control_seq(conn);
            push_control_packet(conn, RTIPC_MSG_SYN, seq);
            conn->connect_attempt_ms = now_ms;
            conn->state = RTIPC_STATE_SYN_SENT;
        }
        return;
    }

    /* SYN_SENT timeout */
    if (conn->state == RTIPC_STATE_SYN_SENT) {
        if ((now_ms - conn->connect_attempt_ms) >= conn->config.connect_timeout_ms) {
            if (conn->config.auto_reconnect) {
                enter_reconnecting(conn, now_ms);
                action_push(conn, RTIPC_ACTION_DISCONNECTED);
                uint64_t base = conn->config.reconnect_initial_delay_ms;
                uint64_t maxd = conn->config.reconnect_max_delay_ms;
                uint32_t shift = conn->reconnect_attempts;
                if (shift > 10) shift = 10;
                uint64_t exp_val = (uint64_t)1 << shift;
                uint64_t delay = base * exp_val;
                if (delay > maxd) delay = maxd;
                if (conn->action_count < RTIPC_MAX_ACTIONS) {
                    rtipc_action_t *a = &conn->actions[conn->action_count++];
                    a->type = RTIPC_ACTION_RECONNECT;
                    a->delay_ms = delay;
                }
            } else {
                conn->state = RTIPC_STATE_CLOSED;
                action_push(conn, RTIPC_ACTION_DISCONNECTED);
            }
            return;
        }
    }

    if (conn->state != RTIPC_STATE_CONNECTED) return;

    /* Heartbeat send */
    if ((now_ms - conn->last_hb_sent_ms) >= conn->config.heartbeat_interval_ms) {
        uint32_t seq = next_control_seq(conn);
        push_control_packet(conn, RTIPC_MSG_HEARTBEAT, seq);
        conn->last_hb_sent_ms = now_ms;
    }

    /* Heartbeat timeout */
    if ((now_ms - conn->last_hb_recv_ms) >= conn->config.heartbeat_timeout_ms) {
        if (conn->config.auto_reconnect) {
            enter_reconnecting(conn, now_ms);
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        } else {
            conn->state = RTIPC_STATE_CLOSED;
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        }
        return;
    }

    /* Retransmission check */
    bool any_failed = false;
    for (int i = 0; i < RTIPC_SEND_WINDOW; i++) {
        if (!conn->pending[i].in_use) continue;
        rtipc_pending_t *pkt = &conn->pending[i];
        if ((now_ms - pkt->sent_at_ms) >= conn->config.rto_ms) {
            if (pkt->retries >= conn->config.max_retries) {
                pkt->in_use = false;
                if (conn->pending_count > 0)
                    conn->pending_count--;
                any_failed = true;
            } else {
                pkt->retries++;
                pkt->sent_at_ms = now_ms;
                /* Push retransmit action */
                if (conn->action_count < RTIPC_MAX_ACTIONS) {
                    rtipc_action_t *a = &conn->actions[conn->action_count++];
                    a->type = RTIPC_ACTION_SEND;
                    a->data = pkt->data;
                    a->data_len = pkt->data_len;
                }
            }
        }
    }

    if (any_failed) {
        if (conn->config.auto_reconnect) {
            enter_reconnecting(conn, now_ms);
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        } else {
            conn->state = RTIPC_STATE_CLOSED;
            action_push(conn, RTIPC_ACTION_DISCONNECTED);
        }
    }
}
