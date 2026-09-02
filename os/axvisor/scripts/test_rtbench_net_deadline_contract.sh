#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
BENCH="$ROOT/os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c"

grep -Eq '^#define RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS[[:space:]]+15U$' "$BENCH"
grep -Eq 'expected[[:space:]]*\*[[:space:]]*RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS' "$BENCH"
grep -Eq 'RTBENCH_NET_TIMEOUT_MARGIN_MS' "$BENCH"
echo "PASS: network benchmark deadline has a per-sample budget and margin"
