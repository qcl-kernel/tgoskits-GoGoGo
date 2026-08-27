#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: $0 LOG MARKER TIMEOUT_SECONDS [PID]" >&2
    exit 2
fi
log_file=$1
marker=$2
timeout=$3
owned_pid=
if [ "$#" -eq 4 ]; then
    owned_pid=$4
fi
deadline=$(($(date +%s) + timeout))

while [ "$(date +%s)" -le "$deadline" ]; do
    if [ -f "$log_file" ] && grep -F "$marker" "$log_file" >/dev/null 2>&1; then
        exit 0
    fi
    if [ -n "$owned_pid" ] && ! kill -0 "$owned_pid" 2>/dev/null; then
        echo "process $owned_pid exited while waiting for $marker" >&2
        exit 1
    fi
    sleep 0.1
done
echo "timeout waiting for $marker in $log_file" >&2
exit 1
