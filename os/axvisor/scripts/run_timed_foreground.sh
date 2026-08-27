#!/usr/bin/env bash

set -Eeuo pipefail

[[ "$#" -gt 0 ]] || exit 2

# Run the command in its own session so timeout can keep the caller's terminal
# in the foreground while this wrapper still owns the complete child process
# group for bounded cleanup.
setsid "$@" &
child_pid=$!

terminate_children() {
    trap - TERM INT HUP
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    exit 143
}

trap terminate_children TERM INT HUP
wait "$child_pid"
exit $?
