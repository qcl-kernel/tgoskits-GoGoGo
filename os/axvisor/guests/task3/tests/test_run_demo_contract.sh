#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
script="$TASK3_ROOT/scripts/run_demo.sh"
waiter="$TASK3_ROOT/scripts/wait_for_marker.sh"

test -x "$script"
test -x "$waiter"
sh -n "$script"
sh -n "$waiter"

grep -F 'rtthread_pid=' "$script" >/dev/null
grep -F 'linux_pid=' "$script" >/dev/null
grep -F 'kill "$rtthread_pid"' "$script" >/dev/null
grep -F 'kill "$linux_pid"' "$script" >/dev/null
grep -F 'wait "$rtthread_pid"' "$script" >/dev/null
grep -F 'wait "$linux_pid"' "$script" >/dev/null
if grep -E 'pkill|killall' "$script" >/dev/null; then
    echo 'run_demo uses a broad process killer' >&2
    exit 1
fi

for argument in \
    '-M virt,gic-version=2' \
    '-cpu cortex-a53' \
    '-netdev socket,id=net0,mcast=230.77.0.1:' \
    '-device virtio-net-device,netdev=net0,mac=' \
    '-smp 2' \
    '-m 256M' \
    '-kernel "$linux_image"' \
    '-initrd "$linux_initrd"' \
    '-smp 1' \
    '-m 128M' \
    '-kernel "$rtthread_image"'; do
    grep -F -- "$argument" "$script" >/dev/null
done
grep -F 'TASK3_RTOS_READY' "$script" >/dev/null
grep -F 'TASK3_SUMMARY_JSON=' "$script" >/dev/null
grep -F 'git_sha=' "$script" >/dev/null
grep -F 'git_status=' "$script" >/dev/null
grep -F 'sha256sum' "$script" >/dev/null
grep -F '60' "$script" >/dev/null
grep -F '180' "$script" >/dev/null
grep -F 'multicast-port' "$script" >/dev/null
grep -F 'build/runs' "$script" >/dev/null

set +e
final_evidence_error=$(sh "$script" --evidence-mode final 2>&1)
final_evidence_rc=$?
set -e
test "$final_evidence_rc" -eq 2
printf '%s\n' "$final_evidence_error" | grep -F 'run_task123.sh' >/dev/null
printf '%s\n' "$final_evidence_error" | grep -F 'AxVisor final evidence' >/dev/null

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
: >"$tmp_dir/log"
(sleep 0.1; printf '%s\n' READY >>"$tmp_dir/log") &
"$waiter" "$tmp_dir/log" READY 2
if "$waiter" "$tmp_dir/log" NEVER 1; then
    echo 'wait_for_marker did not time out' >&2
    exit 1
fi

printf '%s\n' 'test_run_demo_contract: PASS'
