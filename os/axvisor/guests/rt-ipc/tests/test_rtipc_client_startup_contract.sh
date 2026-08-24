#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)"
CLIENT="$ROOT/os/axvisor/guests/rt-ipc/linux/rtipc_client.c"

grep -Eq '^#define HANDSHAKE_TIMEOUT_MS[[:space:]]+60000$' "$CLIENT" || {
    echo "FAIL: Linux RT-IPC client needs a 60-second startup handshake window" >&2
    exit 1
}
grep -Fq 'handshake_deadline_ms' "$CLIENT" || {
    echo "FAIL: handshake must use an absolute deadline" >&2
    exit 1
}
if grep -Eq 'for \(int w = 0; w < 100 && !rtipc_connection_is_connected' "$CLIENT"; then
    echo "FAIL: handshake still uses the old fixed 10-second retry loop" >&2
    exit 1
fi

echo "PASS: Linux RT-IPC client startup handshake contract"
