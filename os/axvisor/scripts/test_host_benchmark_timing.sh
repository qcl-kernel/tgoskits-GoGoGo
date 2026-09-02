#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TIMING="$ROOT/os/axvisor/scripts/host_benchmark_timing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
state="$tmp/state"
result="$tmp/result"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

"$TIMING" start "$state"
sleep 0.02
"$TIMING" finish "$state" "$result" stability seconds 300

line="$(cat "$result")"
[[ "$line" == RTBENCH_HOST_TIMING\ * ]] || fail "missing timing record prefix"
for field in \
    'mode=stability' \
    'requested_unit=seconds' \
    'requested_value=300' \
    'start_monotonic_ns=' \
    'end_monotonic_ns=' \
    'start_epoch_ns=' \
    'end_epoch_ns=' \
    'elapsed_ns=' \
    'elapsed_ms='; do
    [[ "$line" == *"$field"* ]] || fail "missing field: $field"
done

start_ns="$(sed -n 's/.*start_monotonic_ns=\([0-9][0-9]*\).*/\1/p' "$result")"
end_ns="$(sed -n 's/.*end_monotonic_ns=\([0-9][0-9]*\).*/\1/p' "$result")"
elapsed_ns="$(sed -n 's/.*elapsed_ns=\([0-9][0-9]*\).*/\1/p' "$result")"
[[ -n "$start_ns" && -n "$end_ns" && -n "$elapsed_ns" ]] || \
    fail "timing values must be decimal integers"
[[ "$end_ns" -gt "$start_ns" ]] || fail "monotonic clock must advance"
[[ "$elapsed_ns" -eq $((end_ns - start_ns)) ]] || \
    fail "elapsed_ns must be derived from CLOCK_MONOTONIC"
[[ "$elapsed_ns" -ge 10000000 ]] || fail "measured interval is unexpectedly short"

if "$TIMING" finish "$tmp/missing" "$tmp/invalid" suite samples 1000 \
    >/dev/null 2>&1; then
    fail "finish must reject a missing state file"
fi
[[ ! -e "$tmp/invalid" ]] || fail "failed finish must not create a result"

echo "Host benchmark timing contract: PASS"
