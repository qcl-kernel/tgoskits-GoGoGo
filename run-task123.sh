#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/os/axvisor/scripts/run_task123_guest_comparison.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    exec "$RUNNER" --help
fi

# Keep the process in the foreground. Git, Buildroot, Cargo, and QEMU inherit
# this terminal directly, and Ctrl+C is delivered to the whole foreground group.
# Quick/full comparisons are diagnostic runs under QEMU TCG: keep collecting a
# complete 1-ms result even when the emulator adds timer-deadline long tails.
exec "$RUNNER" "${@:---quick}" --allow-qemu-timer-limit
