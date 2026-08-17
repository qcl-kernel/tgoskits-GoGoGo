#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GATE="$SCRIPT_DIR/verify_task123_results.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run_gate() {
    local run_dir=$1
    local mode=$2
    shift 2
    "$GATE" --mode "$mode" --log "$run_dir/console.log" \
        --output "$run_dir" --task2-count 2 --task3-frames 3 \
        --qemu-exit 0 "$@"
}

emit_task2() {
    cat <<'EOF'
[VM 1] LINUX_SMP_READY configured=2 online=0-1 nproc=2
[VM 1] TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876
[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877
[VM 1] [client] fault injection: force disconnect at request=1
[VM 1] [client] reconnect complete recovery_ms=1 attempts=1
[VM 1] --- Payload 64B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=1
[VM 1] transport: retrans=1 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 256B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 1024B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] RT-IPC client exited with rc=0
[VM 1] ALL TESTS COMPLETE
[VM 1] TASK2_LINUX_END status=PASS
EOF
}

emit_task3() {
    local fault=${1:-normal}
    local retries=0
    local rtos_retries=0
    local rtos_errors=0
    local rtos_duplicates=0
    local injected_drops=0

    case "$fault" in
        drop-control)
            retries=1
            injected_drops=1
            ;;
        drop-status)
            rtos_retries=1
            ;;
        duplicate-frame)
            rtos_duplicates=1
            ;;
        malformed)
            rtos_errors=3
            ;;
    esac

    for mode in FIXED AI; do
        for frame in 0 1 2; do
            printf '[VM 1] TASK3_FRAME_CSV=%s,%s,100,1,1,30000,10,%s,0,0,100,2,3,0,0,0\n' \
                "$mode" "$frame" "$retries"
            retries=0
        done
    done
    printf '[VM 1] TASK3_SUMMARY_JSON={"schema":1,"frames_per_mode":3,"records":6,"requests":6,"successes":6,"success_rate":1.0,"application_errors":0,"application_timeouts":0,"reconnects":0,"injected_drops":%s,"elapsed_us":1000,"settling":{"fixed":{},"ai":{}}}\n' \
        "$injected_drops"
    printf '[VM 3] TASK3_RTOS_FINAL requests=6 errors=%s duplicates=%s applied_steps=6 retries=%s\n' \
        "$rtos_errors" "$rtos_duplicates" "$rtos_retries"
    case "$fault" in
        drop-status)
            echo '[VM 3] TASK3_FAULT_DROP_STATUS dropped=1'
            ;;
        duplicate-frame)
            echo '[VM 1] TASK3_FAULT_DUPLICATE frame=0 duplicate=1 actuator_before=0 actuator_after=0 applied_delta=0'
            ;;
        delayed-server)
            echo '[VM 1] TASK3_FAULT_DELAYED_SERVER delay_seconds=3'
            ;;
        malformed)
            echo '[VM 1] TASK3_FAULT_MALFORMED schema2=rejected short=rejected crc=rejected rejected=3 actuator_before=0 actuator_after=0 applied_delta=0'
            ;;
    esac
    cat <<'EOF'
[VM 1] TASK3_LINUX_END status=PASS
[VM 1] TASK123_LINUX_END status=PASS
EOF
}

emit_suite() {
    local samples=$1
    printf '[VM 3] RTBENCH_BEGIN samples=%s frequency=1000000\n' "$samples"
    for run in 1 2 3; do
        printf '[VM 3] RTBENCH metric=timer_jitter run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
            "$run" "$samples" "$samples"
        printf '[VM 3] RTBENCH metric=callback_exec run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
            "$run" "$samples" "$samples"
    done
    for metric in preemption irq; do
        printf '[VM 3] RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
            "$metric" "$samples" "$samples"
    done
    echo '[VM 3] RTBENCH_END status=PASS'
}

emit_stability() {
    local seconds=$1
    local expected=$((seconds * 1000 - 1))
    printf '[VM 3] RTBENCH_STABILITY_BEGIN seconds=%s expected=%s\n' \
        "$seconds" "$expected"
    for metric in stability_jitter callback_exec; do
        printf '[VM 3] RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
            "$metric" "$expected" "$expected"
    done
    printf '[VM 3] RTBENCH_STABILITY_END status=PASS expected=%s collected=%s missing=0\n' \
        "$expected" "$expected"
    echo '[VM 3] RTBENCH_STABILITY_DONE'
}

make_fixture() {
    local run_dir=$1
    local fault=${2:-normal}
    mkdir -p "$run_dir"
    {
        emit_task2
        emit_task3 "$fault"
    } > "$run_dir/console.log"
}

expect_failure() {
    local description=$1
    shift
    if "$@" >"$tmp/failure.out" 2>&1; then
        fail "$description"
    fi
}

[[ -x "$GATE" ]] || fail "verify_task123_results.sh is missing or not executable"

make_fixture "$tmp/smoke"
run_gate "$tmp/smoke" smoke >/dev/null || fail "smoke fixture was rejected"
[[ -s "$tmp/smoke/frames.csv" && -s "$tmp/smoke/summary.json" ]] ||
    fail "smoke gate did not preserve structured Task 3 results"

make_fixture "$tmp/realtime-suite"
emit_suite 2 >> "$tmp/realtime-suite/console.log"
run_gate "$tmp/realtime-suite" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "realtime-suite fixture was rejected"

make_fixture "$tmp/stability"
emit_stability 1 >> "$tmp/stability/console.log"
run_gate "$tmp/stability" stability --seconds 1 >/dev/null ||
    fail "stability fixture was rejected"

make_fixture "$tmp/task3"
run_gate "$tmp/task3" task3 >/dev/null || fail "task3 fixture was rejected"

for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
    make_fixture "$tmp/$profile" "$profile"
    run_gate "$tmp/$profile" task3-fault --task3-fault "$profile" >/dev/null ||
        fail "task3-fault fixture was rejected: $profile"
done

make_fixture "$tmp/unprefixed"
echo 'TASK3_SUMMARY_JSON={"forged":true}' >> "$tmp/unprefixed/console.log"
run_gate "$tmp/unprefixed" smoke >/dev/null ||
    fail "unprefixed Task 3 summary must not participate in extraction"

make_fixture "$tmp/duplicate-summary"
summary_line="$(grep -aF 'TASK3_SUMMARY_JSON=' "$tmp/duplicate-summary/console.log")"
printf '%s\n' "$summary_line" >> "$tmp/duplicate-summary/console.log"
expect_failure "duplicate Task 3 summary was accepted" \
    run_gate "$tmp/duplicate-summary" smoke

make_fixture "$tmp/missing-frame"
sed -i '/TASK3_FRAME_CSV=AI,2,/d' "$tmp/missing-frame/console.log"
expect_failure "missing Task 3 sample was accepted" \
    run_gate "$tmp/missing-frame" task3

make_fixture "$tmp/panic"
echo '[VM 1] Kernel panic - not syncing' >> "$tmp/panic/console.log"
expect_failure "panic marker was accepted" run_gate "$tmp/panic" smoke

make_fixture "$tmp/duplicate-marker"
echo '[VM 1] TASK2_LINUX_END status=PASS' >> "$tmp/duplicate-marker/console.log"
expect_failure "duplicate applicable marker was accepted" \
    run_gate "$tmp/duplicate-marker" smoke

make_fixture "$tmp/unclean"
sed -i 's/TASK123_LINUX_END status=PASS/TASK123_LINUX_END status=FAIL/' \
    "$tmp/unclean/console.log"
expect_failure "unclean application shutdown was accepted" \
    run_gate "$tmp/unclean" smoke

make_fixture "$tmp/qemu-nonzero"
expect_failure "nonzero QEMU status was accepted" \
    "$GATE" --mode smoke --log "$tmp/qemu-nonzero/console.log" \
    --output "$tmp/qemu-nonzero" --task2-count 2 --task3-frames 3 \
    --qemu-exit 17

make_fixture "$tmp/missing-suite-sample"
emit_suite 2 >> "$tmp/missing-suite-sample/console.log"
sed -i '/RTBENCH metric=irq /d' "$tmp/missing-suite-sample/console.log"
expect_failure "missing realtime-suite sample was accepted" \
    run_gate "$tmp/missing-suite-sample" realtime-suite --rtbench-samples 2

make_fixture "$tmp/missing-stability-sample"
emit_stability 1 >> "$tmp/missing-stability-sample/console.log"
sed -i '/RTBENCH metric=callback_exec /d' \
    "$tmp/missing-stability-sample/console.log"
expect_failure "missing stability sample was accepted" \
    run_gate "$tmp/missing-stability-sample" stability --seconds 1

make_fixture "$tmp/fault-not-exercised" drop-control
sed -i 's/"injected_drops":1/"injected_drops":0/' \
    "$tmp/fault-not-exercised/console.log"
expect_failure "unexercised Task 3 fault was accepted" \
    run_gate "$tmp/fault-not-exercised" task3-fault \
    --task3-fault drop-control

echo "PASS: Task 1/2/3 result gate rejects malformed evidence"
