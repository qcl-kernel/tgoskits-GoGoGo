#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
GENERATE_VMCONFIG="$SCRIPT_DIR/generate_rtthread_vmconfig.sh"
VERIFY_SUITE="$SCRIPT_DIR/verify_rtbench_suite.sh"
VERIFY_STABILITY="$SCRIPT_DIR/verify_rtbench_stability.sh"
NET_PROBE="$SCRIPT_DIR/send_rtbench_net_probe.py"
IMAGE_METADATA="$SCRIPT_DIR/rtthread_image_metadata.py"
QEMU="${QEMU:-qemu-system-aarch64}"
ROOTFS="${ROOTFS_IMAGE:-$ROOT/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img}"
RTBENCH_NET_HOST_PORT="${RTBENCH_NET_HOST_PORT:-19879}"
QEMU_UCLAMP_MIN="${QEMU_UCLAMP_MIN:-1024}"
QEMU_TCG_THREAD="${QEMU_TCG_THREAD:-multi}"
QEMU_REALTIME_CONTROL="${QEMU_REALTIME_CONTROL:-$SCRIPT_DIR/apply_qemu_realtime_controls.sh}"
RTTHREAD_REQUIRE_IMAGE_METADATA="${RTTHREAD_REQUIRE_IMAGE_METADATA:-1}"
RTTHREAD_IMAGE_META="${RTTHREAD_IMAGE_META:-}"

usage() {
    cat >&2 <<EOF
usage: \$0 --image RTTHREAD_BIN (--suite-samples N --core-suite | --stability-seconds N) --output DIR
EOF
    exit 2
}

image=
mode=
samples=
seconds=
output=
core_suite=0
qemu_pid=
serial_fd_open=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image|--suite-samples|--stability-seconds|--output)
            [[ $# -ge 2 ]] || usage
            option=$1
            value=$2
            case "$option" in
                --image) image=$value ;;
                --suite-samples) mode=suite; samples=$value ;;
                --stability-seconds) mode=stability; seconds=$value ;;
                --output) output=$value ;;
            esac
            shift 2 ;;
        --core-suite)
            core_suite=1
            shift ;;
        *) usage ;;
    esac
done
[[ -n "$image" && -n "$mode" && -n "$output" ]] || usage
[[ "$core_suite" -eq 0 || "$mode" == suite ]] || usage
[[ "$mode" != suite || "$core_suite" -eq 1 ]] || usage
case "$mode" in
    suite) [[ "$samples" =~ ^[0-9]+$ && "$samples" -ge 1 && "$samples" -le 100000 ]] || usage ;;
    stability) [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 1 && "$seconds" -le 3600 ]] || usage ;;
esac
[[ -x "$QEMU" ]] || { echo "QEMU is not executable: $QEMU" >&2; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "rootfs image not found: $ROOTFS" >&2; exit 1; }
case "$QEMU_TCG_THREAD" in
    single|multi) ;;
    *) echo "QEMU_TCG_THREAD must be single or multi" >&2; exit 2 ;;
esac
case "$RTBENCH_NET_HOST_PORT" in
    ''|*[!0-9]*|0) echo "RTBENCH_NET_HOST_PORT must be a decimal port" >&2; exit 2 ;;
esac
[[ "$RTBENCH_NET_HOST_PORT" -le 65535 ]] || {
    echo "RTBENCH_NET_HOST_PORT must be below 65536" >&2
    exit 2
}
image="$(realpath -e -- "$image")"
if [[ "$RTTHREAD_REQUIRE_IMAGE_METADATA" -eq 1 ]]; then
    metadata="${RTTHREAD_IMAGE_META:-$image.meta.json}"
    python3 "$IMAGE_METADATA" check \
        --image "$image" \
        --metadata "$metadata"
fi
mkdir -p -- "$output"
output="$(cd -- "$output" && pwd)"

runtime="$ROOT/tmp/rtthread-runtime.aaxvisor$(date +%s)$$"
mkdir -p -- "$runtime"
vmconfig="$(timeout --foreground --signal TERM --kill-after 5s 300 "$GENERATE_VMCONFIG" "$ROOT" "$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml" "$image" "$runtime")"

cargo xtask axvisor build --config qemu-aarch64-two-guest-net --smp 4 --vmconfigs "$vmconfig" >"$output/axvisor-build.log" 2>&1
elf="$(sed -n 's/^\[axbuild\] cargo build elf=//p' "$output/axvisor-build.log" | tail -n 1)"
[[ -n "$elf" ]] || { cat "$output/axvisor-build.log" >&2; exit 1; }
aarch64-linux-gnu-strip -o "$output/axvisor.stripped" "$elf"
aarch64-linux-gnu-objcopy -O binary "$output/axvisor.stripped" "$output/axvisor.bin"

fifo="$output/serial.in"
mkfifo -- "$fifo"
console="$output/console.log"
: >"$console"
exec 3<> "$fifo"
serial_fd_open=1

cleanup() {
    local status=$?
    if [[ -n "${qemu_pid:-}" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill -TERM "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    if [[ "$serial_fd_open" -eq 1 ]]; then
        exec 3>&-
        serial_fd_open=0
    fi
    rm -f -- "$fifo"
    return "$status"
}
trap cleanup EXIT HUP INT TERM

if [[ "$mode" == suite ]]; then
    if [[ "$core_suite" -eq 1 ]]; then
        command="benchmark_core $samples"
        verify_mode=core
    else
        command="benchmark $samples"
        verify_mode=full
    fi
    marker="RTBENCH_END"
else
    command="rtbench_stability $seconds"
    marker="RTBENCH_STABILITY_DONE"
    verify_mode=full
fi

"$QEMU" -display none -monitor none -snapshot -name 'tgoskits,debug-threads=on' -accel "tcg,thread=$QEMU_TCG_THREAD" -cpu cortex-a72 -machine virt,virtualization=on,gic-version=3 -global virtio-mmio.force-legacy=false -smp 4 -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 -drive id=disk0,if=none,format=raw,file="$ROOTFS" -append 'root=/dev/nvme0n1 rw init=/bin/sh' -m 8g -netdev "user,id=net2,net=192.168.77.0/24,hostfwd=udp:127.0.0.1:${RTBENCH_NET_HOST_PORT}-192.168.77.30:9878" -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 -serial stdio -no-reboot -kernel "$output/axvisor.bin" <&3 >"$console" 2>&1 &
qemu_pid=$!
"$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN"

deadline=$(( $(date +%s) + 120 ))
while ! grep -aFq 'msh />' "$console"; do
    kill -0 "$qemu_pid" 2>/dev/null || break
    [[ $(date +%s) -lt $deadline ]] || break
    sleep 0.1
done
grep -aFq 'msh />' "$console" || { echo "RT-Thread shell did not start" >&2; exit 1; }
printf '%s\r' "$command" >&3

if [[ "$mode" == suite ]]; then
    deadline=$(( $(date +%s) + ${AXVISOR_ONLY_TIMEOUT_S:-1800} ))
    if [[ "$core_suite" -eq 0 ]]; then
        while ! grep -aFq 'RTBENCH_NET_READY port=9878' "$console"; do
            kill -0 "$qemu_pid" 2>/dev/null || break
            [[ $(date +%s) -lt $deadline ]] || break
            sleep 0.1
        done
        grep -aFq 'RTBENCH_NET_READY port=9878' "$console" || {
            echo "RT-Thread network benchmark did not become ready" >&2
            exit 1
        }
        python3 "$NET_PROBE" \
            --port "$RTBENCH_NET_HOST_PORT" \
            --count "$samples" \
            --interval-us 2000 >&2
    fi
fi

deadline=$(( $(date +%s) + ${AXVISOR_ONLY_TIMEOUT_S:-1800} ))
while ! grep -aFq "$marker" "$console"; do
    kill -0 "$qemu_pid" 2>/dev/null || break
    [[ $(date +%s) -lt $deadline ]] || break
    sleep 0.1
done
exec 3>&-
serial_fd_open=0
kill -TERM "$qemu_pid" 2>/dev/null || true
set +e
wait "$qemu_pid"
qemu_rc=$?
set -e

if [[ "$mode" == suite ]]; then
    "$VERIFY_SUITE" "$console" "$samples" "$qemu_rc" "$verify_mode"
else
    "$VERIFY_STABILITY" "$console" "$seconds" "$qemu_rc"
fi
