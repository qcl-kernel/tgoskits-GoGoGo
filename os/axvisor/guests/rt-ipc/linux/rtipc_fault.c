#include "rtipc_fault.h"

#include <string.h>

static bool packet_has_type(const uint8_t *packet, size_t length,
                            rtipc_msg_type_t type,
                            rtipc_header_t *parsed_header)
{
    rtipc_header_t header;

    if (packet == NULL ||
        rtipc_header_parse(packet, length, &header) != 0 ||
        header.msg_type != (uint8_t)type ||
        (size_t)RTIPC_HEADER_SIZE + header.payload_len > length) {
        return false;
    }
    if (!rtipc_verify_packet(&header, packet + RTIPC_HEADER_SIZE,
                             header.payload_len))
        return false;
    if (parsed_header != NULL)
        *parsed_header = header;
    return true;
}

int rtipc_fault_profile_parse(const char *text,
                              rtipc_fault_profile_t *profile)
{
    if (text == NULL || profile == NULL)
        return -1;
    if (strcmp(text, "none") == 0) {
        *profile = RTIPC_FAULT_PROFILE_NONE;
        return 0;
    }
    if (strcmp(text, "reliability") == 0) {
        *profile = RTIPC_FAULT_PROFILE_RELIABILITY;
        return 0;
    }
    return -1;
}

const char *rtipc_fault_profile_name(rtipc_fault_profile_t profile)
{
    return profile == RTIPC_FAULT_PROFILE_RELIABILITY
               ? "reliability"
               : "none";
}

void rtipc_fault_init(rtipc_fault_context_t *context,
                      rtipc_fault_profile_t profile)
{
    memset(context, 0, sizeof(*context));
    context->profile = profile;
}

rtipc_fault_action_t rtipc_fault_on_tx(rtipc_fault_context_t *context,
                                       int payload_size,
                                       const uint8_t *packet,
                                       size_t length)
{
    if (context->profile == RTIPC_FAULT_PROFILE_RELIABILITY &&
        payload_size == 64 && !context->drop_done &&
        packet_has_type(packet, length, RTIPC_MSG_CTRL_CMD, NULL)) {
        context->drop_done = true;
        return RTIPC_FAULT_ACTION_DROP;
    }
    return RTIPC_FAULT_ACTION_PASS;
}

rtipc_fault_action_t rtipc_fault_on_rx(rtipc_fault_context_t *context,
                                       int payload_size,
                                       const uint8_t *packet,
                                       size_t length)
{
    rtipc_header_t header;

    if (context->profile != RTIPC_FAULT_PROFILE_RELIABILITY ||
        !packet_has_type(packet, length, RTIPC_MSG_STATUS_REP, &header)) {
        return RTIPC_FAULT_ACTION_PASS;
    }

    if (payload_size == 256 && !context->duplicate_done) {
        context->duplicate_done = true;
        return RTIPC_FAULT_ACTION_DUPLICATE;
    }
    if (payload_size == 1024 && !context->reorder_done) {
        if (!context->reorder_held) {
            if (length > sizeof(context->held_packet))
                return RTIPC_FAULT_ACTION_PASS;
            memcpy(context->held_packet, packet, length);
            context->held_length = length;
            context->held_sequence = header.seq_num;
            context->reorder_held = true;
            return RTIPC_FAULT_ACTION_HOLD;
        }
        if (header.seq_num == context->held_sequence)
            return RTIPC_FAULT_ACTION_HOLD;
        context->reorder_done = true;
        return RTIPC_FAULT_ACTION_RELEASE_REVERSED;
    }
    return RTIPC_FAULT_ACTION_PASS;
}

int rtipc_fault_take_held(rtipc_fault_context_t *context,
                          uint8_t *packet,
                          size_t capacity,
                          size_t *length)
{
    if (!context->reorder_held || packet == NULL || length == NULL ||
        capacity < context->held_length) {
        return -1;
    }
    memcpy(packet, context->held_packet, context->held_length);
    *length = context->held_length;
    context->reorder_held = false;
    context->held_length = 0;
    context->held_sequence = 0;
    return 0;
}
