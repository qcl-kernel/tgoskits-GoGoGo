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

run_starry_gate() {
    local run_dir=$1
    "$GATE" --app-guest starryos --mode smoke --log "$run_dir/console.log" \
        --output "$run_dir" --task2-count 2 --task3-frames 3 --qemu-exit 0
}

emit_task2() {
    cat <<'EOF'
[VM 1] LINUX_SMP_READY configured=2 online=0-1 nproc=2
[VM 1] TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876
[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877
[VM 1] --- Payload 64B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
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
    echo '[VM 3] TASK3_RTOS_FINAL_DONE'
    case "$fault" in
        drop-status)
            echo '[VM 3] TASK3_FAULT_DROP_STATUS dropped=1'
            ;;
        duplicate-frame)
            echo '[VM 1] TASK3_FAULT_DUPLICATE frame=0 duplicate=1 actuator_before=0 actuator_after=0 applied_delta=0'
            ;;
        delayed-server)
            echo '[VM 3] TASK3_FAULT_DELAYED_SERVER delay_ms=3000'
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
    local counters='p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=2'
    printf '[VM 3] RTBENCH_BEGIN samples=%s frequency=1000000 pmu_event=0x8\n' "$samples"
    for run in 1 2 3; do
        printf '[VM 3] RTBENCH metric=timer_jitter run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
            "$run" "$samples" "$samples" "$counters"
        printf '[VM 3] RTBENCH metric=callback_exec run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
            "$run" "$samples" "$samples" "$counters"
    done
    for metric in preemption irq irq_to_task irq_disabled_duration mutex_inversion wake_under_load \
        context_switch scheduler_decision sync_sem sync_mutex sync_mailbox irq_handler_exec \
        deadline_miss_under_load net_event_latency; do
        printf '[VM 3] RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
            "$metric" "$samples" "$samples" "$counters"
    done
    echo '[VM 3] RTBENCH_END status=PASS'
}

emit_stability() {
    local seconds=$1
    local expected=$((seconds * 1000 - 1))
    local counters='p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=2'
    printf '[VM 3] RTBENCH_STABILITY_BEGIN seconds=%s expected=%s frequency=1000000 pmu_event=0x8\n' \
        "$seconds" "$expected"
    for metric in stability_jitter callback_exec; do
        printf '[VM 3] RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
            "$metric" "$expected" "$expected" "$counters"
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

assert_summary_sources() {
    local run_dir=$1
    local app_guest=$2
    local rtos=$3
    python3 - "$run_dir/summary.json" "$app_guest" "$rtos" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
app_guest = sys.argv[2]
rtos = sys.argv[3]
sources = summary.get("sources", {})
if sources.get("app_guest") != app_guest:
    raise SystemExit(f"wrong summary app guest: {sources!r}")
if sources.get("rtos") != rtos:
    raise SystemExit(f"wrong summary RTOS: {sources!r}")
if Path(sources.get("app_log", "")).name != f"{app_guest}.log":
    raise SystemExit(f"wrong summary application log: {sources!r}")
if Path(sources.get("rtos_log", "")).name != f"{rtos}.log":
    raise SystemExit(f"wrong summary RTOS log: {sources!r}")
retries = summary.get("transport_retries_by_side", {})
if set(retries) != {app_guest, rtos}:
    raise SystemExit(f"wrong retry-side identities: {retries!r}")
PY
}

[[ -x "$GATE" ]] || fail "verify_task123_results.sh is missing or not executable"

make_fixture "$tmp/smoke"
run_gate "$tmp/smoke" smoke >/dev/null || fail "smoke fixture was rejected"
[[ -s "$tmp/smoke/frames.csv" && -s "$tmp/smoke/summary.json" ]] ||
    fail "smoke gate did not preserve structured Task 3 results"
assert_summary_sources "$tmp/smoke" linux rtthread

make_fixture "$tmp/normal-rtos-errors"
sed -i 's/TASK3_RTOS_FINAL requests=6 errors=0/TASK3_RTOS_FINAL requests=6 errors=1/' \
    "$tmp/normal-rtos-errors/console.log"
expect_failure "normal Task 3 accepted RTOS application errors" \
    run_gate "$tmp/normal-rtos-errors" smoke

make_fixture "$tmp/normal-applied-steps"
sed -i 's/applied_steps=6/applied_steps=5/' \
    "$tmp/normal-applied-steps/console.log"
expect_failure "normal Task 3 accepted a missing RTOS control action" \
    run_gate "$tmp/normal-applied-steps" smoke

cp -a "$tmp/smoke" "$tmp/rtos-final-interleaved"
python3 - "$tmp/rtos-final-interleaved/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
marker = b"[VM 3] TASK3_RTOS_FINAL_DONE\n"
interleaved = (
    b"[VM 3] TASK3_RTOS_FINAL_DON"
    b"\x1b[37m[ 52.430151 0:30 axvm::runtime::vcpus:667] "
    b"\x1b[32mVM[1] VCpu[1] exiting...\x1b[m\r\n"
    b"E\r\n"
)
if data.count(marker) != 1:
    raise SystemExit("RTOS final marker fixture not found")
path.write_bytes(data.replace(marker, interleaved, 1))
PY
rm -f -- "$tmp/rtos-final-interleaved/linux.log" \
    "$tmp/rtos-final-interleaved/summary.json" \
    "$tmp/rtos-final-interleaved/frames.csv" \
    "$tmp/rtos-final-interleaved/summary.raw.json"
run_gate "$tmp/rtos-final-interleaved" smoke >/dev/null ||
    fail "interleaved RTOS final marker was rejected"

cp -a "$tmp/smoke" "$tmp/rtthread-ready-alias"
python3 - "$tmp/rtthread-ready-alias/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_text(encoding="utf-8")
canonical = "[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876\n"
alias = "[VM 3] [32m[I/rtipic.srv] server starting on 192.168.77.30:9876[0m\n"
if data.count(canonical) != 1:
    raise SystemExit("RT-Thread ready marker fixture not found")
path.write_text(data.replace(canonical, alias, 1), encoding="utf-8")
PY
rm -f -- "$tmp/rtthread-ready-alias/linux.log" \
    "$tmp/rtthread-ready-alias/summary.json" \
    "$tmp/rtthread-ready-alias/frames.csv" \
    "$tmp/rtthread-ready-alias/summary.raw.json"
run_gate "$tmp/rtthread-ready-alias" smoke >/dev/null ||
    fail "RT-Thread stable ready-log alias was rejected"

cp -a "$tmp/smoke" "$tmp/starryos"
sed -i \
    -e 's/LINUX_SMP_READY/STARRY_SMP_READY/g' \
    -e 's/TASK123_LINUX_NET_READY/STARRY_NET_READY/g' \
    -e 's/TASK2_LINUX_END/TASK2_STARRY_END/g' \
    -e 's/TASK3_LINUX_END/TASK3_STARRY_END/g' \
    -e 's/TASK123_LINUX_END/TASK123_STARRY_END/g' \
    "$tmp/starryos/console.log"
rm -f -- "$tmp/starryos/linux.log" "$tmp/starryos/summary.json" \
    "$tmp/starryos/frames.csv" "$tmp/starryos/summary.raw.json"
run_starry_gate "$tmp/starryos" >/dev/null || fail "StarryOS smoke fixture was rejected"
[[ -s "$tmp/starryos/starryos.log" ]] ||
    fail "StarryOS gate did not publish the authenticated application log"
assert_summary_sources "$tmp/starryos" starryos rtthread

make_fixture "$tmp/zephyr"
run_gate "$tmp/zephyr" smoke --rtos zephyr >/dev/null ||
    fail "Zephyr smoke fixture was rejected"
[[ -s "$tmp/zephyr/zephyr.log" ]] ||
    fail "Zephyr gate did not publish the authenticated RTOS log"
assert_summary_sources "$tmp/zephyr" linux zephyr

cp -a "$tmp/smoke" "$tmp/ansi-console"
python3 - "$tmp/ansi-console/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "[VM 1] TASK3_FRAME_CSV=FIXED,0",
    "[VM 1] \x1b[mTASK3_FRAME_CSV=FIXED,0",
    1,
)
path.write_text(text, encoding="utf-8")
PY
rm -f -- "$tmp/ansi-console/linux.log" "$tmp/ansi-console/summary.json" \
    "$tmp/ansi-console/frames.csv" "$tmp/ansi-console/summary.raw.json"
run_gate "$tmp/ansi-console" smoke >/dev/null ||
    fail "ANSI-wrapped console markers were rejected"

make_fixture "$tmp/attached-linux-replay"
awk '
    !attached && /^\[VM 1\] TASK3_FRAME_CSV=/ {
        print "[Axvisor] attached VM[1] console; use Ctrl+X, then h to return to the shell"
        attached = 1
    }
    attached && /^\[VM 1\] / { sub(/^\[VM 1\] /, "") }
    { print }
' "$tmp/attached-linux-replay/console.log" \
    > "$tmp/attached-linux-replay/console.replayed.log"
mv "$tmp/attached-linux-replay/console.replayed.log" \
    "$tmp/attached-linux-replay/console.log"
run_gate "$tmp/attached-linux-replay" smoke >/dev/null ||
    fail "attached VM1 replay fixture was rejected"
[[ -s "$tmp/attached-linux-replay/frames.csv" &&
   -s "$tmp/attached-linux-replay/summary.json" ]] ||
    fail "attached VM1 replay did not preserve structured Task 3 results"

make_fixture "$tmp/realtime-suite"
emit_suite 2 >> "$tmp/realtime-suite/console.log"
run_gate "$tmp/realtime-suite" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "realtime-suite fixture was rejected"

cp -a "$tmp/realtime-suite" "$tmp/realtime-suite-interleaved"
python3 - "$tmp/realtime-suite-interleaved/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "RTBENCH metric=irq_to_task run=1 expected=2 collected=2"
replacement = "RTBENCH metric=irq_to_task run=1 expected=2 collected=2\x1b[32m[I/rtipic.srv] client connected\x1b[0m\n6 p95_ns=2 missing=0"
if text.count(needle) != 1:
    raise SystemExit("interleaving fixture marker not found")
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
rm -f -- "$tmp/realtime-suite-interleaved/linux.log" \
    "$tmp/realtime-suite-interleaved/summary.json" \
    "$tmp/realtime-suite-interleaved/frames.csv" \
    "$tmp/realtime-suite-interleaved/summary.raw.json"
run_gate "$tmp/realtime-suite-interleaved" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "interleaved RTBENCH records were rejected"

cp -a "$tmp/realtime-suite" "$tmp/realtime-suite-field-name-interleaved"
python3 - "$tmp/realtime-suite-field-name-interleaved/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "p99_9_ns=4 max_ns=5"
replacement = "p99_9_n\x1b[32m[I/rtipic.srv] client connected\x1b[0ms=4 max_ns=5"
if text.count(needle) != 20:
    raise SystemExit("field-name interleaving fixture marker count changed")
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
rm -f -- "$tmp/realtime-suite-field-name-interleaved/linux.log" \
    "$tmp/realtime-suite-field-name-interleaved/summary.json" \
    "$tmp/realtime-suite-field-name-interleaved/frames.csv" \
    "$tmp/realtime-suite-field-name-interleaved/summary.raw.json"
run_gate "$tmp/realtime-suite-field-name-interleaved" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "field-name interleaved RTBENCH records were rejected"

cp -a "$tmp/realtime-suite" "$tmp/realtime-suite-host-log-interleaved"
python3 - "$tmp/realtime-suite-host-log-interleaved/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
metric = (
    b"[VM 3] RTBENCH metric=net_event_latency run=1 expected=2 collected=2 "
    b"missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 "
    b"miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 "
    b"p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 "
    b"p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=2\n"
)
fragmented_metric = metric.replace(
    b"mean_ns=2\n",
    b"mean_ns=\x1b[37m[ 1.000000 0:2 axvm::vm:1] \x1b[33mstop\x1b[m\r\n"
    b"2\x1b[37m[ 1.000001 0:2 axvm::vm:2] \x1b[32mdone\x1b[m\r\n\r\n",
)
end = b"[VM 3] RTBENCH_END status=PASS\n"
fragmented_end = (
    b"[VM 3] RTBE\x1b[37m[ 1.000002 0:2 axvm::vm:3] \x1b[32ndone\x1b[m\r\n"
    b"NCH_END status=PASS\n"
)
if data.count(metric) != 1 or data.count(end) != 1:
    raise SystemExit("host-log interleaving fixture marker not found")
path.write_bytes(data.replace(metric, fragmented_metric, 1).replace(end, fragmented_end, 1))
PY
rm -f -- "$tmp/realtime-suite-host-log-interleaved/linux.log" \
    "$tmp/realtime-suite-host-log-interleaved/summary.json" \
    "$tmp/realtime-suite-host-log-interleaved/frames.csv" \
    "$tmp/realtime-suite-host-log-interleaved/summary.raw.json"
run_gate "$tmp/realtime-suite-host-log-interleaved" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "host-log interleaved RTBENCH records were rejected"

cp -a "$tmp/realtime-suite" "$tmp/realtime-suite-qemu-exit-after-cr"
python3 - "$tmp/realtime-suite-qemu-exit-after-cr/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
marker = b"[VM 3] RTBENCH_END status=PASS\n"
replacement = marker[:-1] + b"\rqemu-system-aarch64: terminating on signal 15\n"
if data.count(marker) != 1:
    raise SystemExit("QEMU exit-after-CR fixture marker not found")
path.write_bytes(data.replace(marker, replacement, 1))
PY
rm -f -- "$tmp/realtime-suite-qemu-exit-after-cr/linux.log" \
    "$tmp/realtime-suite-qemu-exit-after-cr/summary.json" \
    "$tmp/realtime-suite-qemu-exit-after-cr/frames.csv" \
    "$tmp/realtime-suite-qemu-exit-after-cr/summary.raw.json"
run_gate "$tmp/realtime-suite-qemu-exit-after-cr" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "QEMU exit text after a carriage-return benchmark marker was rejected"

make_fixture "$tmp/stability"
emit_stability 1 >> "$tmp/stability/console.log"
run_gate "$tmp/stability" stability --seconds 1 >/dev/null ||
    fail "stability fixture was rejected"

cp -a "$tmp/stability" "$tmp/stability-fragmented-metric"
python3 - "$tmp/stability-fragmented-metric/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
task3 = (
    b"[VM 3] TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 "
    b"applied_steps=6 retries=0\n[VM 3] TASK3_RTOS_FINAL_DONE\n"
)
fragmented = (
    b"[VM 3] R\nT0m\n\x00 connected\x00v] \x00ity_jitter r\n"
    b"un=1 expected=999 collected=999 p50_ns=1\n2 "
    b"missing=0 "
    b"pTASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0\n"
    b"TASK3_RTOS_FINAL_DONE\n"
    b"95_ns=1 p99_ns=1 p99_9_ns=1 max_ns=1 miss_100us=0 miss_500us=0 "
    b"miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=1 p99_cycles=1 "
    b"p99_9_cycles=1 max_cycles=1 mean_cycles=1 p50_instructions=1 "
    b"p95_instructions=1 p99_instructions=1 p99_9_instructions=1 "
    b"max_instructions=1 mean_instructions=1\n"
)
metric_lines = [
    line for line in data.splitlines(keepends=True)
    if b"RTBENCH metric=stability_jitter run=1" in line
]
if data.count(task3) != 1 or len(metric_lines) != 1:
    raise SystemExit("fragmented stability fixture markers not found")
data = data.replace(task3, b"", 1).replace(metric_lines[0], fragmented, 1)
path.write_bytes(data)
PY
rm -f -- "$tmp/stability-fragmented-metric/linux.log" \
    "$tmp/stability-fragmented-metric/summary.json" \
    "$tmp/stability-fragmented-metric/frames.csv" \
    "$tmp/stability-fragmented-metric/summary.raw.json"
run_gate "$tmp/stability-fragmented-metric" stability --seconds 1 >/dev/null ||
    fail "fragmented stability metric was rejected"

make_fixture "$tmp/stability-qemu-timer-limit"
emit_stability 1 >> "$tmp/stability-qemu-timer-limit/console.log"
sed -i \
    -e '0,/miss_1ms=0/s//miss_1ms=1/' \
    -e 's/RTBENCH_STABILITY_END status=PASS/RTBENCH_STABILITY_END status=FAIL/' \
    "$tmp/stability-qemu-timer-limit/console.log"
run_gate "$tmp/stability-qemu-timer-limit" stability --seconds 1 \
    --allow-qemu-timer-limit >/dev/null ||
    fail "explicit QEMU timer-limit diagnostic fixture was rejected"
if find "$tmp/stability-qemu-timer-limit" -maxdepth 1 -name '.console.*' -print -quit |
   grep -q .; then
    fail "diagnostic gate leaked an internal console normalization file"
fi

# The marker watcher terminates QEMU after RTBENCH_STABILITY_DONE when the
# benchmark reports QEMU-induced deadline misses. In that diagnostic mode the
# controlled nonzero QEMU exit is not an infrastructure error. The same exit
# must still be rejected without --allow-qemu-timer-limit and in other modes.
cp -a "$tmp/stability-qemu-timer-limit" "$tmp/stability-watched-qemu-exit"
run_gate "$tmp/stability-watched-qemu-exit" stability --seconds 1 \
    --allow-qemu-timer-limit > /dev/null || \
    fail "diagnostic stability gate rejected a watched QEMU termination"
expect_failure "diagnostic stability gate accepted nonzero QEMU exit without opt-in" \
    env "$GATE" --mode stability --log "$tmp/stability-watched-qemu-exit/console.log" \
        --output "$tmp/stability-watched-qemu-exit" --task2-count 2 --task3-frames 3 \
        --qemu-exit 1 --seconds 1
expect_failure "smoke gate accepted nonzero QEMU exit under timer-limit opt-in" \
    env "$GATE" --mode smoke --log "$tmp/smoke/console.log" \
        --output "$tmp/smoke" --task2-count 2 --task3-frames 3 \
        --qemu-exit 1 --allow-qemu-timer-limit

cp -a "$tmp/starryos" "$tmp/starryos-kernel-before-rtos-final"
python3 - "$tmp/starryos-kernel-before-rtos-final/console.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b"[VM 3] TASK3_RTOS_FINAL requests="
replacement = (
    b"[VM 1] \x1b[m\x1b[37m[ 74.433424 0:24 starry_kernel::task::ops:398] "
    b"\x1b[32mTask(24, \"task3-linux\") exit with code: 0\x1b[m\r\n"
    + needle
)
if data.count(needle) != 1:
    raise SystemExit("StarryOS/RTOS interleaving marker not found")
path.write_bytes(data.replace(needle, replacement, 1))
PY
rm -f -- "$tmp/starryos-kernel-before-rtos-final/starryos.log" \
    "$tmp/starryos-kernel-before-rtos-final/summary.json" \
    "$tmp/starryos-kernel-before-rtos-final/frames.csv" \
    "$tmp/starryos-kernel-before-rtos-final/summary.raw.json"
run_starry_gate "$tmp/starryos-kernel-before-rtos-final" >/dev/null ||
    fail "StarryOS kernel record before RTOS final marker was rejected"
grep -Fq "TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0" \
    "$tmp/starryos-kernel-before-rtos-final/rtthread.log" ||
    fail "StarryOS interleaving moved TASK3_RTOS_FINAL into the application log"

make_fixture "$tmp/task3"
run_gate "$tmp/task3" task3 >/dev/null || fail "task3 fixture was rejected"

for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
    make_fixture "$tmp/$profile" "$profile"
    run_gate "$tmp/$profile" task3-fault --task3-fault "$profile" >/dev/null ||
        fail "task3-fault fixture was rejected: $profile"
    [[ -s "$tmp/$profile/fault-event.json" ]] ||
        fail "task3-fault did not publish its current event: $profile"
    python3 - "$tmp/$profile/fault-event.json" "$profile" <<'PY'
import json
import sys
from pathlib import Path

event = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
if event.get("case") != sys.argv[2]:
    raise SystemExit("fault event did not come from the current profile")
if any(name in json.dumps(event) for name in (
    {"drop-control", "drop-status", "duplicate-frame", "delayed-server", "malformed"}
    - {sys.argv[2]}
)):
    raise SystemExit("fault event contains a synthetic profile")
PY
    [[ ! -e "$tmp/$profile/fault-summary.json" &&
       ! -e "$tmp/$profile/fault-events.csv" ]] ||
        fail "task3-fault synthesized suite-level evidence: $profile"
done

while read -r profile unsafe_condition; do
    unsafe_dir="$tmp/unsafe-$profile-$unsafe_condition"
    make_fixture "$unsafe_dir" "$profile"
    case "$profile/$unsafe_condition" in
        drop-control/retries)
            sed -i 's/,30000,10,1,0,0,100,/,30000,10,0,0,0,100,/' \
                "$unsafe_dir/console.log"
            ;;
        drop-status/retries)
            sed -i 's/applied_steps=6 retries=1/applied_steps=6 retries=0/' \
                "$unsafe_dir/console.log"
            ;;
        duplicate-frame/duplicates)
            sed -i 's/errors=0 duplicates=1/errors=0 duplicates=0/' \
                "$unsafe_dir/console.log"
            ;;
        duplicate-frame/applied-delta)
            sed -i '/TASK3_FAULT_DUPLICATE/s/applied_delta=0/applied_delta=1/' \
                "$unsafe_dir/console.log"
            ;;
        delayed-server/marker)
            sed -i '/TASK3_FAULT_DELAYED_SERVER/d' "$unsafe_dir/console.log"
            ;;
        malformed/application-errors)
            sed -i 's/errors=3 duplicates=0/errors=1 duplicates=0/' \
                "$unsafe_dir/console.log"
            ;;
        malformed/applied-delta)
            sed -i '/TASK3_FAULT_MALFORMED/s/applied_delta=0/applied_delta=1/' \
                "$unsafe_dir/console.log"
            ;;
        *) fail "unknown unsafe fault fixture: $profile/$unsafe_condition" ;;
    esac
    expect_failure "unsafe $profile event was accepted: $unsafe_condition" \
        run_gate "$unsafe_dir" task3-fault --task3-fault "$profile"
    [[ ! -e "$unsafe_dir/fault-event.json" ]] ||
        fail "unsafe $profile event was published: $unsafe_condition"
done <<'EOF'
drop-control retries
drop-status retries
duplicate-frame duplicates
duplicate-frame applied-delta
delayed-server marker
malformed application-errors
malformed applied-delta
EOF

make_fixture "$tmp/unprefixed-rtthread"
emit_suite 2 >> "$tmp/unprefixed-rtthread/console.log"
sed -i 's/^\[VM 3\] //' "$tmp/unprefixed-rtthread/console.log"
cat >> "$tmp/unprefixed-rtthread/console.log" <<'EOF'
TASK3_FAULT_DELAYED_SERVER delay_ms=3000
arbitrary Linux console text
RTIPC_FAILURE reason=clock_error
TASK3_SUMMARY_JSON={"forged":true}
EOF
run_gate "$tmp/unprefixed-rtthread" realtime-suite --rtbench-samples 2 >/dev/null ||
    fail "selected VM3 unprefixed RT-Thread events were rejected"
grep -Fq 'RTIPC_SERVER_READY ip=192.168.77.30 port=9876' \
    "$tmp/unprefixed-rtthread/rtthread.log" ||
    fail "unprefixed RT-Thread event was not extracted"
grep -Fq 'RTBENCH_END status=PASS' "$tmp/unprefixed-rtthread/rtthread.log" ||
    fail "unprefixed RT benchmark event was not extracted"
grep -Fq 'TASK3_FAULT_DELAYED_SERVER delay_ms=3000' \
    "$tmp/unprefixed-rtthread/rtthread.log" ||
    fail "unprefixed delayed-server marker was not extracted"
if grep -Fq 'arbitrary Linux console text' "$tmp/unprefixed-rtthread/rtthread.log" ||
   grep -Fq 'RTIPC_FAILURE reason=clock_error' "$tmp/unprefixed-rtthread/rtthread.log" ||
   grep -Fq 'TASK3_SUMMARY_JSON=' "$tmp/unprefixed-rtthread/rtthread.log"; then
    fail "unprefixed Linux output leaked into the RT-Thread log"
fi

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
