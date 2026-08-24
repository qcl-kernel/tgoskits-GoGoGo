#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY_PATCHES="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
LAYOUT_PATCH="$ROOT/os/axvisor/patches/rtthread/0009-native-qemu-memory-layout.patch"
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
VERIFY="$SCRIPT_DIR/verify_rtbench_stability.sh"
VERIFY_SUITE="$SCRIPT_DIR/verify_rtbench_suite.sh"
QEMU_REALTIME_CONTROL="$SCRIPT_DIR/apply_qemu_realtime_controls.sh"
NET_PROBE="$SCRIPT_DIR/send_rtbench_net_probe.py"
IMAGE_METADATA="$SCRIPT_DIR/rtthread_image_metadata.py"
RTTHREAD_INPUT_DIGEST="$(python3 "$IMAGE_METADATA" input-digest --root "$ROOT")"

QEMU="${QEMU:-$(command -v qemu-system-aarch64 || true)}"
RTTHREAD_NATIVE_SRC="${RTTHREAD_NATIVE_SRC:-$ROOT/tmp/rt-thread-5.2.2-native-current}"
RTBENCH_STABILITY_SECONDS="${RTBENCH_STABILITY_SECONDS:-300}"
RTBENCH_MODE="${RTBENCH_MODE:-stability}"
RTBENCH_SUITE_SAMPLES="${RTBENCH_SUITE_SAMPLES:-1000}"
VIRTIO_NATIVE_IRQ_BASE="${VIRTIO_NATIVE_IRQ_BASE:-48}"
VIRTIO_NATIVE_VENDOR_ID="${VIRTIO_NATIVE_VENDOR_ID:-0x554d4551}"
case "$RTBENCH_SUITE_SAMPLES" in
    ''|*[!0-9]*|0)
        echo "RTBENCH_SUITE_SAMPLES must be an integer from 1 to 100000" >&2
        exit 2
        ;;
esac
if [ "$RTBENCH_SUITE_SAMPLES" -gt 100000 ]; then
    echo "RTBENCH_SUITE_SAMPLES must be an integer from 1 to 100000" >&2
    exit 2
fi
case "$RTBENCH_MODE" in
    stability)
        RTBENCH_TIMEOUT_S="${RTBENCH_TIMEOUT_S:-$((RTBENCH_STABILITY_SECONDS + 120))}"
        NATIVE_GUEST_LOG="${NATIVE_GUEST_LOG:-$ROOT/tmp/rtthread-native-${RTBENCH_STABILITY_SECONDS}s.log}"
        RTBENCH_END_MARKER=RTBENCH_STABILITY_DONE
        ;;
    suite)
        RTBENCH_TIMEOUT_S="${RTBENCH_TIMEOUT_S:-$((RTBENCH_SUITE_SAMPLES / 100 + 300))}"
        NATIVE_GUEST_LOG="${NATIVE_GUEST_LOG:-$ROOT/tmp/rtthread-native-suite-${RTBENCH_SUITE_SAMPLES}.log}"
        RTBENCH_END_MARKER=RTBENCH_END
        ;;
    *)
        echo "RTBENCH_MODE must be stability or suite (got $RTBENCH_MODE)" >&2
        exit 2
        ;;
esac
NATIVE_QEMU_LOG="${NATIVE_QEMU_LOG:-${NATIVE_GUEST_LOG}.qemu}"
NATIVE_CPU_LOAD_LOG="${NATIVE_CPU_LOAD_LOG:-}"
QEMU_UCLAMP_MIN="${QEMU_UCLAMP_MIN:-1024}"
QEMU_TCG_THREAD="${QEMU_TCG_THREAD:-multi}"
# INST_RETIRED is only exposed by QEMU in precise icount mode. A fixed
# shift keeps the instruction-derived virtual clock deterministic enough for
# the three-counter benchmark; shift=auto is adaptive and disables event 0x08.
QEMU_ICOUNT="${QEMU_ICOUNT:-shift=3}"
QEMU_NATIVE_VCPU_AFFINITY="${QEMU_NATIVE_VCPU_AFFINITY:-}"
RTBENCH_ALLOW_QEMU_TIMER_LIMIT="${RTBENCH_ALLOW_QEMU_TIMER_LIMIT:-0}"
RTBENCH_NET_HOST_PORT="${RTBENCH_NET_HOST_PORT:-19878}"

if [ "$RTBENCH_MODE" = suite ] || [ "$RTBENCH_MODE" = stability ]; then
    QEMU_TCG_THREAD=single
fi

case "$QEMU_TCG_THREAD" in
    single|multi) ;;
    *) echo "QEMU_TCG_THREAD must be single or multi" >&2; exit 2 ;;
esac
if [[ ! "$QEMU_ICOUNT" =~ ^shift=[0-9]+(,.*)?$ ]]; then
    echo "QEMU_ICOUNT must use precise fixed-shift mode for RTBENCH (for example shift=3), got: $QEMU_ICOUNT" >&2
    exit 2
fi
icount_shift="${QEMU_ICOUNT#shift=}"
icount_shift="${icount_shift%%,*}"
if [ "$icount_shift" -gt 10 ]; then
    echo "QEMU_ICOUNT shift must be between 0 and 10 for RTBENCH, got: $icount_shift" >&2
    exit 2
fi
case "$RTBENCH_ALLOW_QEMU_TIMER_LIMIT" in
    0|1) ;;
    *) echo "RTBENCH_ALLOW_QEMU_TIMER_LIMIT must be 0 or 1" >&2; exit 2 ;;
esac

case "$RTBENCH_STABILITY_SECONDS" in
    ''|*[!0-9]*|0)
        echo "RTBENCH_STABILITY_SECONDS must be an integer from 1 to 3600" >&2
        exit 2
        ;;
esac
if [ "$RTBENCH_STABILITY_SECONDS" -gt 3600 ]; then
    echo "RTBENCH_STABILITY_SECONDS must be an integer from 1 to 3600" >&2
    exit 2
fi
case "$RTBENCH_TIMEOUT_S" in
    ''|*[!0-9]*|0)
        echo "RTBENCH_TIMEOUT_S must be a positive integer" >&2
        exit 2
        ;;
esac
if [ -z "$QEMU" ] || [ ! -x "$QEMU" ]; then
    echo "qemu-system-aarch64 is not available: $QEMU" >&2
    exit 1
fi
case "$VIRTIO_NATIVE_IRQ_BASE" in
    ''|*[!0-9]*)
        echo "VIRTIO_NATIVE_IRQ_BASE must be a decimal IRQ number" >&2
        exit 2
        ;;
esac
case "$VIRTIO_NATIVE_VENDOR_ID" in
    0x[0-9a-fA-F]*|[0-9]*) ;;
    *)
        echo "VIRTIO_NATIVE_VENDOR_ID must be a hexadecimal or decimal vendor ID" >&2
        exit 2
        ;;
esac
case "$RTBENCH_NET_HOST_PORT" in
    ''|*[!0-9]*|0)
        echo "RTBENCH_NET_HOST_PORT must be a decimal port" >&2
        exit 2
        ;;
esac
if [ "$RTBENCH_NET_HOST_PORT" -gt 65535 ]; then
    echo "RTBENCH_NET_HOST_PORT must be below 65536" >&2
    exit 2
fi
for command_name in uv socat git; do
    if ! command -v "$command_name" >/dev/null; then
        echo "required command is not available: $command_name" >&2
        exit 1
    fi
done
if [ -n "$NATIVE_CPU_LOAD_LOG" ] && ! command -v pidstat >/dev/null; then
    echo "NATIVE_CPU_LOAD_LOG requires pidstat" >&2
    exit 1
fi

case "$RTTHREAD_NATIVE_SRC" in
    /*) ;;
    *) RTTHREAD_NATIVE_SRC="$ROOT/$RTTHREAD_NATIVE_SRC" ;;
esac
case "$NATIVE_GUEST_LOG" in
    /*) ;;
    *) NATIVE_GUEST_LOG="$ROOT/$NATIVE_GUEST_LOG" ;;
esac
case "$NATIVE_QEMU_LOG" in
    /*) ;;
    *) NATIVE_QEMU_LOG="$ROOT/$NATIVE_QEMU_LOG" ;;
esac
if [ -n "$NATIVE_CPU_LOAD_LOG" ]; then
    case "$NATIVE_CPU_LOAD_LOG" in
        /*) ;;
        *) NATIVE_CPU_LOAD_LOG="$ROOT/$NATIVE_CPU_LOAD_LOG" ;;
    esac
fi

echo "=== Native RT-Thread hard-timer baseline ==="
echo "[1/3] Preparing the pinned RT-Thread source..."
bash "$PREPARE" "$RTTHREAD_NATIVE_SRC"

bash "$APPLY_PATCHES" "$RTTHREAD_NATIVE_SRC"

# QEMU's AArch64 -kernel loader places the raw image at the RAM base but
# starts it at the image's 2 MiB text offset.  Keep the same raw image usable
# by AxVisor: it loads at 0x40000000 and enters at 0x40200000.
if git -C "$RTTHREAD_NATIVE_SRC" apply --check "$LAYOUT_PATCH"; then
    git -C "$RTTHREAD_NATIVE_SRC" apply "$LAYOUT_PATCH"
    echo "Applied Native QEMU memory layout"
elif git -C "$RTTHREAD_NATIVE_SRC" apply --check --reverse "$LAYOUT_PATCH"; then
    echo "Native QEMU memory layout is already applied"
else
    echo "RT-Thread source does not match the native QEMU memory-layout patch" >&2
    exit 1
fi

VIRTIO_HEADER="$RTTHREAD_NATIVE_SRC/bsp/qemu-virt64-aarch64/drivers/virt.h"
grep -Eq '^#define[[:space:]]+VIRTIO_IRQ_BASE[[:space:]]+' "$VIRTIO_HEADER" || {
    echo "RT-Thread virtio IRQ definition is missing: $VIRTIO_HEADER" >&2
    exit 1
}
sed -i -E \
    "s/^#define[[:space:]]+VIRTIO_IRQ_BASE[[:space:]]+.*/#define VIRTIO_IRQ_BASE     (${VIRTIO_NATIVE_IRQ_BASE})/" \
    "$VIRTIO_HEADER"
sed -i -E \
    "s/^#define[[:space:]]+VIRTIO_VENDOR_ID[[:space:]]+.*/#define VIRTIO_VENDOR_ID    (${VIRTIO_NATIVE_VENDOR_ID})/" \
    "$VIRTIO_HEADER"
echo "Configured native QEMU virtio IRQ base: $VIRTIO_NATIVE_IRQ_BASE"
echo "Configured native QEMU virtio vendor ID: $VIRTIO_NATIVE_VENDOR_ID"
BSP_DIR="$RTTHREAD_NATIVE_SRC/bsp/qemu-virt64-aarch64"
echo "[2/3] Building the canonical hard-timer benchmark..."
uv run --with scons scons -C "$BSP_DIR" -c
uv run --with scons scons -C "$BSP_DIR" -j4
RTTHREAD_IMAGE_METADATA="${RTTHREAD_IMAGE_METADATA:-$BSP_DIR/rtthread.bin.meta.json}"
python3 "$IMAGE_METADATA" write \
    --image "$BSP_DIR/rtthread.bin" \
    --source "$RTTHREAD_NATIVE_SRC" \
    --input-digest "$RTTHREAD_INPUT_DIGEST" \
    --output "$RTTHREAD_IMAGE_METADATA"

mkdir -p -- "$(dirname -- "$NATIVE_GUEST_LOG")" "$(dirname -- "$NATIVE_QEMU_LOG")"
: > "$NATIVE_GUEST_LOG"
: > "$NATIVE_QEMU_LOG"
if [ -n "$NATIVE_CPU_LOAD_LOG" ]; then
    mkdir -p -- "$(dirname -- "$NATIVE_CPU_LOAD_LOG")"
    : > "$NATIVE_CPU_LOAD_LOG"
fi

session_dir="$(mktemp -d)"
serial_socket="$session_dir/serial.sock"
serial_input="$session_dir/serial.in"
qemu_pid_file="$session_dir/qemu.pid"
mkfifo "$serial_input"
exec 3<> "$serial_input"
run_pid=
socat_pid=
feeder_pid=
cpu_monitor_pid=

cleanup() {
    for session_pid in "$feeder_pid" "$cpu_monitor_pid" "$socat_pid" "$run_pid"; do
        if [ -n "$session_pid" ] && kill -0 "$session_pid" 2>/dev/null; then
            kill "$session_pid" 2>/dev/null || true
            wait "$session_pid" 2>/dev/null || true
        fi
    done
    exec 3>&-
    rm -rf -- "$session_dir"
}
trap cleanup EXIT HUP INT TERM

feed_command() {
    deadline_ns=$(( $(date +%s%N) + RTBENCH_TIMEOUT_S * 1000000000 ))
    while ! grep -aFq -- 'msh />' "$NATIVE_GUEST_LOG"; do
        if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
            echo "timed out waiting for the RT-Thread shell" >> "$NATIVE_QEMU_LOG"
            return 1
        fi
        sleep 0.1
    done
    case "$RTBENCH_MODE" in
        stability)
            printf 'rtbench_stability %s\r' "$RTBENCH_STABILITY_SECONDS"
            ;;
        suite)
            printf 'benchmark %s\r' "$RTBENCH_SUITE_SAMPLES"
            deadline_ns=$(( $(date +%s%N) + RTBENCH_TIMEOUT_S * 1000000000 ))
            while ! grep -aFq -- 'RTBENCH_NET_READY port=9878' "$NATIVE_GUEST_LOG"; do
                if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
                    echo "timed out waiting for RTBENCH_NET_READY" >&2
                    return 1
                fi
                sleep 0.05
            done
            python3 "$NET_PROBE" \
                --port "$RTBENCH_NET_HOST_PORT" \
                --count "$RTBENCH_SUITE_SAMPLES" \
                --interval-us 2000 >&2
            ;;
    esac
}

echo "[3/3] Running ${RTBENCH_MODE} benchmark on QEMU virt/GICv3/Cortex-A72..."
echo "QEMU PMU: on (event=0x8 INST_RETIRED)"
echo "QEMU icount: ${QEMU_ICOUNT} (precise fixed-shift)"
cd "$BSP_DIR"
RUN_UNTIL_CHILD_PID_FILE="$qemu_pid_file" \
"$RUN_UNTIL" "$RTBENCH_TIMEOUT_S" "$NATIVE_GUEST_LOG" "$RTBENCH_END_MARKER" -- \
    "$QEMU" \
        -display none \
        -monitor none \
        -accel "tcg,thread=$QEMU_TCG_THREAD" \
        -machine virt,gic-version=3 \
        -global virtio-mmio.force-legacy=false \
        -cpu cortex-a72,pmu=on \
        -icount "$QEMU_ICOUNT" \
        -smp 1 \
        -m 1G \
        -netdev "user,id=net0,net=192.168.77.0/24,hostfwd=udp:127.0.0.1:${RTBENCH_NET_HOST_PORT}-192.168.77.30:9878" \
        -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
        -serial "unix:$serial_socket,server=on,wait=on" \
        -kernel rtthread.bin \
    > "$NATIVE_QEMU_LOG" 2>&1 &
run_pid=$!

socket_deadline_ns=$(( $(date +%s%N) + 5000000000 ))
while [ ! -S "$serial_socket" ]; do
    if ! kill -0 "$run_pid" 2>/dev/null || [ "$(date +%s%N)" -ge "$socket_deadline_ns" ]; then
        echo "QEMU serial socket did not become ready" >> "$NATIVE_QEMU_LOG"
        break
    fi
    sleep 0.05
done
if [ -S "$serial_socket" ]; then
    socat - "UNIX-CONNECT:$serial_socket" <&3 > "$NATIVE_GUEST_LOG" &
    socat_pid=$!
    feed_command >&3 &
    feeder_pid=$!
fi

qemu_pid=
pid_deadline_ns=$(( $(date +%s%N) + 5000000000 ))
while [ ! -s "$qemu_pid_file" ]; do
    if ! kill -0 "$run_pid" 2>/dev/null || [ "$(date +%s%N)" -ge "$pid_deadline_ns" ]; then
        break
    fi
    sleep 0.01
done
if [ ! -s "$qemu_pid_file" ]; then
    echo "QEMU PID did not become available" >&2
    exit 1
fi
qemu_pid="$(cat "$qemu_pid_file")"
qemu_realtime_control_status="$(QEMU_VCPU_AFFINITY="$QEMU_NATIVE_VCPU_AFFINITY" \
    "$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN")"
printf '%s\n' "$qemu_realtime_control_status"
if [ -n "$NATIVE_CPU_LOAD_LOG" ]; then
    pidstat -h -t -p "$qemu_pid" 1 > "$NATIVE_CPU_LOAD_LOG" &
    cpu_monitor_pid=$!
fi

set +e
wait "$run_pid"
qemu_rc=$?
set -e
run_pid=

if [ -n "$feeder_pid" ]; then
    wait "$feeder_pid" 2>/dev/null || true
    feeder_pid=
fi
if [ -n "$cpu_monitor_pid" ]; then
    kill "$cpu_monitor_pid" 2>/dev/null || true
    wait "$cpu_monitor_pid" 2>/dev/null || true
    cpu_monitor_pid=
fi
if [ -n "$socat_pid" ]; then
    kill "$socat_pid" 2>/dev/null || true
    wait "$socat_pid" 2>/dev/null || true
    socat_pid=
fi

case "$RTBENCH_MODE" in
    stability)
        grep -aE 'RTBENCH_STABILITY|RTBENCH metric=stability_jitter|RTBENCH metric=callback_exec' \
            "$NATIVE_GUEST_LOG" || true
        if [ "$RTBENCH_ALLOW_QEMU_TIMER_LIMIT" -eq 1 ]; then
            "$VERIFY" "$NATIVE_GUEST_LOG" "$RTBENCH_STABILITY_SECONDS" \
                "$qemu_rc" allow-qemu-timer-limit
        else
            "$VERIFY" "$NATIVE_GUEST_LOG" "$RTBENCH_STABILITY_SECONDS" "$qemu_rc"
        fi
        ;;
    suite)
        grep -aE 'RTBENCH_BEGIN|RTBENCH metric=|RTBENCH_END' "$NATIVE_GUEST_LOG" || true
        "$VERIFY_SUITE" "$NATIVE_GUEST_LOG" "$RTBENCH_SUITE_SAMPLES" "$qemu_rc"
        ;;
esac

echo "Native guest log: $NATIVE_GUEST_LOG"
echo "Native QEMU log: $NATIVE_QEMU_LOG"
if [ -n "$NATIVE_CPU_LOAD_LOG" ]; then
    echo "Native CPU load log: $NATIVE_CPU_LOAD_LOG"
fi
