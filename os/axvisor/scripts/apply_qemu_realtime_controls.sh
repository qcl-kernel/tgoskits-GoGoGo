#!/bin/bash

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 QEMU_PID UCLAMP_MIN" >&2
    exit 2
fi

qemu_pid=$1
uclamp_min=$2

case "$qemu_pid" in
    ''|*[!0-9]*|0)
        echo "invalid QEMU PID: $qemu_pid" >&2
        exit 2
        ;;
esac
case "$uclamp_min" in
    ''|*[!0-9]*)
        echo "QEMU uclamp.min must be an integer from 0 to 1024" >&2
        exit 2
        ;;
esac
if [ "$uclamp_min" -gt 1024 ]; then
    echo "QEMU uclamp.min must be an integer from 0 to 1024" >&2
    exit 2
fi
if ! command -v uclampset >/dev/null 2>&1; then
    echo "QEMU realtime runs require uclampset" >&2
    exit 1
fi

uclampset -m "$uclamp_min" -a -p "$qemu_pid"
echo "QEMU realtime control applied: pid=$qemu_pid uclamp.min=$uclamp_min"
