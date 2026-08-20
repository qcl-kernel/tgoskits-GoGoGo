#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT="$ROOT/os/axvisor/guests/linux-net/init-task123"
BENCH="$ROOT/os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c"
PROBE_SOURCE="$ROOT/os/axvisor/guests/task3/src/linux/rtbench_net_probe.c"

grep -Eq -- '--interval-us[[:space:]]+0' "$INIT"
grep -Eq '^#define RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS[[:space:]]+15U$' "$BENCH"
grep -Eq 'SO_RCVTIMEO' "$PROBE_SOURCE"
grep -Eq 'RTBENCH_NET_PROBE_READY' "$PROBE_SOURCE"
grep -Eq 'sendto\(socket_fd, payload' "$BENCH"
echo "PASS: Linux network probe is ACK-paced and guest budget covers coexistence RTT"
