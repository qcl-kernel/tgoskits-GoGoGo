#!/bin/bash

if [ "${RUN_UNTIL_SIGNALS_RESET:-0}" != 1 ]; then
    export RUN_UNTIL_SIGNALS_RESET=1
    exec env --default-signal=HUP,INT,TERM bash "$0" "$@"
fi

child_pid=
child_pgid=
child_rc=
completion_recorded=0
launch_in_progress=0
pending_signal_rc=
helper_pid_published=0

atomic_write_completion() {
    local destination=$1
    local value=$2
    local temporary="${destination}.tmp.$$"

    printf '%s\n' "$value" > "$temporary" &&
        mv -- "$temporary" "$destination"
}

record_completion() {
    local reason=$1
    local raw_status=$2
    local publish_rc=0

    [ "$completion_recorded" -eq 0 ] || return 0
    completion_recorded=1
    case "$raw_status" in
        ''|*[!0-9]*) raw_status=1 ;;
        *)
            if [ "$raw_status" -gt 255 ]; then
                raw_status=1
            fi
            ;;
    esac
    [ -n "$reason" ] || reason=internal-error

    if [ -n "${RUN_UNTIL_CHILD_STATUS_FILE:-}" ]; then
        atomic_write_completion "$RUN_UNTIL_CHILD_STATUS_FILE" "$raw_status" ||
            publish_rc=$?
    fi
    if [ -n "${RUN_UNTIL_TERMINATION_REASON_FILE:-}" ]; then
        atomic_write_completion "$RUN_UNTIL_TERMINATION_REASON_FILE" "$reason" ||
            publish_rc=$?
    fi
    return "$publish_rc"
}

child_is_running() {
    local state

    [ -n "$child_pid" ] && [ -r "/proc/$child_pid/stat" ] || return 1
    state=$(awk '{ print $3 }' "/proc/$child_pid/stat" 2>/dev/null) || return 1
    [ "$state" != Z ]
}

child_group_is_running() {
    [ -n "$child_pgid" ] && kill -0 -- "-$child_pgid" 2>/dev/null
}

wait_for_child_group() {
    local deadline_ns=$(( $(date +%s%N) + 5000000000 ))

    while child_is_running; do
        child_group_is_running && return 0
        [ "$(date +%s%N)" -lt "$deadline_ns" ] || return 1
        sleep 0.01
    done
    return 0
}

reap_child() {
    if [ -z "$child_pid" ]; then
        return
    fi
    child_pid_for_wait=$child_pid
    child_pid=
    set +e
    if wait "$child_pid_for_wait" 2>/dev/null; then
        child_rc=0
    else
        child_rc=$?
    fi
    set -e
    child_pid=
}

terminate_unowned_child() {
    local deadline_ns

    [ -n "$child_pid" ] || return
    if child_is_running; then
        kill -TERM "$child_pid" 2>/dev/null || true
        deadline_ns=$(( $(date +%s%N) + 1000000000 ))
        while child_is_running && [ "$(date +%s%N)" -lt "$deadline_ns" ]; do
            sleep 0.01
        done
    fi
    if child_is_running; then
        kill -KILL "$child_pid" 2>/dev/null || true
    fi
    reap_child
}

terminate_child_group() {
    local deadline_ns
    local force_deadline_ns

    if [ -z "$child_pgid" ]; then
        return
    fi

    if child_group_is_running; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
        deadline_ns=$(( $(date +%s%N) + 1000000000 ))
        while child_group_is_running && [ "$(date +%s%N)" -lt "$deadline_ns" ]; do
            if [ -n "$child_pid" ] && ! child_is_running; then
                reap_child
            fi
            sleep 0.01
        done
    fi

    if child_group_is_running; then
        kill -KILL -- "-$child_pgid" 2>/dev/null || true
        force_deadline_ns=$(( $(date +%s%N) + 1000000000 ))
        while child_group_is_running &&
              [ "$(date +%s%N)" -lt "$force_deadline_ns" ]; do
            sleep 0.01
        done
        if child_group_is_running; then
            echo "child process group $child_pgid ignored SIGKILL" >&2
            return 1
        fi
    fi
    reap_child
    child_pgid=
}

stop_child_for_completion() {
    terminate_child_group
}

handle_exit() {
    local exit_rc=$?

    trap - EXIT HUP INT TERM
    set +e
    if [ "$helper_pid_published" -eq 1 ] && [ -n "${RUN_UNTIL_HELPER_PID_FILE:-}" ]; then
        rm -f -- "$RUN_UNTIL_HELPER_PID_FILE"
    fi
    terminate_child_group
    if [ "$completion_recorded" -eq 0 ]; then
        record_completion internal-error "$exit_rc"
    fi
    exit "$exit_rc"
}

handle_signal() {
    local signal_rc=$1
    local raw_status

    if [ "$launch_in_progress" -eq 1 ]; then
        [ -n "$pending_signal_rc" ] || pending_signal_rc=$signal_rc
        return
    fi
    trap - HUP INT TERM
    terminate_child_group
    raw_status=${child_rc:-$signal_rc}
    record_completion signal "$raw_status" || true
    exit "$signal_rc"
}

trap handle_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

set -eu

if [ "$#" -lt 5 ]; then
    echo "usage: $0 TIMEOUT_S LOG MARKER [MARKER ...] [--failure-marker MARKER ...] -- COMMAND [ARG ...]" >&2
    exit 2
fi

timeout_s=$1
log=$2
shift 2
markers=()
failure_markers=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ] &&
      [ "$1" != "--failure-marker" ]; do
    markers+=("$1")
    shift
done
while [ "$#" -gt 0 ] && [ "$1" = "--failure-marker" ]; do
    shift
    if [ "$#" -eq 0 ] || [ "$1" = "--" ]; then
        echo 'missing value for --failure-marker' >&2
        exit 2
    fi
    failure_markers+=("$1")
    shift
done
if [ "${#markers[@]}" -eq 0 ] || [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
    echo "usage: $0 TIMEOUT_S LOG MARKER [MARKER ...] [--failure-marker MARKER ...] -- COMMAND [ARG ...]" >&2
    exit 2
fi
shift

case "$timeout_s" in
    ''|*[!0-9]*|0)
        echo "invalid timeout: $timeout_s" >&2
        exit 2
        ;;
esac

completion_grace_ms=${RUN_UNTIL_COMPLETION_GRACE_MS:-250}
case "$completion_grace_ms" in
    ''|*[!0-9]*)
        echo "invalid completion grace: $completion_grace_ms" >&2
        exit 2
        ;;
esac

sleep_milliseconds() {
    local milliseconds=$1
    printf -v seconds '%d.%03d' "$((milliseconds / 1000))" "$((milliseconds % 1000))"
    sleep "$seconds"
}

if [ -n "${RUN_UNTIL_PRE_CHILD_READY_FILE:-}" ]; then
    atomic_write_completion "$RUN_UNTIL_PRE_CHILD_READY_FILE" ready
fi
if [ -n "${RUN_UNTIL_HELPER_PID_FILE:-}" ]; then
    atomic_write_completion "$RUN_UNTIL_HELPER_PID_FILE" "$$"
    helper_pid_published=1
fi
if { [ -n "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ] &&
     [ -z "${RUN_UNTIL_LAUNCH_RELEASE_FILE:-}" ]; } ||
   { [ -z "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ] &&
     [ -n "${RUN_UNTIL_LAUNCH_RELEASE_FILE:-}" ]; }; then
    echo 'launch ready and release files must be configured together' >&2
    exit 2
fi

launch_in_progress=1
if [ -n "${RUN_UNTIL_CHILD_TIMERSLACK_NS:-}" ]; then
    setsid -- bash -c '
        timerslack_ns=$1
        shift
        printf "%s\n" "$timerslack_ns" > /proc/self/timerslack_ns || exit 1
        exec "$@"
    ' run-until-child "$RUN_UNTIL_CHILD_TIMERSLACK_NS" "$@" <&0 &
else
    setsid -- "$@" <&0 &
fi
child_pid=$!
child_pgid=$child_pid
child_pid_for_wait=$child_pid
if [ -n "${RUN_UNTIL_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$child_pid" > "$RUN_UNTIL_CHILD_PID_FILE"
fi
if [ -n "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ]; then
    atomic_write_completion "$RUN_UNTIL_LAUNCH_READY_FILE" ready
    # Do not wait forever if the child exits before the parent releases it.
    # The parent's error path can then terminate this helper promptly.
    while [ ! -e "$RUN_UNTIL_LAUNCH_RELEASE_FILE" ] && child_is_running; do
        sleep 0.01
    done
fi

normalized_marker_present() {
    local marker=$1

    # AxVisor host records and guest UART bytes share one stream. A host
    # record can therefore be inserted between bytes of a guest marker.
    # Remove only the colored host presentation records, then strip the
    # remaining ANSI control sequences so the guest bytes become contiguous.
    python3 - "$log" "$marker" <<'PY'
import re
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
data = re.sub(
    rb"(?:\[VM [0-9]+\] )?\x1b\[37m\[[^\r\n]*?\x1b\[m\r?\n?",
    b"",
    data,
)
data = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)
marker = sys.argv[2].encode()
if marker == b"TASK3_RTOS_FINAL_COMPLETE":
    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    found = re.search(
        rb"TASK3_RTOS_FINAL requests=[0-9]+ errors=[0-9]+ duplicates=[0-9]+ "
        rb"applied_steps=[0-9]+ retries=[0-9]+\n",
        data,
    )
elif marker == b"RTBENCH_STABILITY_END status=":
    found = re.search(
        rb"RTBENCH_STABILITY_END status=(PASS|FAIL) expected=[0-9]+ "
        rb"collected=[0-9]+ missing=0(?:\s|$)",
        data,
    )
else:
    found = marker in data
sys.exit(0 if found else 1)
PY
}

marker_present() {
    local marker=$1

    if [ "$marker" = 'TASK3_RTOS_FINAL_COMPLETE' ]; then
        normalized_marker_present "$marker"
    elif [ "$marker" = 'RTBENCH_STABILITY_END status=' ]; then
        grep -aEq -- \
            'RTBENCH_STABILITY_END status=(PASS|FAIL) expected=[0-9]+ collected=[0-9]+ missing=0([[:space:]]|$)' \
            "$log" && return 0
    else
        grep -aFq -- "$marker" "$log" && return 0
    fi
    normalized_marker_present "$marker"
}

launch_in_progress=0
if ! wait_for_child_group; then
    terminate_unowned_child
    launch_in_progress=0
    if [ -n "$pending_signal_rc" ]; then
        deferred_signal_rc=$pending_signal_rc
        pending_signal_rc=
        handle_signal "$deferred_signal_rc"
    fi
    echo 'child did not establish its process group' >&2
    exit 1
fi
set -e
launch_in_progress=0
if [ -n "$pending_signal_rc" ]; then
    deferred_signal_rc=$pending_signal_rc
    pending_signal_rc=
    handle_signal "$deferred_signal_rc"
fi
deadline_ns=$(( $(date +%s%N) + timeout_s * 1000000000 ))
set -e

while :; do
    all_markers_present=1
    if [ ! -f "$log" ]; then
        all_markers_present=0
    else
        for failure_marker in "${failure_markers[@]}"; do
            if marker_present "$failure_marker"; then
                terminate_child_group
                failure_status=${child_rc:-1}
                if [ "$failure_status" -eq 0 ]; then
                    failure_status=1
                fi
                record_completion failure-marker "$failure_status" || true
                exit 1
            fi
        done
        for marker in "${markers[@]}"; do
            if ! marker_present "$marker"; then
                all_markers_present=0
                break
            fi
        done
    fi
    if [ "$all_markers_present" -eq 1 ]; then
        # Guest UART writes and AxVisor host records share one pipe. A marker
        # can become visible before the remainder of the same report write is
        # drained by tee; keep the child alive briefly so the evidence after
        # the marker reaches the log before controlled termination.
        if child_is_running && [ "$completion_grace_ms" -gt 0 ]; then
            sleep_milliseconds "$completion_grace_ms"
        fi
        terminated_by_helper=0
        if child_is_running; then
            terminated_by_helper=1
        fi
        stop_child_for_completion
        record_completion marker-complete "$child_rc" || true
        if [ "$child_rc" -eq 0 ] || \
           { [ "$terminated_by_helper" -eq 1 ] && \
             { [ "$child_rc" -eq 143 ] || [ "$child_rc" -eq 137 ]; }; }; then
            exit 0
        fi
        exit "$child_rc"
    fi

    # Bash's wait(2) does not wake for ordinary output pipelines; poll the
    # marker and timeout state while QEMU remains alive.
    sleep 0.1

    if ! child_is_running; then
        reap_child
        exited_child_rc=$child_rc
        terminate_child_group
        child_rc=$exited_child_rc
        record_completion child-exit "$child_rc" || true
        exit "$child_rc"
    fi

    if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
        terminate_child_group
        record_completion timeout "$child_rc" || true
        exit 124
    fi

    sleep 0.1
done
