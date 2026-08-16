#ifndef RT_IPC_H
#define RT_IPC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RTIPC_PROTOCOL_VERSION  0x02
#define RTIPC_HEADER_SIZE       20
#define RTIPC_MAX_PAYLOAD       1400
#define RTIPC_MAX_PACKET        (RTIPC_HEADER_SIZE + RTIPC_MAX_PAYLOAD)
/* A v1 session owns one quarter of the sequence space. The bound stays below
 * the signed half-space used for wrap-safe ordering and leaves the final
 * sequence for FIN/FIN ACK before the next local session begins. */
#define RTIPC_SESSION_SEQUENCE_SPAN 0x40000000U

typedef enum {
    RTIPC_MSG_CTRL_CMD     = 0x01,
    RTIPC_MSG_STATUS_REP   = 0x02,
    RTIPC_MSG_ERROR_NOTIFY = 0x03,
    RTIPC_MSG_ACK          = 0x04,
    RTIPC_MSG_SYN          = 0x05,
    RTIPC_MSG_SYNACK       = 0x06,
    RTIPC_MSG_HEARTBEAT    = 0x07,
    RTIPC_MSG_HEARTBEAT_ACK= 0x08,
    RTIPC_MSG_FIN          = 0x09,
} rtipc_msg_type_t;

typedef enum {
    RTIPC_ERR_OK            = 0x0000,
    RTIPC_ERR_UNKNOWN       = 0x0001,
    RTIPC_ERR_CRC_MISMATCH  = 0x0002,
    RTIPC_ERR_INVALID_VER   = 0x0003,
    RTIPC_ERR_PAYLOAD_LARGE = 0x0004,
    RTIPC_ERR_TIMEOUT       = 0x0005,
    RTIPC_ERR_CONN_LOST     = 0x0006,
    RTIPC_ERR_BUFFER_FULL   = 0x0007,
} rtipc_error_t;

typedef struct {
    uint8_t  version;
    uint8_t  msg_type;
    uint16_t payload_len;
    uint32_t seq_num;
    uint64_t session_id;
    uint16_t error_code;
    uint16_t checksum;
} rtipc_header_t;

uint16_t rtipc_crc16(const void *data, size_t len);
uint16_t rtipc_crc16_continue(uint16_t init, const void *data, size_t len);
void     rtipc_header_serialize(const rtipc_header_t *hdr, uint8_t *out);
int      rtipc_header_parse(const uint8_t *buf, size_t len, rtipc_header_t *out);
size_t   rtipc_build_packet(rtipc_header_t *hdr, const void *payload, size_t payload_len, uint8_t *out_buf, size_t out_size);
bool     rtipc_verify_packet(const rtipc_header_t *hdr, const void *payload, size_t payload_len);

typedef enum {
    RTIPC_STATE_CLOSED,
    RTIPC_STATE_SYN_SENT,
    RTIPC_STATE_SYN_RECEIVED,
    RTIPC_STATE_CONNECTED,
    RTIPC_STATE_SHUTDOWN,
    RTIPC_STATE_RECONNECTING,
} rtipc_conn_state_t;

typedef enum {
    RTIPC_SEND_OK = 0,
    RTIPC_SEND_INVALID = -1,
    RTIPC_SEND_WOULD_BLOCK = -2,
} rtipc_send_result_t;

typedef struct {
    uint64_t heartbeat_interval_ms;
    uint64_t heartbeat_timeout_ms;
    uint64_t connect_timeout_ms;
    uint64_t rto_ms;
    uint32_t max_retries;
    uint32_t send_window;
    /* Maximum future packets retained; storage remains statically allocated. */
    uint32_t reorder_buf_size;
    bool     auto_reconnect;
    uint64_t reconnect_initial_delay_ms;
    uint64_t reconnect_max_delay_ms;
    uint64_t session_id_seed;
} rtipc_config_t;

void rtipc_config_default(rtipc_config_t *cfg);

typedef struct {
    uint8_t  data[RTIPC_MAX_PACKET];
    size_t   data_len;
    uint32_t seq;
    uint64_t sent_at_ms;
    uint32_t retries;
    bool     in_use;
} rtipc_pending_t;

typedef struct {
    uint8_t          data[RTIPC_HEADER_SIZE];
    size_t           data_len;
    rtipc_msg_type_t msg_type;
    uint32_t         seq;
    uint64_t         sent_at_ms;
    uint32_t         retries;
    bool             active;
} rtipc_control_pending_t;

typedef enum {
    RTIPC_ACTION_NONE = 0,
    RTIPC_ACTION_SEND,
    RTIPC_ACTION_CONNECTED,
    RTIPC_ACTION_DISCONNECTED,
    RTIPC_ACTION_DELIVER,
    RTIPC_ACTION_RECONNECT,
} rtipc_action_type_t;

typedef struct {
    rtipc_action_type_t type;
    uint8_t  *data;
    size_t    data_len;
    uint8_t  *payload;
    size_t    payload_len;
    uint8_t   msg_type;
    uint64_t  delay_ms;
} rtipc_action_t;

#define RTIPC_SEND_WINDOW 64
#define RTIPC_APP_ACTION_BATCH 8
#define RTIPC_MAX_ACTIONS RTIPC_APP_ACTION_BATCH
#define RTIPC_ACTION_QUEUE_CAPACITY (RTIPC_SEND_WINDOW + 1)
#define RTIPC_LIFECYCLE_ACTION_CAPACITY 3
#define RTIPC_RETIRED_SESSION_CAPACITY 16

typedef struct {
    uint32_t tx_packets;
    uint32_t tx_bytes;
    uint32_t rx_packets;
    uint32_t rx_bytes;
    uint32_t rx_duplicates;
    uint32_t rx_out_of_order;
    uint32_t rx_errors;
    uint32_t acks_received;
    uint32_t retransmissions;
    uint32_t timeouts;
} rtipc_stats_t;

typedef struct {
    rtipc_conn_state_t state;
    rtipc_config_t     config;
    rtipc_stats_t      stats;
    uint32_t           send_seq;
    rtipc_pending_t    pending[RTIPC_SEND_WINDOW];
    uint32_t           pending_count;
    uint32_t           last_acked;
    uint32_t           expected_seq;
    struct {
        uint32_t seq;
        uint8_t  payload[RTIPC_MAX_PAYLOAD];
        size_t   payload_len;
        uint8_t  msg_type;
        bool     in_use;
        bool     delivery_queued;
    } reorder_buf[RTIPC_SEND_WINDOW];
    uint32_t           reorder_count;
    uint64_t           last_hb_sent_ms;
    uint64_t           last_hb_recv_ms;
    uint64_t           connect_attempt_ms;
    uint64_t           reconnect_deadline_ms;
    uint32_t           reconnect_attempts;
    uint32_t           control_seq;
    uint32_t           session_seq;
    bool               session_seq_valid;
    uint64_t           session_id;
    uint64_t           next_session_id;
    uint64_t           retired_session_ids[RTIPC_RETIRED_SESSION_CAPACITY];
    uint32_t           retired_session_count;
    uint32_t           retired_session_next;
    uint32_t           next_session_seq;
    uint32_t           peer_syn_seq;
    bool               peer_syn_seq_valid;
    uint32_t           peer_fin_seq;
    bool               peer_fin_seq_valid;
    rtipc_control_pending_t control_pending;
    rtipc_action_t     actions[RTIPC_ACTION_QUEUE_CAPACITY];
    uint32_t           action_count;
    uint32_t           action_idx;
    rtipc_action_t     deferred_lifecycle[RTIPC_LIFECYCLE_ACTION_CAPACITY];
    uint32_t           deferred_lifecycle_count;
    uint8_t            control_buf[RTIPC_ACTION_QUEUE_CAPACITY]
                                  [RTIPC_HEADER_SIZE];
} rtipc_connection_t;

void rtipc_connection_init(rtipc_connection_t *conn, const rtipc_config_t *cfg);
void rtipc_connection_connect(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_on_recv(rtipc_connection_t *conn, const void *data, size_t len, uint64_t now_ms);
rtipc_send_result_t rtipc_connection_send(rtipc_connection_t *conn, rtipc_msg_type_t msg_type, const void *payload, size_t payload_len, uint64_t now_ms);
void rtipc_connection_tick(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_force_disconnect(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_disconnect(rtipc_connection_t *conn, uint64_t now_ms);
bool rtipc_connection_is_connected(const rtipc_connection_t *conn);
void rtipc_connection_reset(rtipc_connection_t *conn);
const rtipc_action_t *rtipc_action_next(rtipc_connection_t *conn);
bool rtipc_action_defer(rtipc_connection_t *conn,
                        const rtipc_action_t *action);
/* Explicitly discards queued/deferred actions and releases DELIVER backing. */
void rtipc_action_clear(rtipc_connection_t *conn);
rtipc_stats_t rtipc_connection_stats(const rtipc_connection_t *conn);

#ifdef __cplusplus
}
#endif

#endif
