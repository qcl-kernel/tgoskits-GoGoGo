#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 ROOT TEMPLATE RTTHREAD_KERNEL RUNTIME_DIR" >&2
    exit 2
fi

root="$(realpath -e -- "$1")"
template="$(realpath -e -- "$2")"
kernel="$(realpath -e -- "$3")"
runtime_dir="$(realpath -e -- "$4")"

case "$runtime_dir" in
    "$root"/tmp/rtthread-runtime.*) ;;
    *)
        echo "runtime directory must be ROOT/tmp/rtthread-runtime.*: $runtime_dir" >&2
        exit 2
        ;;
esac

runtime_rel="${runtime_dir#"$root"/}"
if [[ ! "$runtime_rel" =~ ^tmp/rtthread-runtime\.[A-Za-z0-9]+$ ]]; then
    echo "unsafe runtime directory name: $runtime_rel" >&2
    exit 2
fi

kernel_path_count="$(grep -c '^kernel_path[[:space:]]*=' "$template" || true)"
if [[ "$kernel_path_count" -ne 1 ]]; then
    echo "template must contain exactly one kernel_path: $template" >&2
    exit 2
fi

runtime_kernel="$runtime_dir/rtthread.bin"
output="$runtime_dir/rtthread-net.toml"
output_tmp="$runtime_dir/.rtthread-net.toml.tmp"
trap 'rm -f -- "$output_tmp"' EXIT

ln -s -- "$kernel" "$runtime_kernel"
awk -v path="rtthread.bin" '
    /^kernel_path[[:space:]]*=/ {
        printf "kernel_path = \"%s\"\n", path
        next
    }
    { print }
' "$template" > "$output_tmp"
mv -- "$output_tmp" "$output"
trap - EXIT

printf '%s\n' "$output"
