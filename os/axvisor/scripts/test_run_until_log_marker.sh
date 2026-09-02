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

internal_error_log="$TMP_DIR/internal-error.log"
internal_error_status_file="$TMP_DIR/internal-error.status"
internal_error_reason_file="$TMP_DIR/internal-error.reason"
mkdir "$TMP_DIR/pid-file-is-a-directory"
set +e
RUN_UNTIL_CHILD_PID_FILE="$TMP_DIR/pid-file-is-a-directory" \
RUN_UNTIL_CHILD_STATUS_FILE="$internal_error_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$internal_error_reason_file" \
"$RUN_UNTIL" 5 "$internal_error_log" 'NEVER WRITTEN' -- sleep 10
internal_error_rc=$?
set -e
if [ "$internal_error_rc" -eq 0 ]; then
    echo "FAIL: PID-file publication error returned success" >&2
    exit 1
fi
if ! grep -Eq '^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$' \
    "$internal_error_status_file" 2>/dev/null; then
    echo "FAIL: internal error did not atomically publish a valid raw status" >&2
    exit 1
fi
if [ "$(cat "$internal_error_reason_file" 2>/dev/null)" != internal-error ]; then
    echo "FAIL: internal error reason was not published" >&2
    exit 1
fi

publication_failure_log="$TMP_DIR/publication-failure.log"
publication_failure_status_file="$TMP_DIR/missing-parent/publication-failure.status"
publication_failure_reason_file="$TMP_DIR/publication-failure.reason"
set +e
RUN_UNTIL_CHILD_STATUS_FILE="$publication_failure_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$publication_failure_reason_file" \
"$RUN_UNTIL" 5 "$publication_failure_log" 'NEVER WRITTEN' -- sh -c 'exit 7'
publication_failure_rc=$?
set -e
if [ "$publication_failure_rc" -ne 7 ]; then
    echo "FAIL: status publication failure changed child exit 7 to $publication_failure_rc" >&2
    exit 1
fi

early_signal_log="$TMP_DIR/early-signal.log"
early_signal_status_file="$TMP_DIR/early-signal.status"
early_signal_reason_file="$TMP_DIR/early-signal.reason"
early_signal_ready_file="$TMP_DIR/early-signal.ready"
early_markers=()
for early_marker_index in $(seq 1 50000); do
    early_markers+=("marker-$early_marker_index")
done
RUN_UNTIL_CHILD_STATUS_FILE="$early_signal_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$early_signal_reason_file" \
RUN_UNTIL_PRE_CHILD_READY_FILE="$early_signal_ready_file" \
    "$RUN_UNTIL" 30 "$early_signal_log" "${early_markers[@]}" -- sleep 10 &
early_signal_pid=$!
early_signal_deadline_ns=$(( $(date +%s%N) + 3000000000 ))
while [ ! -s "$early_signal_ready_file" ]; do
    if ! kill -0 "$early_signal_pid" 2>/dev/null || \
       [ "$(date +%s%N)" -ge "$early_signal_deadline_ns" ]; then
        kill -KILL "$early_signal_pid" 2>/dev/null || true
        echo "FAIL: early-signal helper did not publish its pre-child ready marker" >&2
        exit 1
    fi
    sleep 0.01
done
kill -TERM "$early_signal_pid"
set +e
wait "$early_signal_pid"
early_signal_rc=$?
set -e
if [ "$early_signal_rc" -ne 143 ]; then
    echo "FAIL: early TERM returned $early_signal_rc instead of 143" >&2
    exit 1
fi
if [ "$(cat "$early_signal_status_file" 2>/dev/null)" != 143 ] ||
   [ "$(cat "$early_signal_reason_file" 2>/dev/null)" != signal ]; then
    echo "FAIL: early TERM did not publish valid signal completion" >&2
    exit 1
fi

launch_signal_log="$TMP_DIR/launch-signal.log"
launch_signal_status_file="$TMP_DIR/launch-signal.status"
launch_signal_reason_file="$TMP_DIR/launch-signal.reason"
launch_signal_pid_file="$TMP_DIR/launch-signal.pid"
launch_signal_ready_file="$TMP_DIR/launch-signal.ready"
launch_signal_release_file="$TMP_DIR/launch-signal.release"
launch_signal_tools="$TMP_DIR/launch-signal-tools"
mkdir "$launch_signal_tools"
real_setsid=$(command -v setsid)
cat > "$launch_signal_tools/setsid" <<'EOF'
#!/bin/sh
sleep 0.5
exec "$RUN_UNTIL_REAL_SETSID" "$@"
EOF
chmod +x "$launch_signal_tools/setsid"
RUN_UNTIL_CHILD_PID_FILE="$launch_signal_pid_file" \
RUN_UNTIL_CHILD_STATUS_FILE="$launch_signal_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$launch_signal_reason_file" \
RUN_UNTIL_LAUNCH_READY_FILE="$launch_signal_ready_file" \
RUN_UNTIL_LAUNCH_RELEASE_FILE="$launch_signal_release_file" \
RUN_UNTIL_REAL_SETSID="$real_setsid" \
PATH="$launch_signal_tools:$PATH" \
    "$RUN_UNTIL" 30 "$launch_signal_log" 'NEVER WRITTEN' -- sleep 2 &
launch_signal_helper_pid=$!
launch_signal_deadline_ns=$(( $(date +%s%N) + 3000000000 ))
while [ ! -s "$launch_signal_ready_file" ]; do
    if ! kill -0 "$launch_signal_helper_pid" 2>/dev/null ||
       [ "$(date +%s%N)" -ge "$launch_signal_deadline_ns" ]; then
        kill -TERM "$launch_signal_helper_pid" 2>/dev/null || true
        wait "$launch_signal_helper_pid" 2>/dev/null || true
        echo "FAIL: helper did not expose its child-launch ownership window" >&2
        exit 1
    fi
    sleep 0.01
done
launch_signal_child_pid=$(cat "$launch_signal_pid_file")
kill -TERM "$launch_signal_helper_pid"
touch "$launch_signal_release_file"
set +e
wait "$launch_signal_helper_pid"
launch_signal_rc=$?
set -e
if [ "$launch_signal_rc" -ne 143 ]; then
    echo "FAIL: launch-window TERM returned $launch_signal_rc instead of 143" >&2
    exit 1
fi
if [ "$(cat "$launch_signal_status_file" 2>/dev/null)" != 143 ] ||
   [ "$(cat "$launch_signal_reason_file" 2>/dev/null)" != signal ]; then
    echo "FAIL: launch-window TERM did not publish valid signal completion" >&2
    exit 1
fi
assert_process_stopped "$launch_signal_child_pid" \
    'launch-window child process group leader'

marker_log="$TMP_DIR/marker.log"
child_pid_file="$TMP_DIR/marker.pid"
reported_pid_file="$TMP_DIR/reported.pid"
marker_status_file="$TMP_DIR/marker.status"
marker_reason_file="$TMP_DIR/marker.reason"
start=$(date +%s)
RUN_UNTIL_CHILD_PID_FILE="$reported_pid_file" \
RUN_UNTIL_CHILD_STATUS_FILE="$marker_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$marker_reason_file" \
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
if [ "$(cat "$marker_status_file")" -ne 143 ]; then
    echo "FAIL: marker completion did not preserve raw child status 143" >&2
    exit 1
fi
if [ "$(cat "$marker_reason_file")" != marker-complete ]; then
    echo "FAIL: marker completion reason was not recorded" >&2
    exit 1
fi

fragmented_marker_log="$TMP_DIR/fragmented-marker.log"
set +e
"$RUN_UNTIL" 2 "$fragmented_marker_log" \
    'RTIPC_SERVER_READY ip=192.168.77.30 port=9876' -- sh -c '
    printf "RTIPC_SERVER_READY ip=192.168.77." >> "$1"
    sleep 0.1
    printf "30 port=9876\\n" >> "$1"
    sleep 10
' sh "$fragmented_marker_log"
fragmented_marker_rc=$?
set -e
if [ "$fragmented_marker_rc" -ne 0 ]; then
    echo "FAIL: marker watcher rejected a marker split across writes" >&2
    exit 1
fi

rtos_final_record_log="$TMP_DIR/rtos-final-record.log"
set +e
"$RUN_UNTIL" 2 "$rtos_final_record_log" \
    'TASK3_RTOS_FINAL_COMPLETE' -- sh -c '
    printf "TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_st" >> "$1"
    sleep 0.1
    printf "eps=6 retries=0\n" >> "$1"
    sleep 10
' sh "$rtos_final_record_log"
rtos_final_record_rc=$?
set -e
if [ "$rtos_final_record_rc" -ne 0 ] ||
   ! grep -Fq 'TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0' \
       "$rtos_final_record_log"; then
    echo "FAIL: marker watcher did not wait for the complete RTOS final record" >&2
    exit 1
fi

host_interleaved_marker_log="$TMP_DIR/host-interleaved-marker.log"
set +e
"$RUN_UNTIL" 2 "$host_interleaved_marker_log" \
    'LINUX_SMP_READY configured=2' -- sh -c '
    printf "LINUX_SMP_READY confi" >> "$1"
    sleep 0.1
    printf "\033[37m[ 1.000000 0:1 axvisor::test:1] \033[33mhost record\033[m\r\n\033[mgured=2\\n" >> "$1"
    sleep 10
' sh "$host_interleaved_marker_log"
host_interleaved_marker_rc=$?
set -e
if [ "$host_interleaved_marker_rc" -ne 0 ]; then
    echo "FAIL: marker watcher rejected a guest marker interleaved with an AxVisor host record" >&2
    exit 1
fi

tail_after_marker_log="$TMP_DIR/tail-after-marker.log"
RUN_UNTIL_COMPLETION_GRACE_MS=250 \
"$RUN_UNTIL" 2 "$tail_after_marker_log" 'MARKER COMPLETE' -- sh -c '
    printf "MARKER COMPLETE\\n" >> "$1"
    sleep 0.05
    printf "REPORT TAIL\\n" >> "$1"
    sleep 10
' sh "$tail_after_marker_log"
if ! grep -Fq 'REPORT TAIL' "$tail_after_marker_log"; then
    echo "FAIL: marker completion dropped output written during the drain window" >&2
    exit 1
fi

failure_marker_log="$TMP_DIR/failure-marker.log"
failure_marker_status_file="$TMP_DIR/failure-marker.status"
failure_marker_reason_file="$TMP_DIR/failure-marker.reason"
failure_marker_start_ns=$(date +%s%N)
set +e
RUN_UNTIL_CHILD_STATUS_FILE="$failure_marker_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$failure_marker_reason_file" \
"$RUN_UNTIL" 2 "$failure_marker_log" 'NEVER WRITTEN' \
    --failure-marker 'TASK123_LINUX_END status=FAIL' -- sh -c '
    echo "TASK123_LINUX_END status=FAIL" >> "$1"
    sleep 10
' sh "$failure_marker_log"
failure_marker_rc=$?
set -e
failure_marker_elapsed_ms=$(( ($(date +%s%N) - failure_marker_start_ns) / 1000000 ))
if [ "$failure_marker_rc" -eq 0 ] || [ "$failure_marker_elapsed_ms" -ge 1800 ]; then
    echo "FAIL: failure marker did not stop the child promptly" >&2
    exit 1
fi
if [ "$(cat "$failure_marker_reason_file" 2>/dev/null)" != failure-marker ]; then
    echo "FAIL: failure marker termination reason was not recorded" >&2
    exit 1
fi

host_interleaved_failure_log="$TMP_DIR/host-interleaved-failure.log"
host_interleaved_failure_start_ns=$(date +%s%N)
set +e
"$RUN_UNTIL" 2 "$host_interleaved_failure_log" 'NEVER WRITTEN' \
    --failure-marker 'TASK123_LINUX_END status=FAIL' -- sh -c '
    printf "TASK123_LINUX_END sta" >> "$1"
    printf "\033[37m[ 1.000000 0:1 axvisor::test:1] \033[33mhost record\033[m\r\n\033[mtus=FAIL\\n" >> "$1"
    sleep 10
' sh "$host_interleaved_failure_log"
host_interleaved_failure_rc=$?
set -e
host_interleaved_failure_elapsed_ms=$(( ($(date +%s%N) - host_interleaved_failure_start_ns) / 1000000 ))
if [ "$host_interleaved_failure_rc" -eq 0 ] ||
   [ "$host_interleaved_failure_elapsed_ms" -ge 1800 ]; then
    echo "FAIL: interleaved failure marker did not stop the child promptly" >&2
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

timerslack_log="$TMP_DIR/timerslack.log"
timerslack_value_file="$TMP_DIR/timerslack.value"
RUN_UNTIL_CHILD_TIMERSLACK_NS=1 \
"$RUN_UNTIL" 5 "$timerslack_log" 'TIMERSLACK APPLIED' -- sh -c '
    cat /proc/self/timerslack_ns > "$1"
    echo "TIMERSLACK APPLIED" >> "$2"
    sleep 10
' sh "$timerslack_value_file" "$timerslack_log"
if [ "$(cat "$timerslack_value_file")" != 1 ]; then
    echo "FAIL: child timer slack was not applied before exec" >&2
    exit 1
fi

timerslack_failure_log="$TMP_DIR/timerslack-failure.log"
timerslack_failure_exec_file="$TMP_DIR/timerslack-failure.exec"
set +e
RUN_UNTIL_CHILD_TIMERSLACK_NS=not-a-number \
"$RUN_UNTIL" 5 "$timerslack_failure_log" 'NEVER WRITTEN' -- \
    sh -c ': > "$1"' sh "$timerslack_failure_exec_file"
timerslack_failure_rc=$?
set -e
if [ "$timerslack_failure_rc" -eq 0 ]; then
    echo "FAIL: timer-slack write failure returned success" >&2
    exit 1
fi
if [ -e "$timerslack_failure_exec_file" ]; then
    echo "FAIL: command was executed after timer-slack write failure" >&2
    exit 1
fi

timeout_log="$TMP_DIR/timeout.log"
timeout_pid_file="$TMP_DIR/timeout.pid"
timeout_status_file="$TMP_DIR/timeout.status"
timeout_reason_file="$TMP_DIR/timeout.reason"
while [ "$(date +%N)" -lt 700000000 ]; do
    sleep 0.01
done
timeout_start_ns=$(date +%s%N)
set +e
RUN_UNTIL_CHILD_STATUS_FILE="$timeout_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$timeout_reason_file" \
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
if [ "$(cat "$timeout_status_file")" -ne 143 ] ||
   [ "$(cat "$timeout_reason_file")" != timeout ]; then
    echo "FAIL: timeout child status/reason evidence is incorrect" >&2
    exit 1
fi

exit_log="$TMP_DIR/exit.log"
exit_status_file="$TMP_DIR/exit.status"
exit_reason_file="$TMP_DIR/exit.reason"
set +e
RUN_UNTIL_CHILD_STATUS_FILE="$exit_status_file" \
RUN_UNTIL_TERMINATION_REASON_FILE="$exit_reason_file" \
"$RUN_UNTIL" 5 "$exit_log" 'NEVER WRITTEN' -- sh -c 'exit 7'
exit_rc=$?
set -e
if [ "$exit_rc" -ne 7 ]; then
    echo "FAIL: child exit status changed from 7 to $exit_rc" >&2
    exit 1
fi
if [ "$(cat "$exit_status_file")" -ne 7 ] ||
   [ "$(cat "$exit_reason_file")" != child-exit ]; then
    echo "FAIL: child exit status/reason evidence is incorrect" >&2
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
    signal_status_file="$TMP_DIR/stubborn-signal-$signal_name.status"
    signal_reason_file="$TMP_DIR/stubborn-signal-$signal_name.reason"

    RUN_UNTIL_CHILD_STATUS_FILE="$signal_status_file" \
    RUN_UNTIL_TERMINATION_REASON_FILE="$signal_reason_file" \
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
    case "$(cat "$signal_status_file")" in
        137|143) ;;
        *)
            echo "FAIL: $signal_name raw child status was not termination status" >&2
            exit 1
            ;;
    esac
    if [ "$(cat "$signal_reason_file")" != signal ]; then
        echo "FAIL: $signal_name termination reason was not recorded" >&2
        exit 1
    fi
done

echo "PASS: run-until-log-marker lifecycle"
