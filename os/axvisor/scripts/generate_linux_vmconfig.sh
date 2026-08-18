#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 ROOT TEMPLATE LINUX_KERNEL INITRAMFS RUNTIME_DIR" >&2
    exit 2
fi

if ! root="$(realpath -e -- "$1")" ||
   ! template="$(realpath -e -- "$2")" ||
   ! kernel="$(realpath -e -- "$3")" ||
   ! initramfs="$(realpath -e -- "$4")" ||
   ! runtime_dir="$(realpath -e -- "$5")"; then
    echo "ROOT, TEMPLATE, LINUX_KERNEL, INITRAMFS, and RUNTIME_DIR must exist" >&2
    exit 2
fi

case "$runtime_dir" in
    "$root"/tmp/rtipc-runtime.*) ;;
    *)
        echo "runtime directory must be ROOT/tmp/rtipc-runtime.*: $runtime_dir" >&2
        exit 2
        ;;
esac

runtime_rel="${runtime_dir#"$root"/}"
if [[ ! "$runtime_rel" =~ ^tmp/rtipc-runtime\.[A-Za-z0-9]+$ ]]; then
    echo "unsafe runtime directory name: $runtime_rel" >&2
    exit 2
fi

kernel_path_count="$(grep -c '^kernel_path[[:space:]]*=' "$template" || true)"
ramdisk_path_count="$(grep -c '^ramdisk_path[[:space:]]*=' "$template" || true)"
if [[ "$kernel_path_count" -ne 1 || "$ramdisk_path_count" -ne 1 ]]; then
    echo "template must contain exactly one kernel_path and ramdisk_path: $template" >&2
    exit 2
fi

runtime_kernel="$runtime_dir/linux-kernel"
runtime_initramfs="$runtime_dir/linux-initramfs.cpio"
output="$runtime_dir/linux-net.toml"
output_tmp="$runtime_dir/.linux-net.toml.tmp"
trap 'rm -f -- "$output_tmp"' EXIT

ln -s -- "$kernel" "$runtime_kernel"
ln -s -- "$initramfs" "$runtime_initramfs"
awk '
    /^kernel_path[[:space:]]*=/ {
        print "kernel_path = \"linux-kernel\""
        next
    }
    /^ramdisk_path[[:space:]]*=/ {
        print "ramdisk_path = \"linux-initramfs.cpio\""
        next
    }
    { print }
' "$template" > "$output_tmp"
mv -- "$output_tmp" "$output"
trap - EXIT

printf '%s\n' "$output"
