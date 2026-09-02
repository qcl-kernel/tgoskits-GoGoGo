#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
PROBE="$SCRIPT_DIR/send_rtbench_net_probe.py"
GUEST_PROBE="$ROOT/os/axvisor/guests/task3/src/linux/rtbench_net_probe.c"

wait_function="$(awk '/^static int wait_for_trigger\(/,/^int main\(/' "$GUEST_PROBE")"
grep -Fq '#define RTBENCH_NET_PROBE_READY UINT32_C(0xfffffffe)' "$GUEST_PROBE" || {
    echo "FAIL: probe must have an independent readiness control marker" >&2
    exit 1
}
grep -Fq 'RTBENCH_NET_PROBE_READY' <<<"$wait_function" || {
    echo "FAIL: probe wait path must send readiness control packets" >&2
    exit 1
}
grep -q 'sendto' <<<"$wait_function" || {
    echo "FAIL: probe wait path must send readiness control packets" >&2
    exit 1
}

probe_port="$(python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

python3 - "$probe_port" <<'PY' &
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", port))
dropped = 0
while dropped < 6:
    payload, address = sock.recvfrom(64)
    if payload[:4] == b"RTBN":
        dropped += 1
payload, address = sock.recvfrom(64)
sock.sendto(payload, address)
sock.close()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT

python3 "$PROBE" \
    --port "$probe_port" \
    --count 1 \
    --interval-us 0 \
    --ack-timeout-ms 50 \
    --retries 5

wait "$server_pid"
echo "PASS: network probe retries transient packet loss"
