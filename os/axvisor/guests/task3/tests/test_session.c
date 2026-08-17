#include "controller.h"
#include "session.h"
#include "task3_protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define ASSERT_TRUE(value)                                                        \
    do {                                                                          \
        if (!(value)) {                                                           \
            fprintf(stderr, "assertion failed at %s:%d: %s\n", __FILE__,       \
                    __LINE__, #value);                                             \
            return 1;                                                             \
        }                                                                         \
    } while (0)

enum { QUEUE_CAPACITY = 128 };

typedef struct peer peer_t;

typedef struct {
    peer_t *destination;
    size_t length;
    uint8_t bytes[RTIPC_MAX_PACKET];
} queued_datagram_t;

typedef struct {
    queued_datagram_t items[QUEUE_CAPACITY];
    size_t head;
    size_t count;
    uint64_t now_ms;
} network_t;

struct peer {
    task3_session_t session;
    network_t *network;
    peer_t *other;
    task3_controller_t controller;
    uint32_t delivered_statuses;
    uint32_t duplicate_statuses;
    uint32_t last_status_frame;
    int drop_ctrl_once;
    int drop_status_once;
    int drop_synack_once;
    size_t first_syn_length;
    uint8_t first_syn[RTIPC_MAX_PACKET];
};

static uint8_t packet_type(const uint8_t *bytes, size_t length)
{
    return length >= RTIPC_HEADER_SIZE ? bytes[1] : 0;
}

static int fake_send(void *context, const uint8_t *bytes, size_t length)
{
    peer_t *peer = context;
    network_t *network = peer->network;
    queued_datagram_t *item;
    uint8_t type = packet_type(bytes, length);

    if (length > RTIPC_MAX_PACKET) {
        return -1;
    }
    if (type == RTIPC_MSG_CTRL_CMD && peer->drop_ctrl_once) {
        peer->drop_ctrl_once = 0;
        return 0;
    }
    if (type == RTIPC_MSG_STATUS_REP && peer->drop_status_once) {
        peer->drop_status_once = 0;
        return 0;
    }
    if (type == RTIPC_MSG_SYN && peer->first_syn_length == 0) {
        peer->first_syn_length = length;
        memcpy(peer->first_syn, bytes, length);
    }
    if (type == RTIPC_MSG_SYNACK && peer->drop_synack_once) {
        peer->drop_synack_once = 0;
        return 0;
    }
    if (network->count >= QUEUE_CAPACITY) {
        return -1;
    }
    item = &network->items[(network->head + network->count) % QUEUE_CAPACITY];
    item->destination = peer->other;
    item->length = length;
    memcpy(item->bytes, bytes, length);
    network->count++;
    return 0;
}

static int deliver_message(void *context, uint8_t message_type,
                           const uint8_t *payload, size_t length, uint64_t now_ms)
{
    peer_t *peer = context;

    if (message_type == RTIPC_MSG_CTRL_CMD) {
        task3_control_t control;
        task3_status_t status;
        uint8_t wire[TASK3_STATUS_WIRE_SIZE];
        uint64_t before = peer->controller.applied_steps;

        if (task3_decode_control(payload, length, &control) != TASK3_APP_OK) {
            return -1;
        }
        if (task3_controller_apply(&peer->controller, &control, &status) !=
            TASK3_APP_OK) {
            return -1;
        }
        if (peer->controller.applied_steps == before &&
            (status.flags & TASK3_STATUS_FLAG_DUPLICATE) != 0) {
            peer->duplicate_statuses++;
        }
        if (task3_encode_status(&status, wire) != TASK3_APP_OK) {
            return -1;
        }
        return task3_session_send(&peer->session, RTIPC_MSG_STATUS_REP, wire,
                                  sizeof(wire), now_ms);
    }
    if (message_type == RTIPC_MSG_STATUS_REP) {
        task3_status_t status;

        if (task3_decode_status(payload, length, &status) != TASK3_APP_OK) {
            return -1;
        }
        peer->delivered_statuses++;
        peer->last_status_frame = status.frame_id;
        return 0;
    }
    return -1;
}

static int drain_network(network_t *network)
{
    size_t guard = 0;

    while (network->count > 0) {
        queued_datagram_t item = network->items[network->head];
        network->head = (network->head + 1) % QUEUE_CAPACITY;
        network->count--;
        if (task3_session_on_datagram(&item.destination->session, item.bytes,
                                      item.length, network->now_ms) != 0) {
            return -1;
        }
        if (++guard > 1000) {
            return -1;
        }
    }
    return 0;
}

static int submit_step(peer_t *client, uint32_t frame_id, uint64_t now_ms)
{
    task3_control_t control = {
        .command = TASK3_CMD_STEP,
        .mode = TASK3_MODE_AI,
        .klass = TASK3_CLASS_RIGHT,
        .confidence_q15 = 30000,
        .frame_id = frame_id,
        .tx_monotonic_ns = now_ms * UINT64_C(1000000),
    };
    uint8_t wire[TASK3_CTRL_WIRE_SIZE];

    if (task3_encode_control(&control, wire) != TASK3_APP_OK) {
        return -1;
    }
    return task3_session_submit_control(&client->session, wire, sizeof(wire),
                                        frame_id, now_ms);
}

int main(void)
{
    network_t network = {0};
    peer_t client = {.network = &network};
    peer_t server = {.network = &network};
    uint64_t applied;

    client.other = &server;
    server.other = &client;
    server.drop_synack_once = 1;
    task3_controller_init(&server.controller);
    task3_session_init(&client.session, TASK3_SESSION_CLIENT,
                       UINT64_C(0x1111222233334444), fake_send,
                       deliver_message, &client);
    task3_session_init(&server.session, TASK3_SESSION_SERVER,
                       UINT64_C(0x5555666677778888), fake_send,
                       deliver_message, &server);

    ASSERT_TRUE(client.session.connection.config.rto_ms == 50);
    ASSERT_TRUE(client.session.connection.config.max_retries == 5);
    ASSERT_TRUE(client.session.connection.config.heartbeat_interval_ms == 1000);
    ASSERT_TRUE(client.session.connection.config.heartbeat_timeout_ms == 5000);
    ASSERT_TRUE(client.session.connection.config.connect_timeout_ms == 500);
    ASSERT_TRUE(client.session.connection.config.auto_reconnect);
    ASSERT_TRUE(client.session.connection.config.session_id_seed ==
                UINT64_C(0x1111222233334444));
    ASSERT_TRUE(client.session.connection.next_session_id ==
                UINT64_C(0x1111222233334444));

    ASSERT_TRUE(task3_session_connect(&client.session, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(!task3_session_is_connected(&client.session));
    ASSERT_TRUE(task3_session_is_connected(&server.session));
    ASSERT_TRUE(client.first_syn_length == RTIPC_HEADER_SIZE);
    network.now_ms += 50;
    ASSERT_TRUE(task3_session_tick(&client.session, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(task3_session_is_connected(&client.session));
    ASSERT_TRUE(client.session.connection.session_id ==
                UINT64_C(0x1111222233334444));

    {
        task3_control_t control = {
            .command = TASK3_CMD_STEP,
            .mode = TASK3_MODE_AI,
            .klass = TASK3_CLASS_RIGHT,
            .confidence_q15 = 30000,
            .frame_id = 99,
        };
        uint8_t payload[TASK3_CTRL_WIRE_SIZE];
        uint8_t packet[RTIPC_MAX_PACKET + 1];
        rtipc_header_t header = {
            .version = RTIPC_PROTOCOL_VERSION + 1,
            .msg_type = RTIPC_MSG_CTRL_CMD,
            .seq_num = server.session.connection.expected_seq,
        };
        size_t packet_length;

        ASSERT_TRUE(task3_encode_control(&control, payload) == TASK3_CODEC_OK);
        header.version = RTIPC_PROTOCOL_VERSION;
        header.seq_num = server.session.connection.expected_seq + 1;
        packet_length = rtipc_build_packet(&header, payload, sizeof(payload),
                                           packet, sizeof(packet));
        ASSERT_TRUE(task3_session_on_datagram(&server.session, packet,
                                              packet_length,
                                              network.now_ms) == 0);
        ASSERT_TRUE(server.controller.applied_steps == 0);

        header.version = RTIPC_PROTOCOL_VERSION + 1;
        header.seq_num = server.session.connection.expected_seq;
        packet_length = rtipc_build_packet(&header, payload, sizeof(payload),
                                           packet, sizeof(packet));
        ASSERT_TRUE(packet_length > 0);
        ASSERT_TRUE(task3_session_on_datagram(&server.session, packet,
                                              packet_length,
                                              network.now_ms) != 0);
        ASSERT_TRUE(server.controller.applied_steps == 0);

        header.version = RTIPC_PROTOCOL_VERSION;
        packet_length = rtipc_build_packet(&header, payload, sizeof(payload),
                                           packet, sizeof(packet));
        packet[packet_length] = 0xaa;
        ASSERT_TRUE(task3_session_on_datagram(&server.session, packet,
                                              packet_length + 1,
                                              network.now_ms) != 0);
        ASSERT_TRUE(server.controller.applied_steps == 0);
    }

    client.drop_ctrl_once = 1;
    server.drop_status_once = 1;
    ASSERT_TRUE(submit_step(&client, 7, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(client.delivered_statuses == 0);

    network.now_ms += 50;
    ASSERT_TRUE(task3_session_tick(&client.session, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(server.controller.applied_steps == 1);
    ASSERT_TRUE(client.delivered_statuses == 0);

    network.now_ms += 50;
    ASSERT_TRUE(task3_session_tick(&server.session, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(client.delivered_statuses == 1);
    ASSERT_TRUE(client.last_status_frame == 7);
    ASSERT_TRUE(!task3_session_has_outstanding(&client.session));
    ASSERT_TRUE(client.session.counters.transport_retries == 1);
    ASSERT_TRUE(server.session.counters.transport_retries == 1);

    applied = server.controller.applied_steps;
    ASSERT_TRUE(submit_step(&client, 7, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(server.controller.applied_steps == applied);
    ASSERT_TRUE(server.duplicate_statuses == 1);
    ASSERT_TRUE(client.session.counters.transport_retries == 1);

    ASSERT_TRUE(submit_step(&client, 9, network.now_ms) == 0);
    network.count = 0;
    network.head = 0;
    network.now_ms += 5000;
    ASSERT_TRUE(task3_session_tick(&client.session, network.now_ms) == 0);
    ASSERT_TRUE(!task3_session_is_connected(&client.session));
    ASSERT_TRUE(task3_session_has_outstanding(&client.session));
    ASSERT_TRUE(client.session.counters.disconnects >= 1);

    network.now_ms += 1000;
    ASSERT_TRUE(task3_session_tick(&client.session, network.now_ms) == 0);
    ASSERT_TRUE(drain_network(&network) == 0);
    ASSERT_TRUE(task3_session_is_connected(&client.session));
    ASSERT_TRUE(client.last_status_frame == 9);
    ASSERT_TRUE(!task3_session_has_outstanding(&client.session));
    ASSERT_TRUE(client.session.counters.reconnects == 1);
    ASSERT_TRUE(client.session.connection.session_id ==
                UINT64_C(0x1111222233334445));
    ASSERT_TRUE(task3_session_on_datagram(&server.session, client.first_syn,
                                          client.first_syn_length,
                                          network.now_ms) == 0);
    ASSERT_TRUE(task3_session_is_connected(&server.session));
    ASSERT_TRUE(server.session.connection.session_id ==
                UINT64_C(0x1111222233334445));

    puts("test_session: PASS");
    return 0;
}
