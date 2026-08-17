#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GUESTS_ROOT=$(CDPATH= cd -- "$TASK3_ROOT/.." && pwd)
RTIPC_COMMON="$GUESTS_ROOT/rt-ipc/common"
TASK123_INIT="$GUESTS_ROOT/linux-net/init-task123"
TASK3_SERVICE="$TASK3_ROOT/buildroot/rootfs-overlay/etc/init.d/S99task3"

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
test -x "$TASK123_INIT"
for token in \
    '--port 9877' \
    'TASK2_LINUX_END status=FAIL exit_status=%s' \
    'TASK3_LINUX_END status=FAIL exit_status=%s' \
    'TASK123_LINUX_END status=FAIL'; do
    grep -F -- "$token" "$TASK123_INIT" >/dev/null
done
test "$(grep -Fc '/bin/busybox poweroff -f' "$TASK123_INIT")" -eq 1
service_commands=$(sed -e '/^#!/d' -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' "$TASK3_SERVICE")
test "$service_commands" = 'exec /init'
if grep -F 'poweroff -f' "$TASK3_SERVICE" >/dev/null; then
    echo 'S99task3 must not power off independently' >&2
    exit 1
fi

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
