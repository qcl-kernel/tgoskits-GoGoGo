#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
TASK3_ROOT="$ROOT/os/axvisor/guests/task3"
INIT="$ROOT/os/axvisor/guests/linux-net/init-task123"
SERVICE="$TASK3_ROOT/buildroot/rootfs-overlay/etc/init.d/S99task3"
PACKAGE="$TASK3_ROOT/buildroot/package/task3-linux/task3-linux.mk"
BUILD="$TASK3_ROOT/scripts/build_linux.sh"
TASK2_MAKE="$ROOT/os/axvisor/guests/rt-ipc/linux/Makefile"
INITRAMFS=${TASK123_INITRAMFS:-"$TASK3_ROOT/build/images/linux/rootfs.cpio"}

fail() {
    printf 'test_task123_linux_image_contract: %s\n' "$*" >&2
    exit 1
}

require_line() {
    pattern=$1
    file=$2
    grep -F -- "$pattern" "$file" >/dev/null ||
        fail "missing '$pattern' in ${file#$ROOT/}"
}

test -x "$INIT" || fail 'combined /init source is missing or not executable'
test -x "$SERVICE" || fail 'S99task3 is missing or not executable'
sh -n "$INIT"
sh -n "$SERVICE"
sh -n "$BUILD"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
parser="$tmp_dir/parser.sh"
awk '
    /^main "\$@"$/ { next }
    {
        sub("/bin/busybox cat /proc/cmdline",
            "printf \"%s\\\\n\" \"$TASK123_TEST_CMDLINE\"")
        print
    }
' "$INIT" >"$parser"

parse_controls() {
    TASK123_TEST_CMDLINE=$1 sh -c '
        set -eu
        . "$1"
        console() { :; }
        finish() { exit "$1"; }
        parse_command_line
        printf "%s %s %s %s\n" \
            "$task2_count" "$task2_fault" "$task3_frames" "$task3_fault"
    ' task123-parser "$parser"
}

expect_invalid() {
    command_line=$1
    if parse_controls "$command_line" >/dev/null 2>&1; then
        fail "accepted malformed command line: $command_line"
    else
        status=$?
    fi
    [ "$status" -eq 2 ] ||
        fail "malformed command line returned status $status: $command_line"
}

[ "$(parse_controls '')" = '1000 none 600 normal' ] ||
    fail 'default workload controls changed'
[ "$(parse_controls 'task2.count=1 task2.fault=reliability task3.frames=1 task3.fault=malformed')" = \
    '1 reliability 1 malformed' ] || fail 'valid boundary controls were rejected'
for profile in normal drop-control drop-status duplicate-frame delayed-server malformed; do
    [ "$(parse_controls "task3.fault=$profile")" = "1000 none 600 $profile" ] ||
        fail "valid Task 3 fault profile was rejected: $profile"
done
for command_line in \
    'task2.count=' 'task2.count=0' 'task2.count=-1' 'task2.count=nope' \
    'task2.count=999999999999999999999999999999999999' \
    'task2.fault=bad' 'task3.frames=' 'task3.frames=0' \
    'task3.frames=601' 'task3.frames=nope' 'task3.fault=bad' \
    'task2.unknown=1' 'task3.unknown=1'; do
    expect_invalid "$command_line"
done

for marker in \
    'LINUX_SMP_READY configured=2 online=%s nproc=%s' \
    'TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30' \
    'TASK2_LINUX_BEGIN port=9876' \
    'TASK2_LINUX_END status=PASS' \
    'TASK3_LINUX_READY ip=192.168.77.11 peer=192.168.77.30:9877' \
    'TASK3_LINUX_END status=PASS' \
    'TASK123_LINUX_END status=PASS'; do
    require_line "$marker" "$INIT"
done

require_line '/proc/cmdline' "$INIT"
require_line '[ "$value" -gt 0 ]' "$INIT"
require_line '[ "$value" -ge 1 ]' "$INIT"
require_line '[ "$value" -le 600 ]' "$INIT"
require_line '[ "$linux_online_cpus" != 0-1 ]' "$INIT"
require_line '[ "$linux_nproc" != 2 ]' "$INIT"
for token in \
    'task2.count=' 'task2.fault=' 'task3.frames=' 'task3.fault=' \
    'none|reliability' \
    'normal|drop-control|drop-status|duplicate-frame|delayed-server|malformed' \
    '--fault-profile' '--drop-tx-seq 2' '--duplicate-frame-once' \
    '--malformed-once'; do
    require_line "$token" "$INIT"
done

if grep -Eq 'task3\.(drop_tx_seq|duplicate_frame_once|malformed_once)=' "$INIT"; then
    fail 'legacy Task 3 fault command-line controls remain enabled'
fi
if grep -E 'ip addr add' "$INIT" |
    grep -Ev '192\.168\.77\.11/24 dev eth0' >/dev/null; then
    fail '/init configures an address other than 192.168.77.11/24'
fi

require_line '/bin/rtipic-client' "$INIT"
require_line '--port 9876' "$INIT"
require_line '/usr/bin/task3-linux' "$INIT"
require_line '--port 9877' "$INIT"
require_line 'task2_status=$?' "$INIT"
require_line 'task3_status=$?' "$INIT"

awk '
    /^[[:space:]]*parse_command_line[[:space:]]*$/ { parse = NR }
    /\/bin\/rtipic-client/ { task2 = NR }
    /\/usr\/bin\/task3-linux/ { task3 = NR }
    /poweroff -f/ { poweroff = NR; count++ }
    END {
        exit !(parse > 0 && task2 > parse && task3 > task2 &&
               count == 1 && poweroff > task3)
    }
' "$INIT" || fail 'both workloads must finish before the single poweroff'

require_line 'exec /init' "$SERVICE"
if grep -F 'poweroff -f' "$SERVICE" >/dev/null; then
    fail 'S99task3 must delegate to the combined /init without powering off'
fi

for token in \
    '$(MAKE) -C $(@D)/task2/linux' 'target/rtipic-client' \
    '$(TARGET_DIR)/bin/rtipic-client' '$(TARGET_DIR)/init'; do
    require_line "$token" "$PACKAGE"
done
for token in \
    'rtipc_client.c' 'rtipc_client_report.c' 'rtipc_fault.c' \
    'rtipc_shutdown.c' '../common/rt_ipc.c'; do
    require_line "$token" "$TASK2_MAKE"
done
for token in \
    'guests/rt-ipc/linux' 'guests/rt-ipc/common' \
    'linux-net/init-task123' 'line-follow.y4m' 'truth.csv'; do
    require_line "$token" "$BUILD"
done

if [ "${TASK123_CONTRACT_STATIC_ONLY:-0}" = 1 ]; then
    printf '%s\n' 'test_task123_linux_image_contract: PASS (static only)'
    exit 0
fi

test -s "$INITRAMFS" ||
    fail "generated initramfs not found: $INITRAMFS"
command -v cpio >/dev/null 2>&1 || fail 'cpio is required to inspect initramfs'

contents="$tmp_dir/contents"
if gzip -t "$INITRAMFS" 2>/dev/null; then
    gzip -dc "$INITRAMFS" | cpio -it >"$contents" 2>/dev/null
else
    cpio -it <"$INITRAMFS" >"$contents" 2>/dev/null
fi
for path in \
    bin/rtipic-client usr/bin/task3-linux opt/task3/line-follow.y4m \
    opt/task3/truth.csv init; do
    grep -Eq "^(\\./)?$path$" "$contents" ||
        fail "generated initramfs is missing /$path"
done

if gzip -t "$INITRAMFS" 2>/dev/null; then
    gzip -dc "$INITRAMFS" |
        (cd "$tmp_dir" && cpio -id init >/dev/null 2>&1)
else
    (cd "$tmp_dir" && cpio -id init <"$INITRAMFS" >/dev/null 2>&1)
fi
cmp "$INIT" "$tmp_dir/init" >/dev/null ||
    fail 'generated /init does not match init-task123'

printf '%s\n' 'test_task123_linux_image_contract: PASS'
