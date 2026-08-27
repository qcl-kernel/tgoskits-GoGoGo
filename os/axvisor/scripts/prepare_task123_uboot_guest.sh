#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
APP_GUEST=""

usage() {
    echo "usage: $0 --app-guest linux|starryos" >&2
    return 2
}

while (($#)); do
    case "$1" in
        --app-guest)
            [[ $# -ge 2 ]] || usage
            APP_GUEST=$2
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

case "$APP_GUEST" in
    linux|starryos) ;;
    *) usage ;;
esac

export TGOS_SOURCE_CACHE="${TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$TGOS_SOURCE_CACHE/uv}"
LINUX_BUILD_ROOT="${TASK123_LINUX_IMAGE_CACHE:-$TGOS_SOURCE_CACHE/task3-alpine-linux/6.12.21-alpine-3.23.0}"
LINUX_KERNEL="$LINUX_BUILD_ROOT/images/linux/Image"
LINUX_INITRAMFS="$LINUX_BUILD_ROOT/images/linux/rootfs.cpio.gz"

if [[ ! -s "$LINUX_KERNEL" || ! -s "$LINUX_INITRAMFS" ]]; then
    env BUILD_DIR="$LINUX_BUILD_ROOT" \
        TASK3_MODEL_DIR="$TGOS_SOURCE_CACHE/task3-model" \
        "$ROOT/os/axvisor/guests/task3/scripts/build_alpine_linux.sh"
fi

[[ -s "$LINUX_KERNEL" && -s "$LINUX_INITRAMFS" ]] || {
    echo "Task123 Linux images were not generated under $LINUX_BUILD_ROOT" >&2
    exit 1
}

if [[ "$APP_GUEST" == starryos ]]; then
    starry_image="$ROOT/target/aarch64-unknown-none-softfloat/release/starryos-task123.bin"
    if [[ ! -s "$starry_image" ]]; then
        env TASK123_LINUX_ROOTFS="$LINUX_INITRAMFS" \
            "$ROOT/os/axvisor/guests/starryos-task123/build.sh" \
            --source-cpio "$LINUX_INITRAMFS"
    fi
    [[ -s "$starry_image" ]] || {
        echo "Task123 StarryOS image was not generated: $starry_image" >&2
        exit 1
    }
fi

printf 'TASK123_GUEST_ARTIFACTS app_guest=%s linux_kernel=%s linux_initramfs=%s\n' \
    "$APP_GUEST" "$LINUX_KERNEL" "$LINUX_INITRAMFS"
