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
MODEL_DIR="$TASK3_ROOT/build/model"
INITRAMFS=${TASK123_INITRAMFS:-"$TASK3_ROOT/build/images/linux/rootfs.cpio"}
EXPECTED_TASK2_BIN="$ROOT/os/axvisor/guests/rt-ipc/linux/target/rtipic-client"
EXPECTED_TASK3_BIN=${TASK123_EXPECTED_TASK3_BIN:-"$TASK3_ROOT/build/buildroot/target/usr/bin/task3-linux"}

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

assert_init_wrapper() {
    commands=$(sed -e '/^#!/d' -e '/^[[:space:]]*#/d' \
        -e '/^[[:space:]]*$/d' "$SERVICE")
    [ "$commands" = 'exec /init' ] ||
        fail 'S99task3 must contain only exec /init'
    if grep -F 'poweroff -f' "$SERVICE" >/dev/null; then
        fail 'S99task3 must not power off independently'
    fi
}

test -x "$INIT" || fail 'combined /init source is missing or not executable'
test -x "$SERVICE" || fail 'S99task3 is missing or not executable'
sh -n "$INIT"
sh -n "$SERVICE"
sh -n "$BUILD"

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

assert_init_wrapper

for token in \
    '$(MAKE) -C $(@D)/task2/linux' 'target/rtipic-client' \
    '$(TARGET_DIR)/bin/rtipic-client' '$(TARGET_DIR)/init'; do
    require_line "$token" "$PACKAGE"
done
for token in \
    'all: target/rtipic-client' 'rtipc_client.c' 'rtipc_client_report.c' \
    'rtipc_fault.c' 'rtipc_shutdown.c' '../common/rt_ipc.c'; do
    require_line "$token" "$TASK2_MAKE"
done
for token in \
    'guests/rt-ipc/linux' 'guests/rt-ipc/common' \
    'linux-net/init-task123' 'line-follow.y4m' 'truth.csv'; do
    require_line "$token" "$BUILD"
done

if [ "${TASK123_CONTRACT_STATIC_ONLY:-0}" = 1 ]; then
    printf '%s\n' \
        'test_task123_linux_image_contract: PASS (source checks only; not image verification)'
    exit 0
fi

for command in cpio readelf file cmp awk sed; do
    command -v "$command" >/dev/null 2>&1 ||
        fail "$command is required for the dynamic image contract"
done
test -s "$INITRAMFS" || fail "generated initramfs not found: $INITRAMFS"
test -s "$MODEL_DIR/line-follow.y4m" || fail 'current model video is missing'
test -s "$MODEL_DIR/truth.csv" || fail 'current model truth is missing'
test -s "$EXPECTED_TASK2_BIN" ||
    fail "canonical Task 2 binary not found: $EXPECTED_TASK2_BIN"
test -s "$EXPECTED_TASK3_BIN" ||
    fail "canonical Task 3 binary not found: $EXPECTED_TASK3_BIN"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
rootfs="$tmp_dir/rootfs"
mkdir -p "$rootfs"

extract_required_files() {
    cpio_args='bin/rtipic-client ./bin/rtipic-client
usr/bin/task3-linux ./usr/bin/task3-linux
opt/task3/line-follow.y4m ./opt/task3/line-follow.y4m
opt/task3/truth.csv ./opt/task3/truth.csv
init ./init'
    if gzip -t "$INITRAMFS" 2>/dev/null; then
        gzip -dc "$INITRAMFS" |
            (cd "$rootfs" && cpio --quiet -id --no-absolute-filenames $cpio_args)
    else
        (cd "$rootfs" &&
            cpio --quiet -id --no-absolute-filenames $cpio_args <"$INITRAMFS")
    fi
}

extract_required_files
for path in \
    bin/rtipic-client usr/bin/task3-linux opt/task3/line-follow.y4m \
    opt/task3/truth.csv init; do
    extracted="$rootfs/$path"
    [ -f "$extracted" ] && [ ! -L "$extracted" ] && [ -s "$extracted" ] ||
        fail "image path is not a non-empty regular file: /$path"
done

assert_aarch64_elf() {
    binary=$1
    description=$(file -b "$binary")
    printf '%s\n' "$description" | grep -Eq 'ELF 64-bit.*ARM aarch64' ||
        fail "$binary is not identified by file as AArch64 ELF: $description"
    header="$tmp_dir/readelf-header"
    readelf -h "$binary" >"$header" 2>/dev/null ||
        fail "readelf rejected $binary"
    grep -Eq 'Class:[[:space:]]+ELF64' "$header" ||
        fail "$binary is not ELF64"
    grep -Eq 'Machine:[[:space:]]+AArch64' "$header" ||
        fail "$binary is not AArch64"
}

assert_aarch64_elf "$rootfs/bin/rtipic-client"
assert_aarch64_elf "$rootfs/usr/bin/task3-linux"
cmp "$EXPECTED_TASK2_BIN" "$rootfs/bin/rtipic-client" >/dev/null ||
    fail 'generated rtipic-client does not match the canonical Task 2 build output'
cmp "$EXPECTED_TASK3_BIN" "$rootfs/usr/bin/task3-linux" >/dev/null ||
    fail 'generated task3-linux does not match the canonical Task 3 build output'
cmp "$INIT" "$rootfs/init" >/dev/null ||
    fail 'generated /init does not match init-task123'
cmp "$MODEL_DIR/line-follow.y4m" "$rootfs/opt/task3/line-follow.y4m" >/dev/null ||
    fail 'generated video does not match the current model output'
cmp "$MODEL_DIR/truth.csv" "$rootfs/opt/task3/truth.csv" >/dev/null ||
    fail 'generated truth does not match the current model output'

harness="$tmp_dir/harness"
mkdir -p "$harness/bin"
events="$harness/events"
cmdline="$harness/cmdline"
online="$harness/online"
fake_busybox="$harness/bin/busybox"
fake_task2="$harness/bin/rtipic-client"
fake_task3="$harness/bin/task3-linux"
harness_init="$harness/init"
expected="$harness/expected"
printf '%s\n' '0-1' >"$online"

sed \
    -e '1c#!/bin/sh' \
    -e "s#/bin/busybox#$fake_busybox#g" \
    -e "s#/bin/rtipic-client#$fake_task2#g" \
    -e "s#/usr/bin/task3-linux#$fake_task3#g" \
    -e "s#/proc/cmdline#$cmdline#g" \
    -e "s#/sys/devices/system/cpu/online#$online#g" \
    -e "s#> /dev/console#>> $events#g" \
    "$rootfs/init" >"$harness_init"

cat >"$fake_busybox" <<'EOF_BUSYBOX'
#!/bin/sh
applet=$1
shift
case "$applet" in
    cat) exec /bin/cat "$@" ;;
    nproc) printf '%s\n' 2 ;;
    mkdir|mount|ip|sync) exit 0 ;;
    poweroff)
        printf 'POWEROFF' >>"$TASK123_EVENTS"
        for argument in "$@"; do
            printf ' <%s>' "$argument" >>"$TASK123_EVENTS"
        done
        printf '\n' >>"$TASK123_EVENTS"
        ;;
    *) exit 99 ;;
esac
EOF_BUSYBOX

cat >"$fake_task2" <<'EOF_TASK2'
#!/bin/sh
printf 'TASK2_ARGS'
for argument in "$@"; do
    printf ' <%s>' "$argument"
done
printf '\n'
exit "${TASK2_FAKE_STATUS:-0}"
EOF_TASK2

cat >"$fake_task3" <<'EOF_TASK3'
#!/bin/sh
printf 'TASK3_ARGS'
for argument in "$@"; do
    printf ' <%s>' "$argument"
done
printf '\n'
exit "${TASK3_FAKE_STATUS:-0}"
EOF_TASK3
chmod +x "$fake_busybox" "$fake_task2" "$fake_task3" "$harness_init"

run_init() {
    command_line=$1
    task2_status=$2
    task3_status=$3
    expected_status=$4
    : >"$events"
    printf '%s\n' "$command_line" >"$cmdline"
    if TASK123_EVENTS="$events" TASK2_FAKE_STATUS="$task2_status" \
        TASK3_FAKE_STATUS="$task3_status" "$harness_init"; then
        actual_status=0
    else
        actual_status=$?
    fi
    [ "$actual_status" -eq "$expected_status" ] ||
        fail "/init returned $actual_status, expected $expected_status for: $command_line"
    [ "$(grep -c '^POWEROFF <-f>$' "$events")" -eq 1 ] ||
        fail "/init did not power off exactly once for: $command_line"
}

assert_events() {
    scenario=$1
    if ! cmp "$expected" "$events" >/dev/null; then
        diff -u "$expected" "$events" >&2 || true
        fail "unexpected /init event sequence: $scenario"
    fi
}

task2_args='TASK2_ARGS <--host> <192.168.77.30> <--port> <9876> <--count> <23> <--fault-profile> <reliability>'
task3_args='TASK3_ARGS <--video> </opt/task3/line-follow.y4m> <--truth> </opt/task3/truth.csv> <--peer> <192.168.77.30> <--port> <9877> <--frames> <3> <--csv> </tmp/task3-frames.csv>'

assert_success_profile() {
    profile=$1
    task3_extra=$2
    run_init "task2.count=23 task2.fault=reliability task3.frames=3 task3.fault=$profile" \
        0 0 0
    cat >"$expected" <<EOF_SUCCESS
LINUX_SMP_READY configured=2 online=0-1 nproc=2
TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
TASK2_LINUX_BEGIN port=9876
$task2_args
TASK2_LINUX_END status=PASS
TASK3_LINUX_READY ip=192.168.77.11 peer=192.168.77.30:9877
$task3_args$task3_extra
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
POWEROFF <-f>
EOF_SUCCESS
    assert_events "$profile"
}

assert_success_profile normal ''
assert_success_profile drop-control ' <--drop-tx-seq> <2>'
assert_success_profile drop-status ''
assert_success_profile duplicate-frame ' <--duplicate-frame-once>'
assert_success_profile delayed-server ''
assert_success_profile malformed ' <--malformed-once>'

run_init 'task2.count=23 task2.fault=none task3.frames=3 task3.fault=normal' \
    7 0 7
cat >"$expected" <<EOF_TASK2_FAIL
LINUX_SMP_READY configured=2 online=0-1 nproc=2
TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
TASK2_LINUX_BEGIN port=9876
TASK2_ARGS <--host> <192.168.77.30> <--port> <9876> <--count> <23> <--fault-profile> <none>
TASK2_LINUX_END status=FAIL exit_status=7
TASK3_LINUX_READY ip=192.168.77.11 peer=192.168.77.30:9877
$task3_args
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=FAIL
POWEROFF <-f>
EOF_TASK2_FAIL
assert_events 'Task 2 failure'

run_init 'task2.count=23 task2.fault=none task3.frames=3 task3.fault=normal' \
    0 9 9
cat >"$expected" <<EOF_TASK3_FAIL
LINUX_SMP_READY configured=2 online=0-1 nproc=2
TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
TASK2_LINUX_BEGIN port=9876
TASK2_ARGS <--host> <192.168.77.30> <--port> <9876> <--count> <23> <--fault-profile> <none>
TASK2_LINUX_END status=PASS
TASK3_LINUX_READY ip=192.168.77.11 peer=192.168.77.30:9877
$task3_args
TASK3_LINUX_END status=FAIL exit_status=9
TASK123_LINUX_END status=FAIL
POWEROFF <-f>
EOF_TASK3_FAIL
assert_events 'Task 3 failure'

assert_invalid() {
    command_line=$1
    invalid_name=$2
    run_init "$command_line" 0 0 2
    cat >"$expected" <<EOF_INVALID
TASK123_LINUX_INVALID $invalid_name
TASK123_LINUX_END status=FAIL
POWEROFF <-f>
EOF_INVALID
    assert_events "invalid $invalid_name"
}

assert_invalid 'task2.count=' task2.count
assert_invalid 'task2.count=0' task2.count
assert_invalid 'task2.count=-1' task2.count
assert_invalid 'task2.count=nope' task2.count
assert_invalid 'task2.count=999999999999999999999999999999999999' task2.count
assert_invalid 'task2.fault=bad' task2.fault
assert_invalid 'task3.frames=' task3.frames
assert_invalid 'task3.frames=0' task3.frames
assert_invalid 'task3.frames=601' task3.frames
assert_invalid 'task3.frames=nope' task3.frames
assert_invalid 'task3.fault=bad' task3.fault
assert_invalid 'task2.unknown=1' task2.unknown
assert_invalid 'task3.unknown=1' task3.unknown
assert_invalid 'task3.drop_tx_seq=2' task3.drop_tx_seq
assert_invalid 'task3.duplicate_frame_once=1' task3.duplicate_frame_once
assert_invalid 'task3.malformed_once=1' task3.malformed_once

printf '%s\n' 'test_task123_linux_image_contract: PASS (dynamic image and /init behavior)'
