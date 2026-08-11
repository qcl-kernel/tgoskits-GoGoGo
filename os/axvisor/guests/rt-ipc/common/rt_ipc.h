#ifndef RT_IPC_H
#define RT_IPC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RTIPC_PROTOCOL_VERSION  0x01
#define RTIPC_HEADER_SIZE       12
#define RTIPC_MAX_PAYLOAD       1400
#define RTIPC_MAX_PACKET        (RTIPC_HEADER_SIZE + RTIPC_MAX_PAYLOAD)

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

typedef struct {
    uint64_t heartbeat_interval_ms;
    uint64_t heartbeat_timeout_ms;
    uint64_t connect_timeout_ms;
    uint64_t rto_ms;
    uint32_t max_retries;
    uint32_t send_window;
    uint32_t reorder_buf_size;
    bool     auto_reconnect;
    uint64_t reconnect_initial_delay_ms;
    uint64_t reconnect_max_delay_ms;
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

#define RTIPC_MAX_ACTIONS 8
#define RTIPC_SEND_WINDOW 64

typedef struct {
    rtipc_conn_state_t state;
    rtipc_config_t     config;
    uint32_t           send_seq;
    rtipc_pending_t    pending[RTIPC_SEND_WINDOW];
    uint32_t           pending_count;
    uint32_t           last_acked;
    uint32_t           expected_seq;
    struct {
        uint32_t seq;
        uint8_t  payload[RTIPC_MAX_PAYLOAD];
        size_t   payload_len;
        bool     in_use;
    } reorder_buf[64];
    uint32_t           reorder_count;
    uint64_t           last_hb_sent_ms;
    uint64_t           last_hb_recv_ms;
    uint64_t           connect_attempt_ms;
    uint64_t           reconnect_deadline_ms;
    uint32_t           reconnect_attempts;
    uint32_t           control_seq;
    rtipc_action_t     actions[RTIPC_MAX_ACTIONS];
    uint32_t           action_count;
    uint32_t           action_idx;
    uint8_t            deliver_buf[RTIPC_MAX_PAYLOAD];
} rtipc_connection_t;

void rtipc_connection_init(rtipc_connection_t *conn, const rtipc_config_t *cfg);
void rtipc_connection_connect(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_on_recv(rtipc_connection_t *conn, const void *data, size_t len, uint64_t now_ms);
int  rtipc_connection_send(rtipc_connection_t *conn, rtipc_msg_type_t msg_type, const void *payload, size_t payload_len, uint64_t now_ms);
void rtipc_connection_tick(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_force_disconnect(rtipc_connection_t *conn, uint64_t now_ms);
void rtipc_connection_disconnect(rtipc_connection_t *conn, uint64_t now_ms);
bool rtipc_connection_is_connected(const rtipc_connection_t *conn);
void rtipc_connection_reset(rtipc_connection_t *conn);
const rtipc_action_t *rtipc_action_next(rtipc_connection_t *conn);
void rtipc_action_clear(rtipc_connection_t *conn);

#ifdef __cplusplus
}
#endif

#endif
