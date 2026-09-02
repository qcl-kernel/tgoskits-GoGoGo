#!/usr/bin/env bash

set -euo pipefail

monotonic_ns() {
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
        'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
}

write_start() {
    local state=$1
    local state_tmp="${state}.tmp.$$"
    local start_monotonic_ns start_epoch_ns

    start_monotonic_ns="$(monotonic_ns)"
    start_epoch_ns="$(date +%s%N)"
    printf '%s %s\n' "$start_monotonic_ns" "$start_epoch_ns" > "$state_tmp"
    mv -- "$state_tmp" "$state"
}

write_finish() {
    local state=$1
    local output=$2
    local mode=$3
    local requested_unit=$4
    local requested_value=$5
    local start_monotonic_ns start_epoch_ns extra
    local end_monotonic_ns end_epoch_ns elapsed_ns elapsed_ms output_tmp

    [[ "$mode" =~ ^[a-z0-9_-]+$ ]] || return 2
    [[ "$requested_unit" =~ ^[a-z0-9_-]+$ ]] || return 2
    [[ "$requested_value" =~ ^[0-9]+$ ]] || return 2
    [[ -f "$state" ]] || return 2
    read -r start_monotonic_ns start_epoch_ns extra < "$state"
    [[ -z "${extra:-}" ]] || return 2
    [[ "$start_monotonic_ns" =~ ^[0-9]+$ ]] || return 2
    [[ "$start_epoch_ns" =~ ^[0-9]+$ ]] || return 2

    end_monotonic_ns="$(monotonic_ns)"
    end_epoch_ns="$(date +%s%N)"
    (( end_monotonic_ns >= start_monotonic_ns )) || return 2
    elapsed_ns=$((end_monotonic_ns - start_monotonic_ns))
    elapsed_ms="$(awk -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", ns / 1000000 }')"
    output_tmp="${output}.tmp.$$"
    printf '%s\n' \
        "RTBENCH_HOST_TIMING mode=$mode requested_unit=$requested_unit requested_value=$requested_value start_monotonic_ns=$start_monotonic_ns end_monotonic_ns=$end_monotonic_ns start_epoch_ns=$start_epoch_ns end_epoch_ns=$end_epoch_ns elapsed_ns=$elapsed_ns elapsed_ms=$elapsed_ms" \
        > "$output_tmp"
    mv -- "$output_tmp" "$output"
}

case "${1:-}" in
    start)
        [[ $# -eq 2 ]] || {
            echo "usage: $0 start STATE" >&2
            exit 2
        }
        write_start "$2"
        ;;
    finish)
        [[ $# -eq 6 ]] || {
            echo "usage: $0 finish STATE OUTPUT MODE REQUESTED_UNIT REQUESTED_VALUE" >&2
            exit 2
        }
        write_finish "$2" "$3" "$4" "$5" "$6"
        ;;
    *)
        echo "usage: $0 {start STATE|finish STATE OUTPUT MODE REQUESTED_UNIT REQUESTED_VALUE}" >&2
        exit 2
        ;;
esac
