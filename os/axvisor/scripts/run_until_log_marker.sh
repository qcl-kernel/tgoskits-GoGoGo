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
    set +e
    wait "$child_pid" 2>/dev/null
    child_rc=$?
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
    fi
    reap_child
    child_pgid=
}

handle_exit() {
    local exit_rc=$?

    trap - EXIT HUP INT TERM
    set +e
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
    echo "usage: $0 TIMEOUT_S LOG MARKER [MARKER ...] -- COMMAND [ARG ...]" >&2
    exit 2
fi

timeout_s=$1
log=$2
shift 2
markers=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    markers+=("$1")
    shift
done
if [ "${#markers[@]}" -eq 0 ] || [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
    echo "usage: $0 TIMEOUT_S LOG MARKER [MARKER ...] -- COMMAND [ARG ...]" >&2
    exit 2
fi
shift

case "$timeout_s" in
    ''|*[!0-9]*|0)
        echo "invalid timeout: $timeout_s" >&2
        exit 2
        ;;
esac

if [ -n "${RUN_UNTIL_PRE_CHILD_READY_FILE:-}" ]; then
    atomic_write_completion "$RUN_UNTIL_PRE_CHILD_READY_FILE" ready
fi

if { [ -n "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ] &&
     [ -z "${RUN_UNTIL_LAUNCH_RELEASE_FILE:-}" ]; } ||
   { [ -z "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ] &&
     [ -n "${RUN_UNTIL_LAUNCH_RELEASE_FILE:-}" ]; }; then
    echo 'launch ready and release files must be configured together' >&2
    exit 2
fi

launch_in_progress=1
setsid -- "$@" <&0 &
child_pid=$!
child_pgid=$child_pid
if [ -n "${RUN_UNTIL_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$child_pid" > "$RUN_UNTIL_CHILD_PID_FILE"
fi
if [ -n "${RUN_UNTIL_LAUNCH_READY_FILE:-}" ]; then
    atomic_write_completion "$RUN_UNTIL_LAUNCH_READY_FILE" ready
    while [ ! -e "$RUN_UNTIL_LAUNCH_RELEASE_FILE" ]; do
        sleep 0.01
    done
fi
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
launch_in_progress=0
if [ -n "$pending_signal_rc" ]; then
    deferred_signal_rc=$pending_signal_rc
    pending_signal_rc=
    handle_signal "$deferred_signal_rc"
fi
deadline_ns=$(( $(date +%s%N) + timeout_s * 1000000000 ))

while :; do
    all_markers_present=1
    if [ ! -f "$log" ]; then
        all_markers_present=0
    else
        for marker in "${markers[@]}"; do
            if ! grep -aFq -- "$marker" "$log"; then
                all_markers_present=0
                break
            fi
        done
    fi
    if [ "$all_markers_present" -eq 1 ]; then
        terminated_by_helper=0
        if child_is_running; then
            terminated_by_helper=1
        fi
        terminate_child_group
        record_completion marker-complete "$child_rc" || true
        if [ "$child_rc" -eq 0 ] || \
           { [ "$terminated_by_helper" -eq 1 ] && \
             { [ "$child_rc" -eq 143 ] || [ "$child_rc" -eq 137 ]; }; }; then
            exit 0
        fi
        exit "$child_rc"
    fi

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
