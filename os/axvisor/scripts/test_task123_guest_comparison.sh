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
mode=
output=
task2_count=
task3_frames=3
seconds=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-guest) guest=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --task2-count) task2_count=$2; shift 2 ;;
        --task3-frames) echo "stability runner must use its default frame count" >&2; exit 99 ;;
        --seconds) seconds=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s %s %s %s %s\n' "$guest" "$mode" "$task2_count" "$task3_frames" "$seconds" \
    "${TASK123_SHARED_ARTIFACT_DIR:?}" >> "${TASK123_COMPARISON_TRACE:?}"
mkdir -p "$output"
python3 - "$output" "$guest" "$mode" "$task2_count" "$task3_frames" "$seconds" <<'PY'
import json
import sys
from pathlib import Path

run, guest, mode, count, frames, seconds = sys.argv[1:]
root = Path(run)
common = [
    ("qemu", "a"),
    ("rtthread-normal", "b"),
    ("rtthread-drop-status", "c"),
    ("rtthread-delayed-server", "d"),
    ("rootfs", "e"),
    ("model", "f"),
    ("protocol-source", "1"),
    ("protocol-header", "2"),
]
manifest = [
    "schema=1",
    f"app_guest={guest}",
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
(root / "rtthread.log").write_text(
    "RTBENCH metric=stability_jitter expected=10 collected=10 missing=0 "
    "p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 "
    "miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n"
    "RTBENCH metric=callback_exec expected=10 collected=10 missing=0 "
    "p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 "
    "miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n",
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
if ! TASK123_COMPARISON_RUNNER="$runner" \
    TASK123_COMPARISON_TRACE="$trace" \
    TASK123_COMPARISON_ANALYZER="$ANALYZER" \
    "$ORCHESTRATOR" --quick --output "$output" >/dev/null; then
    [[ ! -f "$output/orchestrator.log" ]] || cat "$output/orchestrator.log" >&2
    fail "quick guest comparison failed"
fi

[[ -s "$output/linux/manifest.txt" ]] || fail "Linux run output is missing"
[[ -s "$output/starryos/manifest.txt" ]] || fail "StarryOS run output is missing"
[[ -s "$output/comparison/comparison.json" ]] || fail "comparison JSON is missing"
[[ -s "$output/comparison/comparison-report.md" ]] || fail "comparison report is missing"
[[ "$(wc -l < "$trace")" -eq 2 ]] || fail "orchestrator did not run both guests exactly once"
awk '$1 == "linux" && $2 == "stability" && $3 == 30000 && $4 == 3 && $5 == 300 {next} $1 == "starryos" && $2 == "stability" && $3 == 30000 && $4 == 3 && $5 == 300 {next} {exit 1}' "$trace" ||
    fail "quick comparison did not use the specified workload"
cache_one="$(awk 'NR == 1 {print $6}' "$trace")"
cache_two="$(awk 'NR == 2 {print $6}' "$trace")"
[[ "$cache_one" == "$cache_two" ]] || fail "guests did not share one artifact cache"
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
awk '$1 == "linux" && $2 == "stability" && $3 == 240000 && $4 == 3 && $5 == 3600 {next} $1 == "starryos" && $2 == "stability" && $3 == 240000 && $4 == 3 && $5 == 3600 {next} {exit 1}' "$full_trace" ||
    fail "full comparison did not use the formal workload"
[[ -s "$full_output/comparison/comparison-report.md" ]] ||
    fail "full comparison report is missing"

echo "PASS: StarryOS/Linux guest comparison orchestrator contract"
