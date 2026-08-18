#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

process_is_running() {
    pid=$1
    [ -r "/proc/$pid/stat" ] || return 1
    state=$(awk '{ print $3 }' "/proc/$pid/stat")
    [ "$state" != Z ]
}

assert_process_stopped() {
    pid=$1
    label=$2
    deadline_ns=$(( $(date +%s%N) + 2000000000 ))
    while process_is_running "$pid"; do
        if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
            kill -KILL "$pid" 2>/dev/null || true
            echo "FAIL: $label is still running (pid=$pid)" >&2
            exit 1
        fi
        sleep 0.01
    done
}

write_stubborn_command() {
    command_file=$1
    cat > "$command_file" <<'EOF'
trap '' HUP INT TERM
echo $$ > "$1"
bash -c 'trap "" HUP INT TERM; while :; do sleep 1; done' &
echo $! > "$2"
if [ -n "$3" ]; then
    echo "$3" >> "$4"
fi
while :; do sleep 1; done
EOF
}

marker_log="$TMP_DIR/marker.log"
child_pid_file="$TMP_DIR/marker.pid"
reported_pid_file="$TMP_DIR/reported.pid"
start=$(date +%s)
RUN_UNTIL_CHILD_PID_FILE="$reported_pid_file" \
"$RUN_UNTIL" 5 "$marker_log" 'CLIENT COMPLETE' -- sh -c '
    echo $$ > "$1"
    sleep 0.1
    echo "CLIENT COMPLETE" >> "$2"
    sleep 10
' sh "$child_pid_file" "$marker_log"
elapsed=$(( $(date +%s) - start ))

if [ "$elapsed" -ge 5 ]; then
    echo "FAIL: marker completion waited for the full timeout" >&2
    exit 1
fi
if kill -0 "$(cat "$child_pid_file")" 2>/dev/null; then
    echo "FAIL: completed command is still running" >&2
    exit 1
fi
if [ "$(cat "$reported_pid_file")" != "$(cat "$child_pid_file")" ]; then
    echo "FAIL: helper did not report the exact child PID" >&2
    exit 1
fi

multi_log="$TMP_DIR/multi.log"
multi_pid_file="$TMP_DIR/multi.pid"
"$RUN_UNTIL" 5 "$multi_log" 'CLIENT COMPLETE' 'STABILITY COMPLETE' -- sh -c '
    echo $$ > "$1"
    echo "CLIENT COMPLETE" >> "$2"
    sleep 0.2
    echo "STABILITY COMPLETE" >> "$2"
    sleep 10
' sh "$multi_pid_file" "$multi_log"
if ! grep -Fq 'STABILITY COMPLETE' "$multi_log"; then
    echo "FAIL: command stopped before every required marker appeared" >&2
    exit 1
fi
if kill -0 "$(cat "$multi_pid_file")" 2>/dev/null; then
    echo "FAIL: multi-marker command is still running" >&2
    exit 1
fi

timeout_log="$TMP_DIR/timeout.log"
timeout_pid_file="$TMP_DIR/timeout.pid"
while [ "$(date +%N)" -lt 700000000 ]; do
    sleep 0.01
done
timeout_start_ns=$(date +%s%N)
set +e
"$RUN_UNTIL" 1 "$timeout_log" 'NEVER WRITTEN' -- sh -c '
    echo $$ > "$1"
    sleep 10
' sh "$timeout_pid_file"
timeout_rc=$?
set -e
timeout_elapsed_ms=$(( ($(date +%s%N) - timeout_start_ns) / 1000000 ))
if [ "$timeout_rc" -ne 124 ]; then
    echo "FAIL: timeout returned $timeout_rc instead of 124" >&2
    exit 1
fi
if [ "$timeout_elapsed_ms" -lt 900 ]; then
    echo "FAIL: one-second timeout expired after only ${timeout_elapsed_ms}ms" >&2
    exit 1
fi
if kill -0 "$(cat "$timeout_pid_file")" 2>/dev/null; then
    echo "FAIL: timed-out command is still running" >&2
    exit 1
fi

exit_log="$TMP_DIR/exit.log"
set +e
"$RUN_UNTIL" 5 "$exit_log" 'NEVER WRITTEN' -- sh -c 'exit 7'
exit_rc=$?
set -e
if [ "$exit_rc" -ne 7 ]; then
    echo "FAIL: child exit status changed from 7 to $exit_rc" >&2
    exit 1
fi

marker_then_fail_log="$TMP_DIR/marker-then-fail.log"
set +e
"$RUN_UNTIL" 5 "$marker_then_fail_log" 'CLIENT COMPLETE' -- sh -c '
    echo "CLIENT COMPLETE" >> "$1"
    exit 37
' sh "$marker_then_fail_log"
marker_then_fail_rc=$?
set -e
if [ "$marker_then_fail_rc" -ne 37 ]; then
    echo "FAIL: marker must not hide child exit status 37 (got $marker_then_fail_rc)" >&2
    exit 1
fi

for leader_exit_rc in 143 137; do
    descendant_log="$TMP_DIR/marker-leader-${leader_exit_rc}.log"
    descendant_pid_file="$TMP_DIR/marker-leader-${leader_exit_rc}-descendant.pid"
    set +e
    timeout -k 1 4 "$RUN_UNTIL" 5 "$descendant_log" 'CLIENT COMPLETE' -- \
        bash -c '
            bash -c '\''trap "" HUP INT TERM; while :; do sleep 1; done'\'' &
            echo $! > "$1"
            echo "CLIENT COMPLETE" >> "$2"
            exit "$3"
        ' bash "$descendant_pid_file" "$descendant_log" "$leader_exit_rc"
    descendant_rc=$?
    set -e
    if [ "$descendant_rc" -ne "$leader_exit_rc" ]; then
        echo "FAIL: marker hid leader exit $leader_exit_rc (got $descendant_rc)" >&2
        exit 1
    fi
    assert_process_stopped "$(cat "$descendant_pid_file")" \
        "marker leader-$leader_exit_rc descendant"
done

stubborn_command="$TMP_DIR/stubborn-command.sh"
write_stubborn_command "$stubborn_command"

stubborn_marker_log="$TMP_DIR/stubborn-marker.log"
stubborn_marker_child="$TMP_DIR/stubborn-marker-child.pid"
stubborn_marker_grandchild="$TMP_DIR/stubborn-marker-grandchild.pid"
set +e
timeout -k 1 4 "$RUN_UNTIL" 5 "$stubborn_marker_log" 'CLIENT COMPLETE' -- \
    bash "$stubborn_command" "$stubborn_marker_child" \
    "$stubborn_marker_grandchild" 'CLIENT COMPLETE' "$stubborn_marker_log"
stubborn_marker_rc=$?
set -e
if [ "$stubborn_marker_rc" -ne 0 ]; then
    echo "FAIL: stubborn marker process group returned $stubborn_marker_rc instead of 0" >&2
    exit 1
fi
assert_process_stopped "$(cat "$stubborn_marker_child")" \
    "marker-path child"
assert_process_stopped "$(cat "$stubborn_marker_grandchild")" \
    "marker-path grandchild"

stubborn_timeout_log="$TMP_DIR/stubborn-timeout.log"
stubborn_timeout_child="$TMP_DIR/stubborn-timeout-child.pid"
stubborn_timeout_grandchild="$TMP_DIR/stubborn-timeout-grandchild.pid"
set +e
timeout -k 1 4 "$RUN_UNTIL" 1 "$stubborn_timeout_log" 'NEVER WRITTEN' -- \
    bash "$stubborn_command" "$stubborn_timeout_child" \
    "$stubborn_timeout_grandchild" '' "$stubborn_timeout_log"
stubborn_timeout_rc=$?
set -e
if [ "$stubborn_timeout_rc" -ne 124 ]; then
    echo "FAIL: stubborn timeout returned $stubborn_timeout_rc instead of 124" >&2
    exit 1
fi
assert_process_stopped "$(cat "$stubborn_timeout_child")" \
    "timeout-path child"
assert_process_stopped "$(cat "$stubborn_timeout_grandchild")" \
    "timeout-path grandchild"

for signal_case in HUP:129 INT:130 TERM:143; do
    signal_name=${signal_case%%:*}
    expected_rc=${signal_case##*:}
    signal_log="$TMP_DIR/stubborn-signal-$signal_name.log"
    signal_child="$TMP_DIR/stubborn-signal-$signal_name-child.pid"
    signal_grandchild="$TMP_DIR/stubborn-signal-$signal_name-grandchild.pid"

    setsid bash -c 'trap - HUP INT TERM; exec "$@"' bash \
        "$RUN_UNTIL" 30 "$signal_log" 'NEVER WRITTEN' -- \
        bash "$stubborn_command" "$signal_child" "$signal_grandchild" '' "$signal_log" &
    helper_pid=$!
    pid_deadline_ns=$(( $(date +%s%N) + 2000000000 ))
    while [ ! -s "$signal_child" ] || [ ! -s "$signal_grandchild" ]; do
        if ! kill -0 "$helper_pid" 2>/dev/null || \
           [ "$(date +%s%N)" -ge "$pid_deadline_ns" ]; then
            kill -KILL "$helper_pid" 2>/dev/null || true
            echo "FAIL: $signal_name test process tree did not start" >&2
            exit 1
        fi
        sleep 0.01
    done

    kill -s "$signal_name" "$helper_pid"
    helper_deadline_ns=$(( $(date +%s%N) + 3000000000 ))
    while kill -0 "$helper_pid" 2>/dev/null; do
        if [ "$(date +%s%N)" -ge "$helper_deadline_ns" ]; then
            kill -KILL "$helper_pid" 2>/dev/null || true
            echo "FAIL: $signal_name cleanup did not finish within its grace period" >&2
            exit 1
        fi
        sleep 0.01
    done
    set +e
    wait "$helper_pid"
    signal_rc=$?
    set -e
    if [ "$signal_rc" -ne "$expected_rc" ]; then
        echo "FAIL: $signal_name returned $signal_rc instead of $expected_rc" >&2
        exit 1
    fi
    assert_process_stopped "$(cat "$signal_child")" \
        "$signal_name-path child"
    assert_process_stopped "$(cat "$signal_grandchild")" \
        "$signal_name-path grandchild"
done

echo "PASS: run-until-log-marker lifecycle"
