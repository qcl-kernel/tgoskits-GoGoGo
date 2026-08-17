#!/bin/sh
set -eu

die() {
    printf '%s\n' "task3: $*" >&2
    return 1
}

# POSIX sh exposes the caller's $0 when this file is sourced. Each executable
# script must therefore resolve its own directory and provide TASK3_ROOT.
[ -n "${TASK3_ROOT:-}" ] || die "TASK3_ROOT must be set before sourcing common.sh"
TASK3_ROOT=$(CDPATH= cd -- "$TASK3_ROOT" && pwd)
BUILD_DIR=${BUILD_DIR:-"$TASK3_ROOT/build"}
RTIPC_DIR=${RTIPC_DIR:-"$TASK3_ROOT/../protocol/c"}
export TASK3_ROOT BUILD_DIR RTIPC_DIR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

verify_sha256() {
    file=$1
    expected=$2
    require_command sha256sum
    require_command awk
    [ -f "$file" ] || die "checksum input not found: $file"
    checksum_line=$(sha256sum "$file") || return $?
    actual=$(printf '%s\n' "$checksum_line" | awk '{print $1}') || return $?
    [ "$actual" = "$expected" ] || die "sha256 mismatch for $file (expected $expected, got $actual)"
    printf '%s=verified\n' "$(basename "$file")"
}
