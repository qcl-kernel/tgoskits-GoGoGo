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
    if ! grep -Fq 'rt_ofw_bootargs_select("task3.fault="' \
        "$SOURCE/bsp/qemu-virt64-aarch64/applications/task3/task3_server.c"; then
        echo "FAIL: Task 3 runtime fault selection is missing" >&2
        exit 1
    fi
fi

echo "Fresh RT-Thread patch-set test: PASS"
