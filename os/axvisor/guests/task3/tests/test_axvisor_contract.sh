#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GUESTS_ROOT=$(CDPATH= cd -- "$TASK3_ROOT/.." && pwd)
RTIPC_COMMON="$GUESTS_ROOT/rt-ipc/common"
TASK123_INIT="$GUESTS_ROOT/linux-net/init-task123"
TASK3_SERVICE="$TASK3_ROOT/buildroot/rootfs-overlay/etc/init.d/S99task3"
TASK3_SERVER="$TASK3_ROOT/src/rtthread/task3_server.c"
TASK3_SERVER_CORE="$TASK3_ROOT/src/common/task3_server_core.c"
RTTHREAD_PATCH_SCRIPT="$TASK3_ROOT/../../patches/rtthread/apply-rtthread-patches.sh"

test -f "$TASK3_SERVER_CORE"
if [ -e "$TASK3_ROOT/src/common/task3_server.c" ]; then
    echo 'common task3_server.c collides with the RT-Thread adapter name' >&2
    exit 1
fi
grep -F 'cp "$TASK3DIR/src/common/task3_server_core.c" \\
    "$TASK3_APPDIR/task3_server_core.c"' "$RTTHREAD_PATCH_SCRIPT" >/dev/null
grep -F 'cp "$TASK3DIR/src/common/task3_server_core.h" \\
    "$TASK3_APPDIR/task3_server_core.h"' "$RTTHREAD_PATCH_SCRIPT" >/dev/null
if grep -Eq 'cp "[^"]*/task3_server\.c" "\\$TASK3_APPDIR/"' \
    "$RTTHREAD_PATCH_SCRIPT"; then
    echo 'RT-Thread Task 3 installation copies an ambiguous task3_server.c' >&2
    exit 1
fi

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
    "$TASK3_SERVER"
grep -F 'TASK3_RTOS_READY ip=192.168.77.30 port=9877' \
    "$TASK3_SERVER" >/dev/null
grep -Eq 'TASK3_SERVER_RECV_TIMEOUT_MS[[:space:]]*=[[:space:]]*10,' \
    "$TASK3_SERVER" >/dev/null
timeout_config=$(sed -n \
    '/^static int configure_receive_timeout(/,/^}/p' "$TASK3_SERVER")
printf '%s\n' "$timeout_config" |
    grep -Eq '^static int configure_receive_timeout\(int socket_fd\)'
printf '%s\n' "$timeout_config" |
    grep -Eq '\.tv_usec[[:space:]]*=[[:space:]]*TASK3_SERVER_RECV_TIMEOUT_MS[[:space:]]*\*[[:space:]]*1000,'
printf '%s\n' "$timeout_config" |
    grep -Eq 'setsockopt\(socket_fd,[[:space:]]*SOL_SOCKET,[[:space:]]*SO_RCVTIMEO,[[:space:]]*&timeout,'
printf '%s\n' "$timeout_config" |
    grep -Eq 'return[[:space:]]+setsockopt\(socket_fd,'
grep -Eq 'if[[:space:]]*\([[:space:]]*configure_receive_timeout\(runtime\.socket_fd\)[[:space:]]*!=[[:space:]]*0[[:space:]]*\)' "$TASK3_SERVER"
grep -F 'TASK3_RTOS_ERROR receive-timeout' "$TASK3_SERVER" >/dev/null
timeout_failure_block=$(sed -n \
    '/if[[:space:]]*(configure_receive_timeout(runtime.socket_fd) != 0)/,/^    }/p' "$TASK3_SERVER")
printf '%s\n' "$timeout_failure_block" | grep -F 'closesocket(runtime.socket_fd)' >/dev/null
printf '%s\n' "$timeout_failure_block" | grep -F 'runtime.socket_fd = -1' >/dev/null
printf '%s\n' "$timeout_failure_block" | grep -F 'return;' >/dev/null
timeout_failure_line=$(grep -n 'TASK3_RTOS_ERROR receive-timeout' "$TASK3_SERVER" | cut -d: -f1)
bind_line=$(grep -n 'if (bind(runtime.socket_fd' "$TASK3_SERVER" | cut -d: -f1)
ready_line=$(grep -n 'TASK3_RTOS_READY' "$TASK3_SERVER" | cut -d: -f1)
[ "$timeout_failure_line" -lt "$bind_line" ]
[ "$timeout_failure_line" -lt "$ready_line" ]
if grep -F 'TASK3_RTOS_STATS' \
    "$TASK3_SERVER" >/dev/null; then
    echo 'Task 3 server still emits periodic debug telemetry' >&2
    exit 1
fi
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
