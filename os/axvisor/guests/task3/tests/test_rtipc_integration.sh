#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$TASK3_ROOT/scripts/common.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

verify_sha256 "$RTIPC_DIR/rt_ipc.h" "$RTIPC_HEADER_SHA256"
verify_sha256 "$RTIPC_DIR/rt_ipc.c" "$RTIPC_SOURCE_SHA256"
make -C "$TASK3_ROOT/tests" test_session
printf '%s\n' 'test_rtipc_integration: PASS'
