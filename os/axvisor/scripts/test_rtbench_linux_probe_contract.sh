#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT="$ROOT/os/axvisor/guests/linux-net/init-task123"
BENCH="$ROOT/os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c"
PROBE_SOURCE="$ROOT/os/axvisor/guests/task3/src/linux/rtbench_net_probe.c"
RUNNER="$ROOT/os/axvisor/scripts/run_task123.sh"

runner_function=$(sed -n '/^feed_benchmark_command()/,/^wait_for_qemu_pid()/p' "$RUNNER")
linux_done_line=$(grep -n 'wait_for_console_marker "\$APP_GUEST_TASK123_END_MARKER"' <<<"$runner_function" | head -n 1 | cut -d: -f1)
benchmark_line=$(grep -n 'command="benchmark \$rtbench_samples"' <<<"$runner_function" | head -n 1 | cut -d: -f1)
[ -n "$linux_done_line" ] && [ -n "$benchmark_line" ] &&
    [ "$linux_done_line" -lt "$benchmark_line" ] || {
    echo "FAIL: realtime benchmark must start after Linux Task 1/2/3 completion" >&2
    exit 1
}

grep -Eq -- '--interval-us[[:space:]]+2000' "$INIT"
grep -Eq '^#define RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS[[:space:]]+15U$' "$BENCH"
grep -Eq 'SO_RCVTIMEO' "$PROBE_SOURCE"
grep -Eq '^#define RTBENCH_NET_PROBE_TIMEOUT_USEC[[:space:]]+500000U$' "$PROBE_SOURCE"
grep -Eq '^#define RTBENCH_NET_PROBE_ATTEMPTS[[:space:]]+8U$' "$PROBE_SOURCE"
grep -Eq 'RTBENCH_NET_PROBE_READY' "$PROBE_SOURCE"
grep -Eq 'ECONNREFUSED' "$PROBE_SOURCE"
grep -Eq 'sendto\(socket_fd, payload' "$BENCH"
python3 - "$PROBE_SOURCE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("for (unsigned long sequence = 0;")
end = source.index("if (!acknowledged)", start)
window = source[start:end]
if "for (;;)" not in window:
    raise SystemExit("FAIL: probe must ignore stale control packets while waiting for a matching ACK")
PY
echo "PASS: Linux network probe is ACK-paced and guest budget covers coexistence RTT"
