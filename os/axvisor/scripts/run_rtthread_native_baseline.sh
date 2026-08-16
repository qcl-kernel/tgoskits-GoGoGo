#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY_PATCHES="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
LAYOUT_PATCH="$ROOT/os/axvisor/patches/rtthread/0009-native-qemu-memory-layout.patch"
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
VERIFY="$SCRIPT_DIR/verify_rtbench_stability.sh"
QEMU_REALTIME_CONTROL="$SCRIPT_DIR/apply_qemu_realtime_controls.sh"

QEMU="${QEMU:-$(command -v qemu-system-aarch64 || true)}"
RTTHREAD_NATIVE_SRC="${RTTHREAD_NATIVE_SRC:-$ROOT/tmp/rt-thread-5.2.2-native-current}"
RTBENCH_STABILITY_SECONDS="${RTBENCH_STABILITY_SECONDS:-300}"
RTBENCH_TIMEOUT_S="${RTBENCH_TIMEOUT_S:-$((RTBENCH_STABILITY_SECONDS + 120))}"
NATIVE_GUEST_LOG="${NATIVE_GUEST_LOG:-$ROOT/tmp/rtthread-native-${RTBENCH_STABILITY_SECONDS}s.log}"
NATIVE_QEMU_LOG="${NATIVE_QEMU_LOG:-${NATIVE_GUEST_LOG}.qemu}"
NATIVE_CPU_LOAD_LOG="${NATIVE_CPU_LOAD_LOG:-}"
QEMU_UCLAMP_MIN="${QEMU_UCLAMP_MIN:-1024}"

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

# The native layout touches files that are also introduced by the base port.
# Remove it before the base-port idempotency check, then apply it again below.
if git -C "$RTTHREAD_NATIVE_SRC" apply --check --reverse "$LAYOUT_PATCH"; then
    git -C "$RTTHREAD_NATIVE_SRC" apply --reverse "$LAYOUT_PATCH"
    echo "Temporarily removed native QEMU memory layout"
fi
bash "$APPLY_PATCHES" "$RTTHREAD_NATIVE_SRC"
if git -C "$RTTHREAD_NATIVE_SRC" apply --check "$LAYOUT_PATCH"; then
    git -C "$RTTHREAD_NATIVE_SRC" apply "$LAYOUT_PATCH"
    echo "Applied native QEMU memory layout"
elif git -C "$RTTHREAD_NATIVE_SRC" apply --check --reverse "$LAYOUT_PATCH"; then
    echo "Native QEMU memory layout is already applied"
else
    echo "RT-Thread source does not match the native memory-layout patch" >&2
    exit 1
fi

BSP_DIR="$RTTHREAD_NATIVE_SRC/bsp/qemu-virt64-aarch64"
echo "[2/3] Building the canonical hard-timer benchmark..."
uv run --with scons scons -C "$BSP_DIR" -c
uv run --with scons scons -C "$BSP_DIR" -j4

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
    printf 'rtbench_stability %s\r' "$RTBENCH_STABILITY_SECONDS"
}

echo "[3/3] Running ${RTBENCH_STABILITY_SECONDS}s on QEMU virt/GICv3/Cortex-A72..."
cd "$BSP_DIR"
RUN_UNTIL_CHILD_PID_FILE="$qemu_pid_file" \
"$RUN_UNTIL" "$RTBENCH_TIMEOUT_S" "$NATIVE_GUEST_LOG" RTBENCH_STABILITY_DONE -- \
    "$QEMU" \
        -display none \
        -monitor none \
        -machine virt,gic-version=3 \
        -cpu cortex-a72 \
        -smp 1 \
        -m 1G \
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
qemu_realtime_control_status="$("$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN")"
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

grep -aE 'RTBENCH_STABILITY|RTBENCH metric=stability_jitter|RTBENCH metric=callback_exec' \
    "$NATIVE_GUEST_LOG" || true
"$VERIFY" "$NATIVE_GUEST_LOG" "$RTBENCH_STABILITY_SECONDS" "$qemu_rc"

echo "Native guest log: $NATIVE_GUEST_LOG"
echo "Native QEMU log: $NATIVE_QEMU_LOG"
if [ -n "$NATIVE_CPU_LOAD_LOG" ]; then
    echo "Native CPU load log: $NATIVE_CPU_LOAD_LOG"
fi
