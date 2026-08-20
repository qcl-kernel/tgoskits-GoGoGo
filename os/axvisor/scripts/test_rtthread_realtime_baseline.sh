#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
RUNNER="$SCRIPT_DIR/run_rtthread_realtime_baseline.sh"
ONLY_RUNNER="$SCRIPT_DIR/run_rtthread_axvisor_only.sh"
TMPDIR="${TMPDIR:-/tmp}"
export TMPDIR

for required_pattern in \
    'run_rtthread_native_baseline.sh' \
    'run_rtthread_axvisor_only.sh' \
    'run_task123.sh' \
    'rtthread_image_metadata.py' \
    'RTTHREAD_REQUIRE_IMAGE_METADATA=1' \
    'summarize_rtthread_realtime.py' \
    'realtime-suite.json' \
    'realtime-suite.md' \
    'realtime-stability.json' \
    'realtime-stability.md' \
    'TASK123_ALLOW_QEMU_TIMER_LIMIT=1'; do
    grep -Fq -- "$required_pattern" "$RUNNER" || {
        echo "FAIL: realtime baseline runner is missing: $required_pattern" >&2
        exit 1
    }
done
for required_pattern in \
    'QEMU="${QEMU:-$(command -v qemu-system-aarch64 || true)}"' \
    'QEMU="$QEMU"'; do
    grep -Fq -- "$required_pattern" "$RUNNER" || {
        echo "FAIL: realtime baseline runner is missing: $required_pattern" >&2
        exit 1
    }
done
for required_pattern in \
    'generate_rtthread_vmconfig.sh' \
    'rtthread_image_metadata.py' \
    'RTTHREAD_REQUIRE_IMAGE_METADATA' \
    'RTTHREAD_IMAGE_META' \
    'cargo xtask axvisor build' \
    '-machine virt,virtualization=on,gic-version=3' \
    '-smp 4' \
    '-m 8g' \
    'bus=virtio-mmio-bus.2' \
    'benchmark_core' \
    '--core-suite' \
    '"$mode" != suite || "$core_suite" -eq 1' \
    'if [[ "$core_suite" -eq 0 ]]; then' \
    'trap cleanup EXIT HUP INT TERM' \
    'exec 3<> "$fifo"' \
    ' <&3 >"$console" 2>&1 &' \
    'rm -f -- "$fifo"' \
    'verify_rtbench_suite.sh' \
    'verify_rtbench_stability.sh'; do
    grep -Fq -- "$required_pattern" "$ONLY_RUNNER" || {
        echo "FAIL: AxVisor-only runner is missing: $required_pattern" >&2
        exit 1
    }
done
for required_pattern in \
    '--markdown-output "$output/realtime-suite.md"' \
    '--markdown-output "$output/realtime-stability.md"'; do
    grep -Fq -- "$required_pattern" "$RUNNER" || {
        echo "FAIL: realtime baseline runner is missing: $required_pattern" >&2
        exit 1
    }
done

if bash "$RUNNER" --skip-suite --skip-stability --output "$TMPDIR/unused" >/dev/null 2>&1; then
    echo 'FAIL: mutually skipped suite and stability were accepted' >&2
    exit 1
fi
if bash "$RUNNER" --quick --suite-samples 100000 --output "$TMPDIR/unused" >/dev/null 2>&1; then
    echo 'FAIL: conflicting quick and sample options were accepted' >&2
    exit 1
fi

echo 'PASS: RT-Thread realtime baseline runner contract'
