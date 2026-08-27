#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$TASK3_ROOT/build"
RTIPC_DIR=${RTIPC_DIR:-"$TASK3_ROOT/../rt-ipc/common"}
qemu=$(command -v qemu-system-aarch64 || true)
if [ -x "$HOME/.local/qemu-arm/bin/qemu-system-aarch64" ]; then
    qemu="$HOME/.local/qemu-arm/bin/qemu-system-aarch64"
fi
frames=600
multicast_port=10077
smoke=0
fault_case=normal
evidence_mode=migration-baseline
requested_run_dir=
rtthread_pid=
linux_pid=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --frames) frames=$2; shift 2 ;;
        --multicast-port) multicast_port=$2; shift 2 ;;
        --smoke) smoke=1; shift ;;
        --fault-case) fault_case=$2; shift 2 ;;
        --evidence-mode) evidence_mode=$2; shift 2 ;;
        --run-dir) requested_run_dir=$2; shift 2 ;;
        *) echo "usage: $0 [--frames N] [--multicast-port PORT] [--smoke] [--fault-case CASE] [--evidence-mode migration-baseline] [--run-dir DIR]" >&2; exit 2 ;;
    esac
done
case "$evidence_mode" in
    migration-baseline) ;;
    final)
        echo "AxVisor final evidence must be collected with os/axvisor/scripts/run_task123.sh" >&2
        exit 2
        ;;
    *) echo "unknown evidence mode: $evidence_mode" >&2; exit 2 ;;
esac
case "$frames:$multicast_port" in
    *[!0-9:]*|0:*|*:0) echo "invalid frames or multicast port" >&2; exit 2 ;;
esac
[ "$frames" -le 600 ] || { echo "frames must be <= 600" >&2; exit 2; }
[ "$multicast_port" -le 65535 ] || { echo "multicast port must be <= 65535" >&2; exit 2; }

linux_image="$BUILD_DIR/images/linux/Image"
linux_initrd="$BUILD_DIR/images/linux/rootfs.cpio"
rtthread_image="$BUILD_DIR/images/rtthread/rtthread.bin"
linux_extra_append=
linux_first_delay=0
case "$fault_case" in
    normal) ;;
    drop-control) linux_extra_append='task3.drop_tx_seq=2' ;;
    drop-status)
        rtthread_image="$BUILD_DIR/images/rtthread/rtthread-drop-status.bin"
        ;;
    duplicate-frame) linux_extra_append='task3.duplicate_frame_once=1' ;;
    delayed-server) linux_first_delay=3 ;;
    malformed) linux_extra_append='task3.malformed_once=1' ;;
    *) echo "unknown fault case: $fault_case" >&2; exit 2 ;;
esac
for image in "$linux_image" "$linux_initrd" "$rtthread_image"; do
    [ -s "$image" ] || { echo "missing image: $image" >&2; exit 1; }
done
[ -x "$qemu" ] || { echo "qemu-system-aarch64 not found" >&2; exit 1; }
[ -s "$RTIPC_DIR/rt_ipc.h" ] && [ -s "$RTIPC_DIR/rt_ipc.c" ] || {
    echo "RT-IPC C source not found: $RTIPC_DIR" >&2
    exit 1
}

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$requested_run_dir" ]; then
    run_dir=$requested_run_dir
else
    run_dir="$TASK3_ROOT/build/runs/$timestamp-$fault_case-$$"
fi
mkdir -p "$run_dir"
rtthread_log="$run_dir/rtthread.log"
linux_log="$run_dir/linux.log"

cleanup() {
    if [ -n "$linux_pid" ]; then
        kill "$linux_pid" 2>/dev/null || true
        wait "$linux_pid" 2>/dev/null || true
        linux_pid=
    fi
    if [ -n "$rtthread_pid" ]; then
        kill "$rtthread_pid" 2>/dev/null || true
        wait "$rtthread_pid" 2>/dev/null || true
        rtthread_pid=
    fi
}
trap cleanup EXIT HUP INT TERM

cat >"$run_dir/commands.txt" <<EOF
$qemu -M virt,gic-version=2 -cpu cortex-a53 -smp 1 -m 128M -kernel "$rtthread_image" -netdev socket,id=net0,mcast=230.77.0.1:$multicast_port -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:30 -nographic -no-reboot
$qemu -M virt,gic-version=2 -cpu cortex-a53 -smp 2 -m 256M -kernel "$linux_image" -initrd "$linux_initrd" -append "console=ttyAMA0 rdinit=/sbin/init task3.frames=$frames $linux_extra_append" -netdev socket,id=net0,mcast=230.77.0.1:$multicast_port -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:11 -nographic -no-reboot
EOF
"$qemu" --version >"$run_dir/versions.txt"
printf 'frames=%s\nmulticast_port=%s\nsmoke=%s\nfault_case=%s\nevidence_mode=%s\n' \
    "$frames" "$multicast_port" "$smoke" "$fault_case" "$evidence_mode" \
    >>"$run_dir/versions.txt"
printf 'git_sha=%s\ngit_status=%s\n' \
    "$(git -C "$TASK3_ROOT" rev-parse HEAD)" \
    "$(test -z "$(git -C "$TASK3_ROOT" status --porcelain)" && printf clean || printf dirty)" \
    >>"$run_dir/versions.txt"
sha256sum "$linux_image" "$linux_initrd" "$rtthread_image" \
    "$BUILD_DIR/model/model_weights.h" "$RTIPC_DIR/rt_ipc.h" \
    "$RTIPC_DIR/rt_ipc.c" >>"$run_dir/versions.txt"
python3 -c 'import numpy; print("numpy=" + numpy.__version__)' \
    >>"$run_dir/versions.txt"
uname -a >>"$run_dir/versions.txt"
uptime >>"$run_dir/versions.txt"

start_rtthread() {
    "$qemu" -M virt,gic-version=2 -cpu cortex-a53 -smp 1 -m 128M \
        -kernel "$rtthread_image" \
        -netdev socket,id=net0,mcast=230.77.0.1:"$multicast_port" \
        -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:30 \
        -nographic -no-reboot 2>&1 | tee -- "$rtthread_log" &
    rtthread_pid=$!
}

start_linux() {
    "$qemu" -M virt,gic-version=2 -cpu cortex-a53 -smp 2 -m 256M \
        -kernel "$linux_image" -initrd "$linux_initrd" \
        -append "console=ttyAMA0 rdinit=/sbin/init task3.frames=$frames $linux_extra_append" \
        -netdev socket,id=net0,mcast=230.77.0.1:"$multicast_port" \
        -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:11 \
        -nographic -no-reboot 2>&1 | tee -- "$linux_log" &
    linux_pid=$!
}

if [ "$linux_first_delay" -gt 0 ]; then
    start_linux
    "$SCRIPT_DIR/wait_for_marker.sh" "$linux_log" TASK3_LINUX_READY 60 "$linux_pid"
    sleep "$linux_first_delay"
    start_rtthread
    "$SCRIPT_DIR/wait_for_marker.sh" "$rtthread_log" TASK3_RTOS_READY 60 "$rtthread_pid"
else
    start_rtthread
    "$SCRIPT_DIR/wait_for_marker.sh" "$rtthread_log" TASK3_RTOS_READY 60 "$rtthread_pid"
    start_linux
fi
"$SCRIPT_DIR/wait_for_marker.sh" "$linux_log" TASK3_SUMMARY_JSON= 180 "$linux_pid"
"$SCRIPT_DIR/wait_for_marker.sh" "$rtthread_log" TASK3_RTOS_FINAL 10 "$rtthread_pid"

cleanup
expected=$((frames * 2))
actual=$(grep -c '^TASK3_FRAME_CSV=' "$linux_log" || true)
[ "$actual" -eq "$expected" ] || { echo "expected $expected frame rows, found $actual" >&2; exit 1; }
summary_count=$(grep -c '^TASK3_SUMMARY_JSON=' "$linux_log" || true)
[ "$summary_count" -eq 1 ] || { echo "expected one summary marker, found $summary_count" >&2; exit 1; }

{
    printf '%s\n' '# task3_csv_schema=1'
    printf '%s\n' 'mode,frame_id,target_q15,truth_class,predicted_class,confidence_q15,inference_us,transport_retries,rtos_status,pwm,actuator_q15,rtos_processing_us,round_trip_us,error_code,duplicate,recovered'
    sed -n 's/^TASK3_FRAME_CSV=//p' "$linux_log"
} >"$run_dir/frames.csv"
sed -n 's/^TASK3_SUMMARY_JSON=//p' "$linux_log" >"$run_dir/summary.raw.json"
if [ "$smoke" -eq 1 ]; then
    python3 "$SCRIPT_DIR/summarize.py" --run-dir "$run_dir" --frames-per-mode "$frames" --smoke
else
    python3 "$SCRIPT_DIR/summarize.py" --run-dir "$run_dir" --frames-per-mode "$frames"
fi
printf 'run_dir=%s\n' "$run_dir"
