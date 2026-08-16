#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_rtthread_native_baseline.sh"
LAYOUT_PATCH="$ROOT/os/axvisor/patches/rtthread/0009-native-qemu-memory-layout.patch"

if [[ ! -x "$RUNNER" ]]; then
    echo "FAIL: native RT-Thread baseline runner is missing or not executable" >&2
    exit 1
fi
if [[ ! -f "$LAYOUT_PATCH" ]]; then
    echo "FAIL: native RT-Thread memory-layout patch is missing" >&2
    exit 1
fi

required_patterns=(
    'prepare_rtthread_source.sh'
    'apply-rtthread-patches.sh'
    '0009-native-qemu-memory-layout.patch'
    'RTTHREAD_NATIVE_SRC'
    'RTBENCH_STABILITY_SECONDS'
    'RTBENCH_STABILITY_DONE'
    'apply_qemu_realtime_controls.sh'
    'QEMU_UCLAMP_MIN'
    'verify_rtbench_stability.sh'
    '-machine virt,gic-version=3'
    '-cpu cortex-a72'
    '-smp 1'
    '-m 1G'
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

layout_reverse_line="$(grep -nF 'apply --reverse "$LAYOUT_PATCH"' "$RUNNER" | head -1 | cut -d: -f1 || true)"
base_apply_line="$(grep -nF 'bash "$APPLY_PATCHES"' "$RUNNER" | head -1 | cut -d: -f1 || true)"
if [[ -z "$layout_reverse_line" || -z "$base_apply_line" ||
      "$layout_reverse_line" -ge "$base_apply_line" ]]; then
    echo "FAIL: native runner must remove layout patch before verifying the base patch" >&2
    exit 1
fi

patch_patterns=(
    '_text_offset = 0x200000'
    '. = 0x40000000 + _text_offset'
    '#define ARCH_TEXT_OFFSET 0x200000'
    '#define ARCH_RAM_OFFSET 0x40000000'
)
for pattern in "${patch_patterns[@]}"; do
    grep -Fq -- "$pattern" "$LAYOUT_PATCH" || {
        echo "FAIL: native layout patch is missing: $pattern" >&2
        exit 1
    }
done

echo "RT-Thread native baseline contract: PASS"
