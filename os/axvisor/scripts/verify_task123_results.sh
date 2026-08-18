#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
SUMMARIZE="$ROOT/os/axvisor/guests/task3/scripts/summarize.py"
SUMMARIZE_FAULTS="$ROOT/os/axvisor/guests/task3/scripts/summarize_faults.py"

usage() {
    echo "usage: $0 [--app-guest linux|starryos] --mode MODE --log LOG --output DIR --task2-count N --task3-frames N --qemu-exit N [--rtbench-samples N] [--seconds N] [--task3-fault PROFILE]" >&2
    exit 2
}

die() {
    echo "task123 result gate: $*" >&2
    exit 1
}

require_positive() {
    local label=$1
    local value=$2
    local maximum=$3
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le "$maximum" ]] ||
        usage
}

mode=
app_guest=linux
log=
output=
task2_count=
task3_frames=
qemu_exit=
rtbench_samples=
seconds=
task3_fault=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-guest|--mode|--log|--output|--task2-count|--task3-frames|--qemu-exit|--rtbench-samples|--seconds|--task3-fault)
            [[ $# -ge 2 ]] || usage
            option=$1
            value=$2
            shift 2
            case "$option" in
                --app-guest) app_guest=$value ;;
                --mode) mode=$value ;;
                --log) log=$value ;;
                --output) output=$value ;;
                --task2-count) task2_count=$value ;;
                --task3-frames) task3_frames=$value ;;
                --qemu-exit) qemu_exit=$value ;;
                --rtbench-samples) rtbench_samples=$value ;;
                --seconds) seconds=$value ;;
                --task3-fault) task3_fault=$value ;;
            esac
            ;;
        *) usage ;;
    esac
done

[[ -n "$mode" && -n "$log" && -n "$output" && -n "$task2_count" &&
   -n "$task3_frames" && -n "$qemu_exit" ]] || usage
case "$app_guest" in
    linux|starryos) ;;
    *) usage ;;
esac
require_positive task2-count "$task2_count" 2147483647
require_positive task3-frames "$task3_frames" 600
[[ "$qemu_exit" =~ ^[0-9]+$ && "$qemu_exit" -le 255 ]] || usage
[[ -f "$log" && -r "$log" ]] || die "console log is missing or unreadable: $log"
[[ -d "$output" && -w "$output" ]] || die "output directory is missing or unwritable: $output"

case "$mode" in
    smoke|task3)
        [[ -z "$rtbench_samples" && -z "$seconds" && -z "$task3_fault" ]] || usage
        ;;
    realtime-suite)
        [[ -n "$rtbench_samples" && -z "$seconds" && -z "$task3_fault" ]] || usage
        require_positive rtbench-samples "$rtbench_samples" 100000
        ;;
    stability)
        [[ -n "$seconds" && -z "$rtbench_samples" && -z "$task3_fault" ]] || usage
        require_positive seconds "$seconds" 3600
        ;;
    task3-fault)
        [[ -n "$task3_fault" && -z "$rtbench_samples" && -z "$seconds" ]] || usage
        case "$task3_fault" in
            drop-control|drop-status|duplicate-frame|delayed-server|malformed) ;;
            *) usage ;;
        esac
        ;;
    *) usage ;;
esac

[[ "$qemu_exit" -eq 0 ]] || die "QEMU failed with exit code $qemu_exit"
if grep -aEiq 'panicked at|kernel panic|assertion failed|RT-Thread[^[:cntrl:]]*assert|(^|[^[:alpha:]])fatal([^[:alpha:]]|$)|status=FAIL|TESTS FAILED' "$log"; then
    die "panic, assertion, fatal error, or failed status found in console log"
fi

require_exact_marker() {
    local marker=$1
    local count
    count="$(grep -aFo -- "$marker" "$log" | wc -l)"
    [[ "$count" -eq 1 ]] || die "marker must occur exactly once: $marker (found $count)"
}

if [[ "$app_guest" == linux ]]; then
    app_smp_marker='LINUX_SMP_READY configured=2'
    app_net_marker='TASK123_LINUX_NET_READY'
    app_task2_marker='TASK2_LINUX_END status=PASS'
    app_task3_marker='TASK3_LINUX_END status=PASS'
    app_task123_marker='TASK123_LINUX_END status=PASS'
else
    app_smp_marker='STARRY_SMP_READY configured=2'
    app_net_marker='STARRY_NET_READY'
    app_task2_marker='TASK2_STARRY_END status=PASS'
    app_task3_marker='TASK3_STARRY_END status=PASS'
    app_task123_marker='TASK123_STARRY_END status=PASS'
fi

for marker in \
    "$app_smp_marker" \
    "$app_net_marker" \
    'RTIPC_SERVER_READY ip=192.168.77.30 port=9876' \
    'TASK3_RTOS_READY ip=192.168.77.30 port=9877' \
    "$app_task2_marker" \
    "$app_task3_marker" \
    "$app_task123_marker"; do
    require_exact_marker "$marker"
done
if [[ "$mode" == realtime-suite ]]; then
    require_exact_marker 'RTBENCH_END status=PASS'
elif [[ "$mode" == stability ]]; then
    require_exact_marker 'RTBENCH_STABILITY_END status=PASS'
fi

"$SCRIPT_DIR/verify_rtipc_results.sh" "$log" "$task2_count" "$qemu_exit" none "$app_guest"
if [[ "$mode" == realtime-suite ]]; then
    "$SCRIPT_DIR/verify_rtbench_suite.sh" "$log" "$rtbench_samples" "$qemu_exit"
elif [[ "$mode" == stability ]]; then
    "$SCRIPT_DIR/verify_rtbench_stability.sh" "$log" "$seconds" "$qemu_exit"
fi

app_log="$output/${app_guest}.log"
rtthread_log="$output/rtthread.log"
frames_csv="$output/frames.csv"
raw_summary="$output/summary.raw.json"
app_tmp="$output/.${app_guest}.log.tmp"
rtthread_tmp="$output/.rtthread.log.tmp"
frames_tmp="$output/.frames.csv.tmp"
summary_tmp="$output/.summary.raw.json.tmp"
trap 'rm -f -- "$app_tmp" "$rtthread_tmp" "$frames_tmp" "$summary_tmp"' EXIT

awk '
    /^\[VM 1\] / {
        sub(/^\[VM 1\] /, "")
        print
        next
    }
    /^\[Axvisor\] attached VM\[1\] console;/ {
        attached_linux = 1
        next
    }
    /^\[Axvisor\] attached VM\[[0-9]+\] console;/ ||
    /^Welcome to AxVisor Shell!/ {
        attached_linux = 0
        next
    }
    attached_linux { print }
' "$log" > "$app_tmp"
awk '
    /^\[VM 3\] / {
        sub(/^\[VM 3\] /, "")
        print
        next
    }
    /^(RTIPC_SERVER_|TASK3_RTOS_|TASK3_FAULT_(DROP_STATUS|DELAYED_SERVER)([[:space:]]|$)|RTBENCH([_[:space:]]|$))/ {
        print
    }
' "$log" > "$rtthread_tmp"
summary_count="$(grep -c '^TASK3_SUMMARY_JSON=' "$app_tmp" || true)"
[[ "$summary_count" -eq 1 ]] ||
    die "authenticated $app_guest Task 3 summary must occur exactly once (found $summary_count)"
frame_count="$(grep -c '^TASK3_FRAME_CSV=' "$app_tmp" || true)"
[[ "$frame_count" -eq $((task3_frames * 2)) ]] ||
    die "Task 3 frame rows are missing or duplicated (found $frame_count)"

{
    echo '# task3_csv_schema=1'
    echo 'mode,frame_id,target_q15,truth_class,predicted_class,confidence_q15,inference_us,transport_retries,rtos_status,pwm,actuator_q15,rtos_processing_us,round_trip_us,error_code,duplicate,recovered'
    sed -n 's/^TASK3_FRAME_CSV=//p' "$app_tmp"
} > "$frames_tmp"
sed -n 's/^TASK3_SUMMARY_JSON=//p' "$app_tmp" > "$summary_tmp"
mv -- "$app_tmp" "$app_log"
mv -- "$rtthread_tmp" "$rtthread_log"
mv -- "$frames_tmp" "$frames_csv"
mv -- "$summary_tmp" "$raw_summary"
trap - EXIT

summarize_args=(
    python3 "$SUMMARIZE"
    --run-dir "$output"
    --frames-per-mode "$task3_frames"
)
if [[ "$mode" != task3 || "$task3_frames" -ne 600 ]]; then
    summarize_args+=(--smoke)
fi
"${summarize_args[@]}"

if [[ "$mode" == task3-fault ]]; then
    python3 - "$SUMMARIZE_FAULTS" "$task3_fault" "$output" <<'PY'
import importlib.util
import sys
from pathlib import Path

module_path = Path(sys.argv[1])
profile = sys.argv[2]
run_dir = Path(sys.argv[3])
sys.path.insert(0, str(module_path.parent))
spec = importlib.util.spec_from_file_location("task123_summarize_faults", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("unable to load summarize_faults.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
event = module.collect_event(profile, run_dir)
module.validate_event(event)
module.write_json_atomic(run_dir / "fault-event.json", event)
PY
fi

echo "PASS: integrated Task 1/2/3 evidence accepted for mode=$mode"
