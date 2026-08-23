#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Compatibility entrypoint. The xtask command owns persistent RT-Thread image
# selection and keeps the runner in the foreground process group.
if [[ $# -eq 0 ]]; then
    set -- --quick --allow-qemu-timer-limit
else
    have_timer_limit=0
    for argument in "$@"; do
        case "$argument" in
            --allow-qemu-timer-limit) have_timer_limit=1 ;;
        esac
    done
    if [[ ${have_timer_limit:-0} -eq 0 ]]; then
        set -- "$@" --allow-qemu-timer-limit
    fi
fi
set -- cargo xtask axvisor task123 "$@"
cd "$SCRIPT_DIR"
exec "$@"
