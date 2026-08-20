#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_rtthread_native_baseline.sh"

if [[ ! -x "$RUNNER" ]]; then
    echo "FAIL: native RT-Thread baseline runner is missing or not executable" >&2
    exit 1
fi

required_patterns=(
    'prepare_rtthread_source.sh'
    'apply-rtthread-patches.sh'
    '0009-native-qemu-memory-layout.patch'
    'Native QEMU memory layout'
    'VIRTIO_IRQ_BASE'
    'VIRTIO_NATIVE_IRQ_BASE:-48'
    'VIRTIO_NATIVE_VENDOR_ID:-0x554d4551'
    'RTTHREAD_NATIVE_SRC'
    'RTBENCH_STABILITY_SECONDS'
    'RTBENCH_STABILITY_DONE'
    'RTBENCH_MODE'
    'RTBENCH_SUITE_SAMPLES'
    'RTBENCH_END'
    'verify_rtbench_suite.sh'
    'apply_qemu_realtime_controls.sh'
    'QEMU_UCLAMP_MIN'
    'verify_rtbench_stability.sh'
    'RTBENCH_ALLOW_QEMU_TIMER_LIMIT'
    'allow-qemu-timer-limit'
    '-machine virt,gic-version=3'
    '-global virtio-mmio.force-legacy=false'
    '-cpu cortex-a72'
    '-smp 1'
    '-m 1G'
    'user,id=net0,net=192.168.77.0/24,hostfwd=udp:'
    '-device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01'
    '-kernel rtthread.bin'
    'socat'
    'NATIVE_GUEST_LOG'
    'NATIVE_QEMU_LOG'
)
for pattern in "${required_patterns[@]}"; do
    grep -Fq -- "$pattern" "$RUNNER" || {
        echo "FAIL: native runner is missing: $pattern" >&2
        exit 1
    }
done

echo "RT-Thread native baseline contract: PASS"
