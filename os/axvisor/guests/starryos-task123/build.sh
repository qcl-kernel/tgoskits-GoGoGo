#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
BUILD_CONFIG="$REPO_ROOT/os/StarryOS/configs/axvisor/task123-aarch64.toml"
TARGET_DIR="$REPO_ROOT/target/aarch64-unknown-none-softfloat/release"
ROOTFS="$SCRIPT_DIR/build/starryos-task123-rootfs.cpio"
source_cpio=${TASK123_LINUX_ROOTFS:-}

usage() {
    cat <<EOF
Usage: $0 [--source-cpio PATH]

Builds the deterministic embedded rootfs and the two-vCPU StarryOS guest image.
EOF
}

while (($#)); do
    case "$1" in
        --source-cpio)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            source_cpio=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

rootfs_args=(--output "$ROOTFS")
if [[ -n "$source_cpio" ]]; then
    rootfs_args+=(--source-cpio "$source_cpio")
fi
"$SCRIPT_DIR/build_rootfs.sh" "${rootfs_args[@]}"

cd "$REPO_ROOT"
STARRY_EMBEDDED_ROOTFS="$ROOTFS" \
    cargo xtask starry build --config "$BUILD_CONFIG"

[[ -s "$TARGET_DIR/starryos" ]] || {
    printf 'StarryOS ELF was not generated\n' >&2
    exit 1
}
[[ -s "$TARGET_DIR/starryos.bin" ]] || {
    printf 'StarryOS raw image was not generated\n' >&2
    exit 1
}

cp -f -- "$TARGET_DIR/starryos.bin" "$TARGET_DIR/starryos-task123.bin"
sha256sum "$TARGET_DIR/starryos" "$TARGET_DIR/starryos-task123.bin" "$ROOTFS" > \
    "$SCRIPT_DIR/build/starryos-task123.sha256"

printf 'starryos_elf=%s\n' "$TARGET_DIR/starryos"
printf 'starryos_image=%s\n' "$TARGET_DIR/starryos-task123.bin"
printf 'starryos_rootfs=%s\n' "$ROOTFS"
printf 'starryos_hashes=%s\n' "$SCRIPT_DIR/build/starryos-task123.sha256"
