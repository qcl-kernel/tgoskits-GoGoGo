#!/bin/bash

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 LOG EXPECTED_SAMPLES QEMU_EXIT_CODE" >&2
    exit 2
fi

log=$1
samples=$2
qemu_rc=$3

case "$samples" in
    ''|*[!0-9]*|0)
        echo "invalid benchmark sample count: $samples" >&2
        exit 2
        ;;
esac
if [ "$samples" -gt 100000 ]; then
    echo "benchmark sample count exceeds the guest limit: $samples" >&2
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
    echo "benchmark error, panic, or assertion found in suite log" >&2
    exit 1
fi

begin_pattern="RTBENCH_BEGIN samples=${samples} frequency=[1-9][0-9]*[[:space:]]*$"
metric_suffix="expected=${samples} collected=${samples} missing=0 p50_ns=[0-9]+ p95_ns=[0-9]+ p99_ns=[0-9]+ p99_9_ns=[0-9]+ max_ns=[0-9]+ miss_100us=[0-9]+ miss_500us=[0-9]+ miss_1ms=[0-9]+ mean_ns=[0-9]+[[:space:]]*$"

if [ "$(grep -aEc "$begin_pattern" "$log")" -ne 1 ]; then
    echo "missing or duplicate benchmark suite begin marker" >&2
    exit 1
fi

for run in 1 2 3; do
    if [ "$(grep -aEc "RTBENCH metric=timer_jitter run=${run} ${metric_suffix}" "$log")" -ne 1 ]; then
        echo "timer jitter run ${run} is missing or incomplete" >&2
        exit 1
    fi
    if [ "$(grep -aEc "RTBENCH metric=timer_jitter run=${run} .*miss_1ms=0 mean_ns=[0-9]+[[:space:]]*$" "$log")" -ne 1 ]; then
        echo "timer jitter run ${run} exceeded the one-millisecond deadline" >&2
        exit 1
    fi
    if [ "$(grep -aEc "RTBENCH metric=callback_exec run=${run} ${metric_suffix}" "$log")" -ne 1 ]; then
        echo "callback execution run ${run} is missing or incomplete" >&2
        exit 1
    fi
done

for metric in preemption irq; do
    if [ "$(grep -aEc "RTBENCH metric=${metric} run=1 ${metric_suffix}" "$log")" -ne 1 ]; then
        echo "${metric} benchmark is missing or incomplete" >&2
        exit 1
    fi
done

if [ "$(grep -aEc 'RTBENCH_END status=PASS[[:space:]]*$' "$log")" -ne 1 ]; then
    echo "missing, duplicate, or failed benchmark suite end marker" >&2
    exit 1
fi

echo "PASS: RT benchmark suite completed (${samples} samples per metric)"
