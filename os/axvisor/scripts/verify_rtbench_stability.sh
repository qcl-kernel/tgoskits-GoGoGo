#!/bin/bash

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 LOG EXPECTED_SECONDS QEMU_EXIT_CODE" >&2
    exit 2
fi

log=$1
seconds=$2
qemu_rc=$3

case "$seconds" in
    ''|*[!0-9]*|0)
        echo "invalid stability duration: $seconds" >&2
        exit 2
        ;;
esac
if [ "$seconds" -gt 3600 ]; then
    echo "stability duration exceeds the guest limit: $seconds" >&2
    exit 2
fi

case "$qemu_rc" in
    ''|*[!0-9]*)
        echo "invalid QEMU exit code: $qemu_rc" >&2
        exit 2
        ;;
esac
if [ "${#qemu_rc}" -gt 3 ] || [ "$qemu_rc" -gt 255 ]; then
    echo "invalid QEMU exit code: $qemu_rc" >&2
    exit 2
fi

if [ ! -f "$log" ]; then
    echo "RT benchmark log does not exist: $log" >&2
    exit 1
fi

if [ "$qemu_rc" -ne 0 ]; then
    echo "QEMU failed with exit code $qemu_rc" >&2
    exit 1
fi

if grep -aEiq \
    'RTBENCH_ERROR|RTBENCH[^[:cntrl:]]*status=FAIL|panicked at|kernel panic|assertion failed|RT-Thread.*assert' \
    "$log"; then
    echo "benchmark error, panic, or assertion found in stability log" >&2
    exit 1
fi

expected=$((seconds * 1000 - 1))
begin_pattern="RTBENCH_STABILITY_BEGIN seconds=${seconds} expected=${expected}[[:space:]]*$"
end_pattern="RTBENCH_STABILITY_END status=PASS expected=${expected} collected=${expected} missing=0[[:space:]]*$"
done_pattern="RTBENCH_STABILITY_DONE[[:space:]]*$"
metric_suffix="run=1 expected=${expected} collected=${expected} missing=0 p50_ns=[0-9]+ p95_ns=[0-9]+ p99_ns=[0-9]+ p99_9_ns=[0-9]+ max_ns=[0-9]+ miss_100us=[0-9]+ miss_500us=[0-9]+ miss_1ms=[0-9]+ mean_ns=[0-9]+[[:space:]]*$"

if [ "$(grep -aEc "$begin_pattern" "$log")" -ne 1 ]; then
    echo "missing or duplicate ${seconds}-second stability begin marker" >&2
    exit 1
fi
if [ "$(grep -aEc "RTBENCH metric=stability_jitter ${metric_suffix}" "$log")" -ne 1 ]; then
    echo "stability jitter samples are missing or incomplete" >&2
    exit 1
fi
if [ "$(grep -aEc "RTBENCH metric=stability_jitter .*miss_1ms=0 mean_ns=[0-9]+[[:space:]]*$" "$log")" -ne 1 ]; then
    echo "stability benchmark exceeded the one-millisecond deadline" >&2
    exit 1
fi
if [ "$(grep -aEc "RTBENCH metric=callback_exec ${metric_suffix}" "$log")" -ne 1 ]; then
    echo "stability callback samples are missing or incomplete" >&2
    exit 1
fi
if [ "$(grep -aEc "$end_pattern" "$log")" -ne 1 ]; then
    echo "missing, duplicate, or incomplete stability end marker" >&2
    exit 1
fi
if [ "$(grep -aEc "$done_pattern" "$log")" -ne 1 ]; then
    echo "missing or duplicate stability done marker" >&2
    exit 1
fi

end_line=$(grep -anE "$end_pattern" "$log" | cut -d: -f1)
done_line=$(grep -anE "$done_pattern" "$log" | cut -d: -f1)
if [ "$done_line" -le "$end_line" ]; then
    echo "stability done marker precedes the complete result" >&2
    exit 1
fi

echo "PASS: RT benchmark stability completed (${seconds}s, ${expected} samples)"
