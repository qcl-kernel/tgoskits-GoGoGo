#!/bin/bash

set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    echo "usage: $0 LOG EXPECTED_SAMPLES QEMU_EXIT_CODE [full|core] [rtthread|zephyr]" >&2
    exit 2
fi

log=$1
samples=$2
qemu_rc=$3
suite_mode=${4:-full}
rtos=${5:-rtthread}
case "$suite_mode" in
    full|core) ;;
    *)
        echo "invalid suite mode: $suite_mode" >&2
        exit 2
        ;;
esac
case "$rtos" in
    rtthread|zephyr) ;;
    *)
        echo "invalid RTOS selector: $rtos" >&2
        exit 2
        ;;
esac

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

# QEMU may be terminated as soon as RTBENCH_END is observed. RT-Thread emits
# that marker with a carriage return, so QEMU's termination diagnostic can be
# appended after the CR on the same byte stream. Normalize CR boundaries
# before applying the strict record checks.
normalized_log=$(mktemp)
trap 'rm -f -- "$normalized_log"' EXIT
python3 - "$log" "$normalized_log" <<'PY'
import re
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
data = re.sub(
    rb"(RTBENCH(?:_STABILITY)?_END status=(?:PASS|FAIL)"
    rb"(?: expected=[0-9]+ collected=[0-9]+ missing=0)?)(?:\r?\n|\r)?"
    rb"qemu-system-aarch64: terminating[^\r\n]*",
    rb"\1\n",
    data,
)
destination.write_bytes(data.replace(b"\r", b"\n"))
PY
log=$normalized_log
if [ "$qemu_rc" -ne 0 ]; then
    echo "QEMU failed with exit code $qemu_rc" >&2
    exit 1
fi
if [ "$rtos" = zephyr ]; then
    failure_check_log="$(mktemp)"
    sed '/RTBENCH_PMU status=unavailable /d' "$log" > "$failure_check_log"
    failure_pattern='RTBENCH_ERROR|RTBENCH[^[:cntrl:]]*status=FAIL|panicked at|kernel panic|assertion failed'
else
    failure_check_log="$log"
    failure_pattern='RTBENCH_ERROR|RTBENCH[^[:cntrl:]]*status=FAIL|RTBENCH_PMU status=unavailable|panicked at|kernel panic|assertion failed'
fi
if grep -aEiq "$failure_pattern" "$failure_check_log"; then
    echo "benchmark error, panic, or assertion found in suite log" >&2
    exit 1
fi

# RT-Thread omits `expected`; Zephyr includes it as an explicit sample-count
# echo. Both forms are valid only when the requested sample count is present.
begin_pattern="RTBENCH_BEGIN samples=${samples}( expected=${samples})? frequency=[1-9][0-9]* pmu_event=0x8[[:space:]]*$"
metric_suffix="expected=${samples} collected=${samples} missing=0 p50_ns=[0-9]+ p95_ns=[0-9]+ p99_ns=[0-9]+ p99_9_ns=[0-9]+ max_ns=[0-9]+ miss_100us=[0-9]+ miss_500us=[0-9]+ miss_1ms=[0-9]+ mean_ns=[0-9]+ p50_cycles=[0-9]+ p95_cycles=[0-9]+ p99_cycles=[0-9]+ p99_9_cycles=[0-9]+ max_cycles=[0-9]+ mean_cycles=[0-9]+ p50_instructions=[0-9]+ p95_instructions=[0-9]+ p99_instructions=[0-9]+ p99_9_instructions=[0-9]+ max_instructions=[0-9]+ mean_instructions=[0-9]+[[:space:]]*$"
ns_metric_suffix="expected=${samples} collected=${samples} missing=0 p50_ns=[0-9]+ p95_ns=[0-9]+ p99_ns=[0-9]+ p99_9_ns=[0-9]+ max_ns=[0-9]+ mean_ns=[0-9]+[[:space:]]*$"

metric_record_count() {
    local metric=$1
    local run=$2
    local verbose_count compact_count
    verbose_count="$(grep -aEc "RTBENCH metric=${metric} run=${run} ${metric_suffix}" "$log")"
    compact_count="$(grep -aEc "RTBENCH_NS metric=${metric} run=${run} ${ns_metric_suffix}" "$log")"
    if [ "$((verbose_count + compact_count))" -ge 1 ]; then
        echo 1
    else
        echo 0
    fi
}

if [ "$(grep -aEc "$begin_pattern" "$log")" -ne 1 ]; then
    echo "missing or duplicate benchmark suite begin marker" >&2
    exit 1
fi

required_runs=$( [ "$rtos" = zephyr ] && echo 1 || echo '1 2 3' )
for run in $required_runs; do
    if [ "$(metric_record_count timer_jitter "$run")" -ne 1 ]; then
        echo "timer jitter run ${run} is missing or incomplete" >&2
        exit 1
    fi
    if [ "$(metric_record_count callback_exec "$run")" -ne 1 ]; then
        echo "callback execution run ${run} is missing or incomplete" >&2
        exit 1
    fi
done

metrics='preemption irq irq_to_task irq_disabled_duration mutex_inversion wake_under_load context_switch scheduler_decision sync_sem sync_mutex sync_mailbox irq_handler_exec deadline_miss_under_load'
if [ "$rtos" = zephyr ] || [ "$suite_mode" = full ]; then
    metrics="$metrics net_event_latency"
fi
for metric in $metrics; do
    if [ "$(metric_record_count "$metric" 1)" -ne 1 ]; then
        echo "${metric} benchmark is missing or incomplete" >&2
        exit 1
    fi
done

end_pattern="RTBENCH_END status=PASS( expected=${samples} collected=${samples} missing=0)?[[:space:]]*$"
if [ "$(grep -aEc "$end_pattern" "$log")" -ne 1 ]; then
    echo "missing, duplicate, or failed benchmark suite end marker" >&2
    exit 1
fi

echo "PASS: RT benchmark suite completed (${samples} samples per metric)"
