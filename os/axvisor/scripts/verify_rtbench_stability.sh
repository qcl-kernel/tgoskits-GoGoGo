#!/bin/bash

set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    echo "usage: $0 LOG EXPECTED_SECONDS QEMU_EXIT_CODE [allow-qemu-timer-limit] [rtthread|zephyr]" >&2
    exit 2
fi

log=$1
seconds=$2
qemu_rc=$3
allow_qemu_timer_limit=${4:-}
rtos=${5:-rtthread}

if [ -n "$allow_qemu_timer_limit" ] && [ "$allow_qemu_timer_limit" != allow-qemu-timer-limit ]; then
    echo "invalid stability diagnostic mode: $allow_qemu_timer_limit" >&2
    exit 2
fi
case "$rtos" in
    rtthread|zephyr) ;;
    *)
        echo "invalid RTOS selector: $rtos" >&2
        exit 2
        ;;
esac

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

# See verify_rtbench_suite.sh: the marker watcher can stop QEMU immediately
# after a CR-terminated RT-Thread record, leaving QEMU text on that record.
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
data = re.sub(
    rb"(RTBENCH_STABILITY_BEGIN seconds=[0-9]+ expected=[0-9]+)"
    rb"[^\x1b\r\n]*?(frequency=[1-9][0-9]+)",
    rb"\1 \2",
    data,
)
data = re.sub(
    rb"\x1b\[37m\[[^\r\n]*?\x1b\[[0-?]*[ -/]*m",
    b"",
    data,
)
data = re.sub(
    rb"(?:\x1b\[[0-9;]*m)+[^\x1b\r\n]*(?=(?:\r?\n|\r|$))",
    b"",
    data,
)
data = re.sub(
    rb"(RTBENCH_STABILITY_BEGIN seconds=[0-9]+ expected=[0-9]+)[ \t\r\n]+",
    rb"\1 ",
    data,
)
destination.write_bytes(data.replace(b"\r", b"\n"))
PY
log=$normalized_log

if [ "$qemu_rc" -ne 0 ]; then
    echo "QEMU failed with exit code $qemu_rc" >&2
    exit 1
fi
failure_log="$log"
if [ "$rtos" = zephyr ]; then
    zephyr_failure_log="$(mktemp)"
    sed '/RTBENCH_PMU status=unavailable /d' "$log" > "$zephyr_failure_log"
    failure_log="$zephyr_failure_log"
fi
if [ "$allow_qemu_timer_limit" = allow-qemu-timer-limit ]; then
    timer_limit_failure_log="$(mktemp)"
    sed '/RTBENCH_STABILITY_END status=FAIL/d' "$failure_log" > "$timer_limit_failure_log"
    if [ "$failure_log" != "$log" ]; then
        rm -f -- "$failure_log"
    fi
    failure_log="$timer_limit_failure_log"
fi
trap 'rm -f -- "$failure_log"' EXIT
if grep -aEiq \
    'RTBENCH_ERROR|RTBENCH[^[:cntrl:]]*status=FAIL|RTBENCH_PMU status=unavailable|panicked at|kernel panic|assertion failed|RT-Thread.*assert' \
    "$failure_log"; then
    echo "benchmark error, panic, or assertion found in stability log" >&2
    exit 1
fi

expected=$((seconds * 1000 - 1))
begin_pattern="RTBENCH_STABILITY_BEGIN seconds=${seconds} expected=${expected}[[:space:]]*frequency=[1-9][0-9]* pmu_event=0x8"
if [ "$allow_qemu_timer_limit" = allow-qemu-timer-limit ]; then
    end_pattern="RTBENCH_STABILITY_END status=(PASS|FAIL) expected=${expected} collected=${expected} missing=0[[:space:]]*$"
else
    end_pattern="RTBENCH_STABILITY_END status=PASS expected=${expected} collected=${expected} missing=0[[:space:]]*$"
fi
done_pattern="RTBENCH_STABILITY_DONE[[:space:]]*$"
metric_suffix="run=1 expected=${expected} collected=${expected} missing=0 p50_ns=[0-9]+ p95_ns=[0-9]+ p99_ns=[0-9]+ p99_9_ns=[0-9]+ max_ns=[0-9]+ miss_100us=[0-9]+ miss_500us=[0-9]+ miss_1ms=[0-9]+ mean_ns=[0-9]+ p50_cycles=[0-9]+ p95_cycles=[0-9]+ p99_cycles=[0-9]+ p99_9_cycles=[0-9]+ max_cycles=[0-9]+ mean_cycles=[0-9]+ p50_instructions=[0-9]+ p95_instructions=[0-9]+ p99_instructions=[0-9]+ p99_9_instructions=[0-9]+ max_instructions=[0-9]+ mean_instructions=[0-9]+[[:space:]]*$"

if [ "$(grep -aEc "$begin_pattern" "$log")" -ne 1 ]; then
    echo "missing or duplicate ${seconds}-second stability begin marker" >&2
    exit 1
fi
if [ "$(grep -aEc "RTBENCH metric=stability_jitter ${metric_suffix}" "$log")" -ne 1 ]; then
    echo "stability jitter samples are missing or incomplete" >&2
    exit 1
fi
if [ "$allow_qemu_timer_limit" = allow-qemu-timer-limit ]; then
    if [ "$(grep -aEc "RTBENCH_STABILITY_END status=FAIL expected=${expected} collected=${expected} missing=0[[:space:]]*$" "$log")" -eq 1 ]; then
        if [ "$(grep -aEc "RTBENCH metric=stability_jitter .*miss_1ms=[1-9][0-9]* mean_ns=[0-9]+ p50_cycles=" "$log")" -ne 1 ]; then
            echo "diagnostic stability failure was not caused by a one-millisecond timer miss" >&2
            exit 1
        fi
    fi
elif [ "$(grep -aEc "RTBENCH metric=stability_jitter .*miss_1ms=0 mean_ns=[0-9]+ p50_cycles=" "$log")" -ne 1 ]; then
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
done_count=$(grep -aEc "$done_pattern" "$log" || true)
if [ "$done_count" -gt 1 ]; then
    echo "duplicate stability done marker" >&2
    exit 1
fi

if [ "$done_count" -eq 1 ]; then
    end_line=$(grep -anE "$end_pattern" "$log" | cut -d: -f1)
    done_line=$(grep -anE "$done_pattern" "$log" | cut -d: -f1)
    if [ "$done_line" -le "$end_line" ]; then
        echo "stability done marker precedes the complete result" >&2
        exit 1
    fi
fi

echo "PASS: RT benchmark stability completed (${seconds}s, ${expected} samples)"
