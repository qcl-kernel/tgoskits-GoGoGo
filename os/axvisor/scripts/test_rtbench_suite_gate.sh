#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY="$SCRIPT_DIR/verify_rtbench_suite.sh"
BENCHMARK_SOURCE="$SCRIPT_DIR/../guests/rt-benchmark/rtthread/rt_benchmark.c"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

write_complete_log() {
    log=$1
    cat > "$log" <<'EOF'
[VM 3] RTBENCH_PMU status=ready event=0x8 cycles_delta=100 instructions_delta=100
[VM 3] RTBENCH_BEGIN samples=1000 frequency=62500000 pmu_event=0x8
[VM 3] RTBENCH metric=timer_jitter run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=callback_exec run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=timer_jitter run=2 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=callback_exec run=2 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=timer_jitter run=3 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=callback_exec run=3 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=preemption run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=irq run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=irq_to_task run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=irq_disabled_duration run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=mutex_inversion run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=wake_under_load run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
   for metric in context_switch scheduler_decision sync_sem sync_mutex sync_mailbox \
[VM 3] RTBENCH metric=net_event_latency run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
EOF
    for metric in context_switch scheduler_decision sync_sem sync_mutex sync_mailbox \
        irq_handler_exec deadline_miss_under_load; do
        printf '[VM 3] RTBENCH metric=%s run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1\n' "$metric" >> "$log"
    done
    printf '%s\n' '[VM 3] RTBENCH_END status=PASS' >> "$log"
}

expect_pass() {
    name=$1
    shift
    if ! "$@" > "$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should pass" >&2
        cat "$TMP_DIR/$name.out" >&2
        exit 1
    fi
}

expect_fail() {
    name=$1
    shift
    if "$@" > "$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should fail" >&2
        cat "$TMP_DIR/$name.out" >&2
        exit 1
    fi
}

complete="$TMP_DIR/complete.log"
write_complete_log "$complete"
expect_pass complete "$VERIFY" "$complete" 1000 0
expect_fail qemu_timeout "$VERIFY" "$complete" 1000 124

zephyr_complete="$TMP_DIR/zephyr-complete.log"
sed 's/RTBENCH_BEGIN samples=1000 frequency=/RTBENCH_BEGIN samples=1000 expected=1000 frequency=/' \
    "$complete" > "$zephyr_complete"
sed -i 's/RTBENCH_END status=PASS$/RTBENCH_END status=PASS expected=1000 collected=1000 missing=0/' \
    "$zephyr_complete"
expect_pass zephyr_complete "$VERIFY" "$zephyr_complete" 1000 0 core zephyr

unavailable_pmu="$TMP_DIR/unavailable-pmu.log"
sed 's/RTBENCH_PMU status=ready/RTBENCH_PMU status=unavailable/' "$complete" > "$unavailable_pmu"
expect_fail unavailable_pmu "$VERIFY" "$unavailable_pmu" 1000 0

tail_observed="$TMP_DIR/tail-observed.log"
write_complete_log "$tail_observed"
sed -i '0,/miss_1ms=0/s//miss_1ms=1/' "$tail_observed"
expect_pass tail_observed "$VERIFY" "$tail_observed" 1000 0

missing_context_switch="$TMP_DIR/missing-context-switch.log"
write_complete_log "$missing_context_switch"
sed -i '/metric=context_switch/d' "$missing_context_switch"
expect_fail missing_context_switch "$VERIFY" "$missing_context_switch" 1000 0

grep -qF 'rt_bool_t strict_tail' "$BENCHMARK_SOURCE" || {
    echo "FAIL: RT benchmark does not separate suite data completeness from strict stability tails" >&2
    exit 1
}
grep -qF '(!strict_tail || jitter_result.miss_1ms == 0)' "$BENCHMARK_SOURCE" || {
    echo "FAIL: RT benchmark suite still fails on an observed timer tail" >&2
    exit 1
}

for required in \
    'volatile rt_bool_t stopping' \
    'struct rt_semaphore workers_done' \
    'struct rt_semaphore low_go' \
    'static void rtbench_mutex_abort' \
    'static rt_bool_t rtbench_mutex_wait_workers' \
    'rt_tick_from_millisecond(100)'; do
    grep -qF "$required" "$BENCHMARK_SOURCE" || {
        echo "FAIL: mutex inversion benchmark lacks lifecycle guard: $required" >&2
        exit 1
    }
done

for required in \
    'rtbench_run_context_switch' \
    'rtbench_run_scheduler_decision' \
    'rtbench_run_sync_sem' \
    'rtbench_run_sync_mutex' \
    'rtbench_run_sync_mailbox' \
    'rtbench_run_irq_handler_exec' \
    'rtbench_run_deadline_miss_under_load' \
    'rt_thread_yield()' \
    'rt_schedule()'; do
    grep -qF "$required" "$BENCHMARK_SOURCE" || {
        echo "FAIL: RT benchmark lacks overhead metric contract: $required" >&2
        exit 1
    }
done

for required in \
    'struct rtbench_deadline_context' \
    'rtbench_deadline_load' \
    'load_threads[4]' \
    'workers_done' \
    'RT_TIMER_FLAG_PERIODIC | RT_TIMER_FLAG_HARD_TIMER' \
    'rt_timer_stop(&context->timer)' \
    'rt_thread_delete(context->load_threads[i])'; do
    grep -qF "$required" "$BENCHMARK_SOURCE" || {
        echo "FAIL: deadline benchmark lacks lifecycle contract: $required" >&2
        exit 1
    }
done

for required in \
    'volatile rt_bool_t released' \
    'while (!context->released' \
    'context->released = RT_TRUE' \
    'RTBENCH_WORKER_PRIORITY,'; do
    grep -qF "$required" "$BENCHMARK_SOURCE" || {
        echo "FAIL: context-switch benchmark lacks startup barrier: $required" >&2
        exit 1
    }
done

python3 - "$BENCHMARK_SOURCE" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()

def function_body(name):
    match = re.search(
        rf"static (?:int|void|rt_bool_t) {name}\([^)]*\)\s*\{{",
        source,
    )
    if not match:
        raise SystemExit(f"FAIL: missing function {name}")
    start = match.end()
    depth = 1
    index = start
    while depth and index < len(source):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    return source[start:index - 1]

low = function_body("rtbench_mutex_low")
controller = function_body("rtbench_run_mutex_inversion")
if "rt_sem_take(&context->low_go" not in low:
    raise SystemExit("FAIL: low-priority mutex worker is not explicitly gated per sample")
low_gate = controller.find("rt_sem_release(&context->low_go)")
low_ready = controller.find("rt_sem_take(&context->low_acquired")
high_gate = controller.find("rt_sem_release(&context->high_go)")
if low_gate < 0 or low_ready < 0 or low_gate > low_ready:
    raise SystemExit("FAIL: mutex controller must start low worker before waiting for low_acquired")
if high_gate >= 0 and high_gate < low_ready:
    raise SystemExit("FAIL: mutex controller must not release high_go before low_acquired")
PY

python3 - "$BENCHMARK_SOURCE" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.find("static rt_bool_t rtbench_net_event_probe_sequence")
end = source.find("/* Called by", start)
if start < 0 or end < 0:
    raise SystemExit("FAIL: missing network probe classifier")
classifier = source[start:end]
if "RTBENCH_NET_PROBE_READY" not in classifier:
    raise SystemExit("FAIL: network probe readiness control packet must not count as a dropped sample")
PY

crlf="$TMP_DIR/crlf.log"
sed 's/$/\r/' "$complete" > "$crlf"
expect_pass crlf "$VERIFY" "$crlf" 1000 0

cr_after_end="$TMP_DIR/cr-after-end.log"
python3 - "$complete" "$cr_after_end" <<'PY'
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
marker = b"RTBENCH_END status=PASS\n"
if data.count(marker) != 1:
    raise SystemExit("suite end marker not found")
destination.write_bytes(
    data.replace(marker, marker[:-1] + b"\rqemu-system-aarch64: terminating on signal 15\n", 1)
)
PY
expect_pass cr_after_end "$VERIFY" "$cr_after_end" 1000 0

missing_run="$TMP_DIR/missing-run.log"
write_complete_log "$missing_run"
sed -i '/metric=timer_jitter run=2/d' "$missing_run"
expect_fail missing_timer_run "$VERIFY" "$missing_run" 1000 0

missing_net_event="$TMP_DIR/missing-net-event.log"
write_complete_log "$missing_net_event"
sed -i '/metric=net_event_latency/d' "$missing_net_event"
expect_fail missing_net_event "$VERIFY" "$missing_net_event" 1000 0
expect_pass core_without_network "$VERIFY" "$missing_net_event" 1000 0 core

missing_samples="$TMP_DIR/missing-samples.log"
write_complete_log "$missing_samples"
sed -i '0,/collected=1000 missing=0/s//collected=999 missing=1/' \
    "$missing_samples"
expect_fail missing_samples "$VERIFY" "$missing_samples" 1000 0

failed_suite="$TMP_DIR/failed-suite.log"
write_complete_log "$failed_suite"
sed -i 's/RTBENCH_END status=PASS/RTBENCH_END status=FAIL/' "$failed_suite"
expect_fail failed_suite "$VERIFY" "$failed_suite" 1000 0

conflicting_suite="$TMP_DIR/conflicting-suite.log"
write_complete_log "$conflicting_suite"
printf '%s\n' '[VM 3] RTBENCH_END status=FAIL' >> "$conflicting_suite"
expect_fail conflicting_suite "$VERIFY" "$conflicting_suite" 1000 0

panic_log="$TMP_DIR/panic.log"
write_complete_log "$panic_log"
printf '%s\n' 'kernel panic' >> "$panic_log"
expect_fail panic "$VERIFY" "$panic_log" 1000 0

expect_fail qemu_failure "$VERIFY" "$complete" 1000 1
expect_fail invalid_samples "$VERIFY" "$complete" invalid 0
for invalid_qemu_rc in '' abc 999999999999999999999; do
    set +e
    "$VERIFY" "$complete" 1000 "$invalid_qemu_rc" \
        >"$TMP_DIR/invalid-qemu-rc.out" 2>&1
    invalid_status=$?
    set -e
    if [ "$invalid_status" -ne 2 ]; then
        echo "FAIL: invalid QEMU exit code '$invalid_qemu_rc' returned $invalid_status instead of 2" >&2
        exit 1
    fi
    set +e
    "$VERIFY" "$TMP_DIR/missing-invalid.log" 1000 "$invalid_qemu_rc" \
        >"$TMP_DIR/missing-invalid-qemu-rc.out" 2>&1
    missing_invalid_status=$?
    set -e
    if [ "$missing_invalid_status" -ne 2 ]; then
        echo "FAIL: missing log with invalid QEMU exit code '$invalid_qemu_rc' returned $missing_invalid_status instead of 2" >&2
        exit 1
    fi
done

echo "PASS: RT benchmark suite result gate"
