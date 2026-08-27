#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
log="$tmp/console.log"

cat > "$log" <<'LOG'
[VM 1] STARRY_SMP_READY configured=2 online=0-1 nproc=2
[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876
[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877
[VM 1] --- Payload 64B ---
[VM 1]   sent=2  recv=2  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 256B ---
[VM 1] [progress] size=256 idx=1 sent=1 recv=1 state=3 acks=[VM 1]   sent=2  recv=2  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 1024B ---
[VM 1]   sent=2  recv=2  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] RT-IPC client exited with rc=0
[VM 1] ALL TESTS COMPLETE
LOG

"$ROOT/os/axvisor/scripts/verify_rtipc_results.sh" \
    "$log" 2 0 none starryos
echo "PASS: interleaved RT-IPC summary"
