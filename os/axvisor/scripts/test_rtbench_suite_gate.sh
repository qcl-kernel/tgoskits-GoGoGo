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
[VM 3] RTBENCH_BEGIN samples=1000 frequency=62500000
[VM 3] RTBENCH metric=timer_jitter run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=callback_exec run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=timer_jitter run=2 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=callback_exec run=2 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=timer_jitter run=3 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=callback_exec run=3 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=preemption run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=irq run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=irq_to_task run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=irq_disabled_duration run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=mutex_inversion run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=wake_under_load run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH metric=net_event_latency run=1 expected=1000 collected=1000 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1
[VM 3] RTBENCH_END status=PASS
EOF
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

tail_observed="$TMP_DIR/tail-observed.log"
write_complete_log "$tail_observed"
sed -i '0,/miss_1ms=0/s//miss_1ms=1/' "$tail_observed"
expect_pass tail_observed "$VERIFY" "$tail_observed" 1000 0

grep -qF 'rt_bool_t strict_tail' "$BENCHMARK_SOURCE" || {
    echo "FAIL: RT benchmark does not separate suite data completeness from strict stability tails" >&2
    exit 1
}
grep -qF '(!strict_tail || jitter_result.miss_1ms == 0)' "$BENCHMARK_SOURCE" || {
    echo "FAIL: RT benchmark suite still fails on an observed timer tail" >&2
    exit 1
}

crlf="$TMP_DIR/crlf.log"
sed 's/$/\r/' "$complete" > "$crlf"
expect_pass crlf "$VERIFY" "$crlf" 1000 0

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
