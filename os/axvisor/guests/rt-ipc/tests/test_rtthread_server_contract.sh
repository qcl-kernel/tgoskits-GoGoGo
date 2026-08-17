#!/bin/bash

set -eu

server=${1:-../rtthread/rtipc_server.c}

require_pattern() {
    pattern=$1
    message=$2
    if ! grep -Eq "$pattern" "$server"; then
        echo "FAIL: $message" >&2
        exit 1
    fi
}

require_pattern 'RTIPC_SERVER_ERROR stage=' \
    'server errors need a machine-readable status marker'
require_pattern 'inet_aton\([^;]+\)[[:space:]]*!=[[:space:]]*1' \
    'static IP parsing failures must be checked'
require_pattern 'netdev_set_ipaddr\([^;]+\)[[:space:]]*!=[[:space:]]*RT_EOK' \
    'IP address configuration failures must be checked'
require_pattern 'netdev_set_netmask\([^;]+\)[[:space:]]*!=[[:space:]]*RT_EOK' \
    'netmask configuration failures must be checked'
require_pattern 'netdev_set_gw\([^;]+\)[[:space:]]*!=[[:space:]]*RT_EOK' \
    'gateway configuration failures must be checked'
require_pattern 'setsockopt\([^;]+\)[[:space:]]*!=[[:space:]]*0' \
    'receive timeout setup failures must be checked'
require_pattern 'if[[:space:]]*\(tid[[:space:]]*==[[:space:]]*RT_NULL\)' \
    'thread allocation failures must be returned'
require_pattern 'rt_thread_startup\(tid\)[[:space:]]*;' \
    'thread startup must be attempted explicitly'
require_pattern 'return[[:space:]]+startup_result[[:space:]]*;' \
    'thread startup status must propagate to INIT_APP_EXPORT'
require_pattern '^int[[:space:]]+rtipc_server_start\(void\)' \
    'the combined image needs a stable RT-IPC server entry symbol'
require_pattern 'INIT_APP_EXPORT\(rtipc_server_start\);' \
    'the stable RT-IPC server entry must start automatically'
require_pattern 'cfg\.auto_reconnect[[:space:]]*=[[:space:]]*false' \
    'the fixed UDP server must release dead ephemeral client peers'
require_pattern 'rtipc_peer_guard_retire\(' \
    'closed sessions must retain a bounded FIN retransmission tombstone'
require_pattern 'rtipc_peer_guard_accepts_closed_fin\(' \
    'a duplicate FIN must reach the protocol core after its first ACK is lost'

echo 'PASS: RT-Thread server startup contract'
