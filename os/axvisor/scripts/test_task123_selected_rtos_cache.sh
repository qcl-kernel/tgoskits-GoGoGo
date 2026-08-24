#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_task123.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

source "$RUNNER"

SHARED_ARTIFACT_DIR="$tmp/shared-cache"
mkdir -- "$SHARED_ARTIFACT_DIR"
printf 'old zephyr image\n' > "$SHARED_ARTIFACT_DIR/zephyr.bin"

rtos=zephyr
unset ZEPHYR_IMAGE
resolve_input_artifact ZEPHYR_IMAGE zephyr zephyr.bin 0
[[ -z "${ZEPHYR_IMAGE:-}" ]] || {
    echo "FAIL: selected Zephyr input reused an unvalidated shared cache image" >&2
    exit 1
}

printf 'current zephyr image\n' > "$tmp/current-zephyr.bin"
staged_image="$(stage_shared_artifact zephyr zephyr.bin "$tmp/current-zephyr.bin" 1)"
cmp -s "$tmp/current-zephyr.bin" "$staged_image" || {
    echo "FAIL: selected Zephyr input did not refresh the shared cache" >&2
    exit 1
}

echo "PASS: selected RTOS images do not reuse stale shared cache entries"
