#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/os/axvisor/scripts/run_task123_guest_comparison.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    exec "$RUNNER" --help
fi

# Prefer the persistent, metadata-validated RT-Thread build used by the
# realtime baseline. If it is absent, the runner builds a fresh image and
# writes its metadata in the per-run artifact cache.
rtthread_build_root="${RTTHREAD_NATIVE_SRC:-$SCRIPT_DIR/tmp/rt-thread-5.2.2-native-current}"
rtthread_default_image="$rtthread_build_root/bsp/qemu-virt64-aarch64/rtthread.bin"
rtthread_image="${RTTHREAD_IMAGE:-}"
if [[ -z "$rtthread_image" && -f "$rtthread_default_image" &&
    -f "$rtthread_default_image.meta.json" ]]; then
    rtthread_image="$rtthread_default_image"
fi

runner_environment=(
    RTTHREAD_REQUIRE_IMAGE_METADATA=1
)
if [[ -n "$rtthread_image" ]]; then
    rtthread_metadata="${RTTHREAD_IMAGE_META:-$rtthread_image.meta.json}"
    runner_environment+=(
        "RTTHREAD_IMAGE=$rtthread_image"
        "RTTHREAD_IMAGE_META=$rtthread_metadata"
    )
    printf 'RTTHREAD_IMAGE %s\n' "$rtthread_image"
    printf 'RTTHREAD_IMAGE_META %s\n' "$rtthread_metadata"
else
    printf '%s\n' 'RTTHREAD_IMAGE <build-on-demand>'
fi
printf '%s\n' 'RTTHREAD_REQUIRE_IMAGE_METADATA 1'

# Keep the process in the foreground. Git, Buildroot, Cargo, and QEMU inherit
# this terminal directly, and Ctrl+C is delivered to the whole foreground group.
# Quick/full comparisons are diagnostic runs under QEMU TCG: keep collecting a
# complete 1-ms result even when the emulator adds timer-deadline long tails.
exec env "${runner_environment[@]}" "$RUNNER" "${@:---quick}" --allow-qemu-timer-limit
