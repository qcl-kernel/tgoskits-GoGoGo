#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GENERATOR="$SCRIPT_DIR/generate_linux_vmconfig.sh"
OUTER_QEMU_CONFIG="$SCRIPT_DIR/../configs/qemu/qemu-aarch64-two-guest-net.toml"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

root="$fixture/repo"
runtime="$root/tmp/rtipc-runtime.ABC123"
legacy_runtime="$root/tmp/rtipc-runtime.DEF456"
mkdir -p "$runtime" "$legacy_runtime" "$root/config"
kernel="$root/linux-kernel"
initramfs="$root/linux-initramfs.cpio"
printf '%s\n' 'kernel fixture' > "$kernel"
printf '%s\n' 'initramfs fixture' > "$initramfs"

template="$root/config/linux-net.toml"
cat > "$template" <<'EOF'
[kernel]
kernel_path = "/stale/worktree/linux-kernel"
ramdisk_path = "/stale/worktree/linux-initramfs.cpio"
memory_regions = [
  [0x80000000, 0x20000000, 0x7, 2],
]
cmdline = "stale=guest"
unchanged = "cmdline = not-a-key"

["metadata"]
cmdline = "outer-table-must-remain-unchanged"
EOF

guest_cmdline='console=ttyAMA0 rdinit=/init task2.count=1000 task2.fault=none task3.frames=600 task3.fault=normal'
output="$(
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" "$runtime" \
        "$guest_cmdline"
)"

[[ "$output" == "$runtime/linux-net.toml" ]] || {
    echo "FAIL: unexpected generated config path: $output" >&2
    exit 1
}
grep -Fxq 'kernel_path = "linux-kernel"' "$output" || {
    echo "FAIL: generated kernel path is not runtime-relative" >&2
    exit 1
}
grep -Fxq 'ramdisk_path = "linux-initramfs.cpio"' "$output" || {
    echo "FAIL: generated initramfs path is not runtime-relative" >&2
    exit 1
}
[[ "$(realpath -e -- "$runtime/linux-kernel")" == "$(realpath -e -- "$kernel")" ]] || {
    echo "FAIL: runtime kernel does not resolve to the selected kernel" >&2
    exit 1
}
[[ "$(realpath -e -- "$runtime/linux-initramfs.cpio")" == \
   "$(realpath -e -- "$initramfs")" ]] || {
    echo "FAIL: runtime initramfs does not resolve to the selected initramfs" >&2
    exit 1
}
if grep -Fq '/stale/worktree' "$output"; then
    echo "FAIL: generated config retained stale absolute paths" >&2
    exit 1
fi
grep -Fxq "cmdline = \"$guest_cmdline\"" "$output" || {
    echo "FAIL: generated config did not replace the guest cmdline" >&2
    exit 1
}
grep -Fxq 'unchanged = "cmdline = not-a-key"' "$output" || {
    echo "FAIL: generator modified a non-cmdline key" >&2
    exit 1
}
grep -Fxq 'cmdline = "outer-table-must-remain-unchanged"' "$output" || {
    echo "FAIL: generator modified cmdline outside the kernel table" >&2
    exit 1
}
rg -q --fixed-strings 'root=/dev/nvme0n1 rw init=/bin/sh' "$OUTER_QEMU_CONFIG" || {
    echo "FAIL: outer QEMU fixture no longer contains its expected host cmdline" >&2
    exit 1
}
if rg -q --fixed-strings 'root=/dev/nvme0n1 rw init=/bin/sh' "$output"; then
    echo "FAIL: outer QEMU -append leaked into the Linux guest cmdline" >&2
    exit 1
fi

legacy_output="$(
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" "$legacy_runtime"
)"
grep -Fxq 'cmdline = "stale=guest"' "$legacy_output" || {
    echo "FAIL: five-argument mode must preserve the template cmdline" >&2
    exit 1
}

expect_exit_2() {
    local label="$1"
    shift
    set +e
    "$@" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || {
        echo "FAIL: $label must return 2 (got $rc)" >&2
        exit 1
    }
}

mkdir -p "$fixture/outside-runtime"
expect_exit_2 "runtime directory outside ROOT" \
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" \
    "$fixture/outside-runtime"

mkdir -p "$root/tmp/rtipc-runtime.QUOTE1"
expect_exit_2 "guest cmdline containing a quote" \
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" \
    "$root/tmp/rtipc-runtime.QUOTE1" 'console="ttyAMA0"'

mkdir -p "$root/tmp/rtipc-runtime.SLASH1"
expect_exit_2 "guest cmdline containing a backslash" \
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" \
    "$root/tmp/rtipc-runtime.SLASH1" 'console=ttyAMA0\unsafe'

missing_cmdline="$root/config/linux-net-missing-cmdline.toml"
sed '/^cmdline = "stale=guest"$/d' "$template" > "$missing_cmdline"
mkdir -p "$root/tmp/rtipc-runtime.MISSING1"
expect_exit_2 "template without cmdline" \
    bash "$GENERATOR" "$root" "$missing_cmdline" "$kernel" "$initramfs" \
    "$root/tmp/rtipc-runtime.MISSING1" "$guest_cmdline"

duplicate_cmdline="$root/config/linux-net-duplicate-cmdline.toml"
sed '/^cmdline = "stale=guest"$/a cmdline = "duplicate=guest"' \
    "$template" > "$duplicate_cmdline"
mkdir -p "$root/tmp/rtipc-runtime.DUPLICATE1"
expect_exit_2 "template with duplicate cmdline keys" \
    bash "$GENERATOR" "$root" "$duplicate_cmdline" "$kernel" "$initramfs" \
    "$root/tmp/rtipc-runtime.DUPLICATE1" "$guest_cmdline"

echo "PASS: Linux runtime VM config generator"
