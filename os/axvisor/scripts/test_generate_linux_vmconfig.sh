#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GENERATOR="$SCRIPT_DIR/generate_linux_vmconfig.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

root="$fixture/repo"
runtime="$root/tmp/rtipc-runtime.ABC123"
mkdir -p "$runtime" "$root/config"
kernel="$root/linux-kernel"
initramfs="$root/linux-initramfs.cpio"
printf '%s\n' 'kernel fixture' > "$kernel"
printf '%s\n' 'initramfs fixture' > "$initramfs"

template="$root/config/linux-net.toml"
cat > "$template" <<'EOF'
[kernel]
kernel_path = "/stale/worktree/linux-kernel"
ramdisk_path = "/stale/worktree/linux-initramfs.cpio"
EOF

output="$(
    bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" "$runtime"
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

set +e
bash "$GENERATOR" "$root" "$template" "$kernel" "$initramfs" \
    "$fixture/outside-runtime" >/dev/null 2>&1
unsafe_rc=$?
set -e
[[ "$unsafe_rc" -eq 2 ]] || {
    echo "FAIL: unsafe runtime directory must return 2 (got $unsafe_rc)" >&2
    exit 1
}

echo "PASS: Linux runtime VM config generator"
