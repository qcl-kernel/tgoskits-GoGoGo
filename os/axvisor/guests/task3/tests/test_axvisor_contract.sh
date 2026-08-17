#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GUESTS_ROOT=$(CDPATH= cd -- "$TASK3_ROOT/.." && pwd)
RTIPC_COMMON="$GUESTS_ROOT/rt-ipc/common"

grep -Eq '^#define[[:space:]]+RTIPC_HEADER_SIZE[[:space:]]+20$' \
    "$RTIPC_COMMON/rt_ipc.h"
grep -Eq 'uint64_t[[:space:]]+session_id;' "$RTIPC_COMMON/rt_ipc.h"

grep -Eq '^#define[[:space:]]+DEFAULT_PORT[[:space:]]+9876$' \
    "$GUESTS_ROOT/rt-ipc/linux/rtipc_client.c"
grep -Eq '^#define[[:space:]]+RTIPC_PORT[[:space:]]+9876$' \
    "$GUESTS_ROOT/rt-ipc/rtthread/rtipc_server.c"

grep -Eq 'TASK3_DEFAULT_PORT[[:space:]]*=[[:space:]]*9877,' \
    "$TASK3_ROOT/src/linux/main.c"
grep -Eq 'TASK3_SERVER_PORT[[:space:]]*=[[:space:]]*9877,' \
    "$TASK3_ROOT/src/linux/rtipc_client.h"
grep -Eq 'TASK3_SERVER_PORT[[:space:]]*=[[:space:]]*9877,' \
    "$TASK3_ROOT/src/rtthread/task3_server.c"
grep -F 'TASK3_RTOS_READY ip=192.168.77.30 port=9877' \
    "$TASK3_ROOT/src/rtthread/task3_server.c" >/dev/null
grep -F -- '--port 9877' \
    "$TASK3_ROOT/buildroot/rootfs-overlay/etc/init.d/S99task3" >/dev/null

grep -F 'RTIPC_DIR=${RTIPC_DIR:-"$TASK3_ROOT/../rt-ipc/common"}' \
    "$TASK3_ROOT/scripts/common.sh" >/dev/null
grep -F 'RTIPC_DIR ?= ../../rt-ipc/common' \
    "$TASK3_ROOT/tests/Makefile" >/dev/null
for script in build_linux.sh build_rtthread.sh doctor.sh run_demo.sh; do
    if grep -E 'RTIPC_DIR/(include|src)/rt_ipc\.[ch]' \
        "$TASK3_ROOT/scripts/$script" >/dev/null; then
        echo "legacy RT-IPC path remains in scripts/$script" >&2
        exit 1
    fi
done

if find "$TASK3_ROOT" -path "$TASK3_ROOT/build" -prune -o \
    \( -name rt_ipc.c -o -name rt_ipc.h \) -print | grep . >/dev/null; then
    echo "Task 3 contains a duplicate RT-IPC implementation" >&2
    exit 1
fi

grep -F -- '--evidence-mode final' "$TASK3_ROOT/tests/test_run_demo_contract.sh" \
    >/dev/null
grep -F 'AxVisor final evidence' "$TASK3_ROOT/scripts/run_demo.sh" >/dev/null
grep -F 'run_task123.sh' "$TASK3_ROOT/scripts/run_demo.sh" >/dev/null

echo 'test_axvisor_contract: PASS'
