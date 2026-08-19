#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
VERIFY="$ROOT/os/axvisor/patches/rtthread/test-rtthread-patches.sh"
SCONS_REQUIREMENT="scons==4.11.0"
TEST_ROOT="$(mktemp -d /tmp/tgoskits-rtthread-patchset.XXXXXX)"
SOURCE="$TEST_ROOT/rt-thread"
BSP="$SOURCE/bsp/qemu-virt64-aarch64"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

build_rtthread() {
    uv run --with "$SCONS_REQUIREMENT" scons -C "$BSP" -j4
}

verify_combined_symbols() {
    nm "$BSP/rtthread.elf" >"$TEST_ROOT/rtthread.nm"
    for symbol in rtbench_stability rtipc_server_start task3_server_start \
        rt_virtio_net_init; do
        if ! grep -Eq "[[:space:]]T[[:space:]]+$symbol$" \
            "$TEST_ROOT/rtthread.nm"; then
            echo "FAIL: combined RT-Thread ELF is missing symbol: $symbol" >&2
            exit 1
        fi
    done
}

task3_object_hash() {
    sha256sum "$BSP/build/applications/task3/task3_server.o" | cut -d' ' -f1
}

if [[ -n "${RTTHREAD_TEST_REPOSITORY:-}" ]]; then
    RTTHREAD_REPOSITORY="$RTTHREAD_TEST_REPOSITORY" "$PREPARE" "$SOURCE"
else
    "$PREPARE" "$SOURCE"
fi
"$APPLY" "$SOURCE"
"$APPLY" "$SOURCE"
"$VERIFY" "$SOURCE"

if rg -n '/home/[^/]+/' \
    "$SOURCE/bsp/qemu-virt64-aarch64/SConstruct" \
    "$SOURCE/bsp/qemu-virt64-aarch64/rtconfig.py" \
    "$SOURCE/bsp/qemu-virt64-aarch64/rtconfig.h"; then
    echo "FAIL: patched RT-Thread build files contain a developer home path" >&2
    exit 1
fi

if [[ "${RTTHREAD_TEST_BUILD:-1}" == 1 ]]; then
    build_rtthread
    test -s "$BSP/rtthread.elf"
    test -s "$BSP/rtthread.bin"
    verify_combined_symbols
    if grep -Eq \
        '[[:space:]](g_virtio_net_poll_timer|virtio_net_poll_timer_cb)$' \
        "$TEST_ROOT/rtthread.nm"; then
        echo "FAIL: combined RT-Thread ELF contains virtio-net polling" >&2
        exit 1
    fi
    normal_task3_hash="$(task3_object_hash)"

    TASK3_FAULT_DROP_STATUS_ONCE=1 build_rtthread
    verify_combined_symbols
    drop_status_task3_hash="$(task3_object_hash)"
    if [[ "$drop_status_task3_hash" == "$normal_task3_hash" ]]; then
        echo "FAIL: drop-status fault did not change the Task 3 object" >&2
        exit 1
    fi

    TASK3_FAULT_DELAY_START_MS=3000 build_rtthread
    verify_combined_symbols
    delayed_task3_hash="$(task3_object_hash)"
    if [[ "$delayed_task3_hash" == "$normal_task3_hash" ||
          "$delayed_task3_hash" == "$drop_status_task3_hash" ]]; then
        echo "FAIL: delayed-server fault did not produce a distinct Task 3 object" >&2
        exit 1
    fi
fi

echo "Fresh RT-Thread patch-set test: PASS"
