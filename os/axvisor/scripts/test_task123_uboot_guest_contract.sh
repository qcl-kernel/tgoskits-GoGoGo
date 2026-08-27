#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
SCRIPT="$ROOT/os/axvisor/scripts/prepare_task123_uboot_guest.sh"

[[ -x "$SCRIPT" ]] || {
    echo "FAIL: Task123 U-Boot guest preparer is missing or not executable" >&2
    exit 1
}
grep -Fq 'build_alpine_linux.sh' "$SCRIPT" || {
    echo "FAIL: U-Boot guest preparer does not build Linux artifacts" >&2
    exit 1
}
grep -Fq 'starryos-task123/build.sh' "$SCRIPT" || {
    echo "FAIL: U-Boot guest preparer does not build StarryOS artifacts" >&2
    exit 1
}

echo "PASS: Task123 U-Boot guest build contract"
