#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/os/axvisor/scripts/run_task123_guest_comparison.sh"
RTTHREAD_METADATA_TOOL="$SCRIPT_DIR/os/axvisor/scripts/rtthread_image_metadata.py"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    exec "$RUNNER" --help
fi

# The root entrypoint delegates --rtos, --app-guest, and --matrix all to the
# guest comparison runner. No selector preserves the existing default path.

# Prefer the persistent, metadata-validated RT-Thread build used by the
# realtime baseline. If it is absent, the runner builds a fresh image and
# writes its metadata in the per-run artifact cache.
rtthread_build_root="${RTTHREAD_NATIVE_SRC:-$SCRIPT_DIR/tmp/rt-thread-5.2.2-native-current}"
rtthread_default_image="$rtthread_build_root/bsp/qemu-virt64-aarch64/rtthread.bin"
rtthread_image="${RTTHREAD_IMAGE:-}"
rtthread_input_digest="$(
    python3 "$RTTHREAD_METADATA_TOOL" input-digest --root "$SCRIPT_DIR"
)"
if [[ -z "$rtthread_image" && -f "$rtthread_default_image" &&
    -f "$rtthread_default_image.meta.json" ]] &&
    python3 "$RTTHREAD_METADATA_TOOL" check \
        --image "$rtthread_default_image" \
        --metadata "$rtthread_default_image.meta.json" \
        --input-digest "$rtthread_input_digest" >/dev/null 2>&1; then
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
allow_timer_limit=--allow-qemu-timer-limit
for argument in "$@"; do
    if [[ "$argument" == "$allow_timer_limit" ]]; then
        allow_timer_limit=
    fi
done

runner_arguments=()
if [[ "$#" -gt 0 ]]; then
    runner_arguments=("$@")
else
    runner_arguments=(--quick)
fi
if [[ -n "$allow_timer_limit" ]]; then
    runner_arguments+=("$allow_timer_limit")
fi

exec env "${runner_environment[@]}" "$RUNNER" "${runner_arguments[@]}"
