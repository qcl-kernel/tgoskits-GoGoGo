#include "rtipc_echo_responder.h"

rtipc_echo_result_t rtipc_echo_process_actions(
    rtipc_connection_t *connection, uint64_t now_ms,
    rtipc_echo_send_fn send_packet, void *send_context)
{
    rtipc_echo_result_t result = {0};
    bool deferred_delivery = false;

    const rtipc_action_t *action;
    while ((action = rtipc_action_next(connection)) != NULL) {
        switch (action->type) {
        case RTIPC_ACTION_SEND:
            if (send_packet(action->data, action->data_len,
                            send_context) != 0)
                result.send_errors++;
            break;
        case RTIPC_ACTION_CONNECTED:
            result.connected_events++;
            break;
        case RTIPC_ACTION_DISCONNECTED:
            result.disconnected_events++;
            break;
        case RTIPC_ACTION_DELIVER:
            if (action->msg_type != RTIPC_MSG_CTRL_CMD) {
                result.response_errors++;
                break;
            }
            rtipc_send_result_t send_result = rtipc_connection_send(
                connection, RTIPC_MSG_STATUS_REP, action->payload,
                action->payload_len, now_ms);
            if (send_result == RTIPC_SEND_WOULD_BLOCK &&
                rtipc_action_defer(connection, action)) {
                deferred_delivery = true;
                break;
            }
            if (send_result != RTIPC_SEND_OK) {
                result.response_errors++;
                break;
            }
            result.delivered_messages++;
            break;
        default:
            break;
        }
        if (deferred_delivery)
            break;
    }
    if (!deferred_delivery)
        rtipc_action_clear(connection);
    return result;
}
