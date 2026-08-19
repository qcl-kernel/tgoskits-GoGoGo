#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNNER="$TASK3_ROOT/scripts/run_faults.sh"
SUMMARIZER="$TASK3_ROOT/scripts/summarize_faults.py"
RTTHREAD_SERVER="$TASK3_ROOT/src/rtthread/task3_server.c"

[ -x "$RUNNER" ] || { echo 'run_faults.sh is not executable' >&2; exit 1; }
[ -f "$SUMMARIZER" ] || { echo 'summarize_faults.py is missing' >&2; exit 1; }
[ -f "$RTTHREAD_SERVER" ] || { echo 'task3_server.c is missing' >&2; exit 1; }

for case_name in drop-control drop-status duplicate-frame delayed-server malformed; do
    grep -F "$case_name" "$RUNNER" >/dev/null
done
for contract in case_dir fault-summary.json summarize_faults.py; do
    grep -F "$contract" "$RUNNER" >/dev/null
done
for marker in TASK3_FAULT_DUPLICATE TASK3_FAULT_MALFORMED \
    TASK3_FAULT_DELAYED_SERVER; do
    grep -F "$marker" "$SUMMARIZER" >/dev/null
done
grep -F 'applied_delta' "$SUMMARIZER" >/dev/null
grep -F 'application_errors' "$SUMMARIZER" >/dev/null
grep -F 'rt_kprintf("TASK3_FAULT_DELAYED_SERVER delay_ms=%d\n",' \
    "$RTTHREAD_SERVER" >/dev/null

DEMO="$TASK3_ROOT/scripts/run_demo.sh"
if grep -E '(^|[[:space:]])(pkill|killall)([[:space:]]|$)' "$RUNNER" "$DEMO" >/dev/null; then
    echo 'fault runner may only terminate its owned PIDs' >&2
    exit 1
fi
grep -F 'linux_pid=' "$DEMO" >/dev/null
grep -F 'rtthread_pid=' "$DEMO" >/dev/null

echo 'test_fault_contract: PASS'
