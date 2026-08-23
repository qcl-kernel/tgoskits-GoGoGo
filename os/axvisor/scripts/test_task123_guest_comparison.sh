#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ORCHESTRATOR="$ROOT/os/axvisor/scripts/run_task123_guest_comparison.sh"
ANALYZER="$ROOT/os/axvisor/scripts/compare_task123_guests.py"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[[ -x "$ORCHESTRATOR" ]] || fail "comparison orchestrator is missing or not executable"
[[ -x "$ANALYZER" ]] || fail "comparison analyzer is missing or not executable"

runner="$tmp/fake-runner.sh"
trace="$tmp/runner.trace"
cat > "$runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
guest=linux
rtos=rtthread
mode=
output=
task2_count=
task3_frames=3
seconds=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-guest) guest=$2; shift 2 ;;
        --rtos) rtos=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --task2-count) task2_count=$2; shift 2 ;;
        --task3-frames)
            if [[ "$mode" == stability ]]; then
                echo "stability runner must use its default frame count" >&2
                exit 99
            fi
            task3_frames=$2
            shift 2
            ;;
        --seconds) seconds=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$mode" == smoke && -n "$seconds" ]]; then
    echo "smoke runner must not receive a stability duration" >&2
    exit 98
fi
if [[ "${TASK123_COMPARISON_EXPECT_RUNNING:-0}" == 1 ]]; then
    grep -Fxq 'status=RUNNING' "$(dirname -- "$output")/comparison-manifest.txt" ||
        { echo "comparison manifest is not RUNNING while a guest starts" >&2; exit 18; }
    if grep -Eq '^stability_gate=PASS' "$(dirname -- "$output")/comparison-manifest.txt"; then
        echo "running comparison manifest advertises a passing gate" >&2
        exit 19
    fi
fi
if [[ "${TASK123_COMPARISON_SIGNAL_PARENT:-0}" == 1 ]]; then
    kill -TERM "$PPID"
    sleep 1
fi
if [[ "${TASK123_COMPARISON_FAIL_GUEST:-}" == "$guest" ]]; then
    exit 17
fi
printf '%s %s %s %s %s %s %s %s %s\n' "$guest" "$mode" "$task2_count" "$task3_frames" "${seconds:--}" \
    "${TASK123_SHARED_ARTIFACT_DIR:?}" "${TASK123_TIMEOUT_S:?}" "${rtos:?}" \
    "${QEMU_TCG_THREAD:-unset}" >> "${TASK123_COMPARISON_TRACE:?}"
mkdir -p "$output"
python3 - "$output" "$guest" "$mode" "$task2_count" "$task3_frames" "$seconds" "$rtos" <<'PY'
import json
import sys
from pathlib import Path

run, guest, mode, count, frames, seconds, rtos = sys.argv[1:]
root = Path(run)
common = [
    ("qemu", "a"),
    (rtos, "b"),
    ("rootfs", "e"),
    ("model", "f"),
    ("protocol-source", "1"),
    ("protocol-header", "2"),
]
manifest = [
    "schema=1",
    f"app_guest={guest}",
    f"rtos={rtos}",
    f"mode={mode}",
    f"task2_count={count}",
    f"task3_frames={frames}",
    "task3_fault=normal",
    "qemu_timer_slack_ns=1",
    "result_gate=PASS",
]
for label, char in common:
    manifest.append(f"ARTIFACT name={label} path=/cache/{label} sha256={char * 64}")
(root / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="ascii")
sections = []
for payload in (64, 256, 1024):
    sections.extend([
        f"--- Payload {payload}B ---",
        f"sent={count} recv={count}",
        "RTT: min=1ms avg=2ms P50=2ms P95=3ms P99=4ms P99.9=5ms max=6ms",
        "throughput=10.00KiB/s",
        "request_timeouts=0 protocol_errors=0 reconnects=0",
        "transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0",
    ])
(root / f"{guest}.log").write_text("\n".join(sections) + "\n", encoding="ascii")
counter_fields = (
    "p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 "
    "p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 "
    "max_instructions=5 mean_instructions=2"
)
(root / "rtthread.log").write_text(
    "RTBENCH metric=stability_jitter expected=10 collected=10 missing=0 "
    "p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 "
    f"miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 {counter_fields}\n"
    "RTBENCH metric=callback_exec expected=10 collected=10 missing=0 "
    "p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 "
    f"miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 {counter_fields}\n",
    encoding="ascii",
)
(root / "summary.json").write_text(json.dumps({
    "success_rate": 1.0,
    "inference_us": {"mean": 1, "p95": 2, "p99": 3, "max": 4},
    "round_trip_us": {"mean": 2, "p95": 3, "p99": 4, "max": 5},
    "rtos_processing_us": {"mean": 1, "p95": 2, "p99": 3, "max": 4},
}) + "\n", encoding="ascii")
(root / "host-metrics.txt").write_text(
    "elapsed_ms=1000\ncpu_time_ms=500\npeak_rss_kb=100\nmax_threads=4\nsample_count=10\n",
    encoding="ascii",
)
(root / "console.log").write_text("result_gate=PASS\n", encoding="ascii")
PY
EOF
chmod +x "$runner"

output="$tmp/comparison-output"
explicit_cache="$tmp/explicit-cache"
mkdir -- "$explicit_cache"
if ! TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$trace" \
    TASK123_COMPARISON_ANALYZER="$ANALYZER" \
    TASK123_COMPARISON_EXPECT_RUNNING=1 \
    "$ORCHESTRATOR" --quick --cache "$explicit_cache" --output "$output" >/dev/null; then
    [[ ! -f "$output/orchestrator.log" ]] || cat "$output/orchestrator.log" >&2
    fail "quick guest comparison failed"
fi

[[ -s "$output/linux/manifest.txt" ]] || fail "Linux run output is missing"
[[ -s "$output/starryos/manifest.txt" ]] || fail "StarryOS run output is missing"
[[ -s "$output/comparison/comparison.json" ]] || fail "comparison JSON is missing"
[[ -s "$output/comparison/comparison-report.md" ]] || fail "comparison report is missing"
[[ "$(grep '^rtos=' "$output/linux/manifest.txt")" == rtos=rtthread ]] ||
    fail "default comparison did not select RT-Thread"
grep -Fxq 'rtos=rtthread' "$output/comparison-manifest.txt" ||
    fail "default comparison manifest did not record RT-Thread"
grep -Fxq 'status=COMPLETE' "$output/comparison-manifest.txt" ||
    fail "successful comparison manifest is not complete"
grep -Fxq 'stability_gate=PASS' "$output/comparison-manifest.txt" ||
    fail "successful comparison manifest lacks its final gate"
[[ "$(wc -l < "$trace")" -eq 2 ]] || fail "orchestrator did not run both guests exactly once"
awk '$1 == "linux" && $2 == "stability" && $3 == 30000 && $4 == 3 && $5 == 300 && $7 == 6900 {next} $1 == "starryos" && $2 == "stability" && $3 == 30000 && $4 == 3 && $5 == 300 && $7 == 6900 {next} {exit 1}' "$trace" ||
    fail "quick comparison did not use the specified workload"
cache_one="$(awk 'NR == 1 {print $6}' "$trace")"
cache_two="$(awk 'NR == 2 {print $6}' "$trace")"
[[ "$cache_one" == "$cache_two" ]] || fail "guests did not share one artifact cache"
[[ "$cache_one" == "$(realpath -e -- "$explicit_cache")" ]] ||
    fail "orchestrator did not use the explicit artifact cache"
case "$cache_one" in
    "$output"/*) fail "shared artifact cache is nested in output" ;;
esac

full_output="$tmp/formal-comparison-output"
full_trace="$tmp/formal.trace"
if ! TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$full_trace" \
    TASK123_COMPARISON_ANALYZER="$ANALYZER" \
    "$ORCHESTRATOR" --full --output "$full_output" >/dev/null; then
    [[ ! -f "$full_output/orchestrator.log" ]] || cat "$full_output/orchestrator.log" >&2
    fail "full guest comparison failed"
fi
[[ "$(wc -l < "$full_trace")" -eq 2 ]] || fail "full comparison did not run both guests exactly once"
awk '$1 == "linux" && $2 == "stability" && $3 == 240000 && $4 == 3 && $5 == 3600 && $7 == 23400 {next} $1 == "starryos" && $2 == "stability" && $3 == 240000 && $4 == 3 && $5 == 3600 && $7 == 23400 {next} {exit 1}' "$full_trace" ||
    fail "full comparison did not use the formal workload"
[[ -s "$full_output/comparison/comparison-report.md" ]] ||
    fail "full comparison report is missing"

failed_output="$tmp/failed-comparison-output"
if TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$tmp/failed.trace" \
    TASK123_COMPARISON_ANALYZER="$ANALYZER" \
    TASK123_COMPARISON_FAIL_GUEST=linux \
    "$ORCHESTRATOR" --quick --output "$failed_output" >/dev/null 2>&1; then
    fail "runner failure was accepted by the comparison orchestrator"
fi
grep -Fxq 'status=FAILED' "$failed_output/comparison-manifest.txt" ||
    fail "failed comparison manifest does not record FAILED"
if grep -Eq '^stability_gate=PASS' "$failed_output/comparison-manifest.txt"; then
    fail "failed comparison manifest advertises a passing stability gate"
fi

interrupted_output="$tmp/interrupted-comparison-output"
if TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$tmp/interrupted.trace" \
    TASK123_COMPARISON_ANALYZER="$ANALYZER" \
    TASK123_COMPARISON_SIGNAL_PARENT=1 \
    "$ORCHESTRATOR" --quick --output "$interrupted_output" >/dev/null 2>&1; then
    fail "interrupted comparison was accepted"
fi
grep -Fxq 'status=INTERRUPTED' "$interrupted_output/comparison-manifest.txt" ||
    fail "interrupted comparison manifest does not record INTERRUPTED"
if grep -Eq '^stability_gate=PASS' "$interrupted_output/comparison-manifest.txt"; then
    fail "interrupted comparison manifest advertises a passing stability gate"
fi
if find "$failed_output" "$interrupted_output" -maxdepth 1 \
    -name '.comparison-manifest.*' -print | grep -q .; then
    fail "atomic comparison manifest publication left temporary files"
fi

echo "PASS: StarryOS/Linux guest comparison orchestrator contract"

single_output="$tmp/zephyr-linux-output"
single_trace="$tmp/zephyr-linux.trace"
if ! TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$single_trace" \
    "$ORCHESTRATOR" --quick --rtos zephyr --app-guest linux \
        --output "$single_output" >/dev/null; then
    fail "single RTOS/app-guest combination failed"
fi
[[ "$(wc -l < "$single_trace")" -eq 1 ]] ||
    fail "single combination must invoke the runner exactly once"
awk '$1 == "linux" && $2 == "stability" && $3 == 30000 && $4 == 3 &&
     $5 == 300 && $8 == "zephyr" {next} {exit 1}' "$single_trace" ||
    fail "single combination did not pass the selected RTOS"
[[ -s "$single_output/zephyr-linux/manifest.txt" ]] ||
    fail "single combination output uses a non-unique directory"
grep -Fxq 'rtos=zephyr' "$single_output/comparison-manifest.txt" &&
    grep -Fxq 'app_guest=linux' "$single_output/comparison-manifest.txt" &&
grep -Fxq 'single_combination=1' "$single_output/comparison-manifest.txt" ||
    fail "single combination manifest did not record its selectors"
grep -Fxq 'status=COMPLETE' "$single_output/comparison-manifest.txt" ||
    fail "single combination manifest is not complete"

matrix_output="$tmp/matrix-output"
matrix_trace="$tmp/matrix.trace"
if ! TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$matrix_trace" \
    "$ORCHESTRATOR" --quick --matrix all --output "$matrix_output" >/dev/null; then
    fail "four-combination matrix failed"
fi
[[ "$(wc -l < "$matrix_trace")" -eq 4 ]] ||
    fail "matrix must run four combinations exactly once"
awk '
    $1 == "linux" && $2 == "smoke" && $3 == 10 && $5 == "-" && $8 == "rtthread" {rtthread_linux++; next}
    $1 == "starryos" && $2 == "smoke" && $3 == 10 && $5 == "-" && $8 == "rtthread" {rtthread_starryos++; next}
    $1 == "linux" && $2 == "smoke" && $3 == 10 && $5 == "-" && $8 == "zephyr" {zephyr_linux++; next}
    $1 == "starryos" && $2 == "smoke" && $3 == 10 && $5 == "-" && $8 == "zephyr" {zephyr_starryos++; next}
    {exit 1}
    END {
        if (rtthread_linux != 1 || rtthread_starryos != 1 ||
            zephyr_linux != 1 || zephyr_starryos != 1) exit 1
    }
' "$matrix_trace" || fail "matrix did not cover each RTOS/app-guest pair once"
awk '$9 != "multi" {exit 1}' "$matrix_trace" ||
    fail "quick matrix must use multi-threaded TCG"
for combination in rtthread-linux rtthread-starryos zephyr-linux zephyr-starryos; do
    [[ -s "$matrix_output/$combination/manifest.txt" ]] ||
        fail "matrix output is missing $combination"
done

grep -q '^stability_seconds=1$' "$matrix_output/comparison-manifest.txt" &&
    grep -q '^task2_count=10$' "$matrix_output/comparison-manifest.txt" ||
    fail "quick matrix did not record its reduced workload"
grep -Fxq 'matrix=all' "$matrix_output/comparison-manifest.txt" &&
    grep -Fxq 'rtos_order=rtthread,zephyr' "$matrix_output/comparison-manifest.txt" &&
    grep -Fxq 'app_guest_order=linux,starryos' "$matrix_output/comparison-manifest.txt" ||
    fail "matrix manifest did not record all selector dimensions"
grep -Fxq 'status=COMPLETE' "$matrix_output/comparison-manifest.txt" ||
    fail "matrix manifest is not complete"

echo "PASS: RTOS/app-guest matrix orchestrator contract"
