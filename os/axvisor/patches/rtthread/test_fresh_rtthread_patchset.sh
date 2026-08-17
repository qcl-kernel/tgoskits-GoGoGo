#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
VERIFY="$ROOT/os/axvisor/patches/rtthread/test-rtthread-patches.sh"
SEED_REPOSITORY="${RTTHREAD_TEST_REPOSITORY:-$ROOT/tmp/rt-thread-5.2.2-full}"
TEST_ROOT="$(mktemp -d /tmp/tgoskits-rtthread-patchset.XXXXXX)"
SOURCE="$TEST_ROOT/rt-thread"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

RTTHREAD_REPOSITORY="$SEED_REPOSITORY" "$PREPARE" "$SOURCE"
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

if [[ "${RTTHREAD_TEST_BUILD:-0}" == 1 ]]; then
    uv run --with scons scons \
        -C "$SOURCE/bsp/qemu-virt64-aarch64" -j4
    test -s "$SOURCE/bsp/qemu-virt64-aarch64/rtthread.elf"
    test -s "$SOURCE/bsp/qemu-virt64-aarch64/rtthread.bin"
fi

echo "Fresh RT-Thread patch-set test: PASS"
