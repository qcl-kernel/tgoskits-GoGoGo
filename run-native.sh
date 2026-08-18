#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="${NATIVE_INPUT_DIR:-}"
MODE="${1:-smoke}"

usage() {
    cat <<'EOF'
Usage: ./run-native.sh [smoke|suite|stability] [--input-dir DIR]

Native one-click runner: builds AxVisor and RT-Thread inputs, boots one
2-vCPU Linux guest and one RT-Thread guest, then runs RT-IPC over virtio-net.

Environment:
  QEMU                 Override the AArch64 QEMU binary.
  NATIVE_INPUT_DIR     Reuse a guest input directory.
  RTTHREAD_SRC         Reuse a pinned RT-Thread source/cache.

Modes:
  smoke       100 requests per payload (default)
  suite       1000 requests plus 1000-sample realtime suite
  stability   30000 requests plus 300-second stability test
EOF
}

while (($# > 0)); do
    case "$1" in
        smoke|suite|stability) MODE="$1" ;;
        --input-dir)
            (($# >= 2)) || { echo "--input-dir requires an argument" >&2; exit 2; }
            INPUT_DIR="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for tool in cargo uv git make cpio debugfs dtc file gzip rg socat uclampset \
    aarch64-linux-gnu-gcc aarch64-linux-musl-gcc; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing native dependency: $tool" >&2
        exit 1
    }
done

if [[ -z "${QEMU:-}" ]]; then
    for candidate in \
        /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
        "$(command -v qemu-system-aarch64 || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            QEMU="$candidate"
            break
        fi
    done
fi
QEMU="${QEMU:-}"
[[ -n "$QEMU" && -x "$QEMU" ]] || {
    echo "Set QEMU to an executable qemu-system-aarch64" >&2
    exit 1
}
export QEMU

validate_inputs() {
    local missing=0 artifact
    for artifact in linux-kernel linux-1-initramfs.cpio rootfs.img; do
        if [[ ! -r "$1/$artifact" ]]; then
            echo "Missing guest input: $1/$artifact" >&2
            missing=1
        fi
    done
    ((missing == 0))
}

prepare_inputs() {
    local -a candidates=()
    [[ -z "$INPUT_DIR" ]] || candidates+=("$INPUT_DIR")
    candidates+=(
        "$ROOT/tmp/vmconfigs/three-guest-net/current"
        "/home/yfblock/Code/hyper-rtos/tgoskits/tmp/vmconfigs/three-guest-net/current"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]] && validate_inputs "$candidate"; then
            INPUT_DIR="$candidate"
            return
        fi
    done

    if [[ -n "$INPUT_DIR" ]]; then
        validate_inputs "$INPUT_DIR"
        return
    fi

    RTTHREAD_BUILD="${RTTHREAD_SRC:-$ROOT/.native-cache/rt-thread-5.2.2}"
    bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh "$RTTHREAD_BUILD"
    bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh "$RTTHREAD_BUILD"
    uv run --with 'scons==4.10.1' scons -j"$(nproc)" \
        -C "$RTTHREAD_BUILD/bsp/qemu-virt64-aarch64"
    AXVISOR_THREE_GUEST_RTOS_IMAGE="$RTTHREAD_BUILD/bsp/qemu-virt64-aarch64/rtthread.bin" \
    AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT=0xa0000000 \
        bash os/axvisor/scripts/setup_qemu_three_guest_net.sh
    INPUT_DIR="$ROOT/tmp/vmconfigs/three-guest-net/current"
    validate_inputs "$INPUT_DIR"
}

prepare_inputs
mkdir -p tmp/native-runs
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

case "$MODE" in
    smoke)
        RTIPC_COUNT=100 RTIPC_TIMEOUT_S=480 ;;
    suite)
        RTIPC_COUNT=1000 RTIPC_TIMEOUT_S=480
        RTBENCH_SUITE_SAMPLES=1000 RTBENCH_START_MODE=concurrent ;;
    stability)
        RTIPC_COUNT=30000 RTIPC_TIMEOUT_S=480
        RTBENCH_STABILITY_SECONDS=300 RTBENCH_START_MODE=concurrent ;;
esac

export RTIPC_COUNT RTIPC_TIMEOUT_S QEMU_UCLAMP_MIN=1024
export LOG="$ROOT/tmp/native-runs/$MODE-$RUN_ID.log"
export QEMU_LOG="$ROOT/tmp/native-runs/$MODE-$RUN_ID.qemu.log"
export ARTIFACT_LOG="$ROOT/tmp/native-runs/$MODE-$RUN_ID.artifacts"
if [[ "$MODE" != smoke ]]; then
    export RTBENCH_SUITE_SAMPLES RTBENCH_START_MODE
    export RTBENCH_TIMING_LOG="$ROOT/tmp/native-runs/$MODE-$RUN_ID.timing"
    export CPU_LOAD_LOG="$ROOT/tmp/native-runs/$MODE-$RUN_ID-cpu.log"
fi
if [[ "$MODE" == stability ]]; then
    export RTBENCH_STABILITY_SECONDS
fi

export LINUX_KERNEL_IMAGE="$INPUT_DIR/linux-kernel"
export LINUX_INITRAMFS_SOURCE="$INPUT_DIR/linux-1-initramfs.cpio"
export ROOTFS_IMAGE="$INPUT_DIR/rootfs.img"

printf 'Native mode: %s\\n' "$MODE"
printf 'Guest inputs: %s\\n' "$INPUT_DIR"
printf 'QEMU: %s\\n' "$QEMU"
printf 'Guest log: %s\\n' "$LOG"

bash os/axvisor/scripts/run_rtipc_test.sh
