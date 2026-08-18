#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
SAMPLER="$ROOT/os/axvisor/scripts/sample_qemu_resources.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[[ -x "$SAMPLER" ]] || fail "QEMU resource sampler is missing or not executable"

sleep 0.2 &
child=$!
metrics="$tmp/host-metrics.txt"
"$SAMPLER" "$child" "$metrics" 10 &
sampler=$!
wait "$child"
wait "$sampler"

grep -Eq '^schema=1$' "$metrics" || fail "metrics schema is missing"
grep -Eq '^qemu_pid=[0-9]+$' "$metrics" || fail "QEMU PID is missing"
grep -Eq '^elapsed_ms=[1-9][0-9]*$' "$metrics" || fail "elapsed wall time is invalid"
grep -Eq '^cpu_time_ms=[0-9]+$' "$metrics" || fail "CPU time is invalid"
grep -Eq '^peak_rss_kb=[1-9][0-9]*$' "$metrics" || fail "peak RSS is invalid"
grep -Eq '^max_threads=[1-9][0-9]*$' "$metrics" || fail "maximum thread count is invalid"
grep -Eq '^sample_count=[1-9][0-9]*$' "$metrics" || fail "sample count is invalid"

echo "PASS: QEMU resource sampler contract"
