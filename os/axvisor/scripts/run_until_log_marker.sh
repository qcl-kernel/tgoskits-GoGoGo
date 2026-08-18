#!/bin/bash

if [ "${RUN_UNTIL_SIGNALS_RESET:-0}" != 1 ]; then
    export RUN_UNTIL_SIGNALS_RESET=1
    exec env --default-signal=HUP,INT,TERM bash "$0" "$@"
fi

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

child_pid=
child_pgid=
child_rc=

child_is_running() {
    local state

    [ -n "$child_pid" ] && [ -r "/proc/$child_pid/stat" ] || return 1
    state=$(awk '{ print $3 }' "/proc/$child_pid/stat" 2>/dev/null) || return 1
    [ "$state" != Z ]
}

child_group_is_running() {
    [ -n "$child_pgid" ] && kill -0 -- "-$child_pgid" 2>/dev/null
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

cleanup() {
    terminate_child_group
}

handle_signal() {
    local signal_rc=$1

    trap - EXIT HUP INT TERM
    terminate_child_group
    exit "$signal_rc"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

setsid -- "$@" &
child_pid=$!
child_pgid=$child_pid
if [ -n "${RUN_UNTIL_CHILD_PID_FILE:-}" ]; then
    printf '%s\n' "$child_pid" > "$RUN_UNTIL_CHILD_PID_FILE"
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
        exit "$child_rc"
    fi

    if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
        terminate_child_group
        exit 124
    fi

    sleep 0.1
done
