#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(realpath -e -- "$SCRIPT_DIR")"
DEFAULT_RUNNER="$ROOT/os/axvisor/scripts/run_task123_guest_comparison.sh"

mode=quick
mode_set=0
output_candidate=
output_set=0
cache_candidate=
cache_set=0
allow_qemu_timer_limit=0
help_requested=0

usage() {
    cat <<EOF
Usage: $(basename -- "${BASH_SOURCE[0]}") [OPTIONS]

Options:
  --quick                    Run the short comparison (default)
  --long                     Run the 3600-second comparison
  --output DIR               Write results to DIR
  --cache DIR                Use DIR as the artifact cache
  --allow-qemu-timer-limit   Allow the QEMU timer limit gate
  --help                     Show this help
EOF
}

fail() {
    printf 'task123 runner: %s\n' "$*" >&2
    exit 2
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)
                [[ "$mode_set" -eq 0 ]] || fail 'duplicate mode option'
                mode=quick
                mode_set=1
                shift
                ;;
            --long)
                [[ "$mode_set" -eq 0 ]] || fail 'duplicate mode option'
                mode=long
                mode_set=1
                shift
                ;;
            --output)
                [[ "$output_set" -eq 0 ]] || fail 'duplicate --output option'
                [[ $# -ge 2 && "$2" != --* ]] || fail '--output requires a directory'
                output_candidate=$2
                output_set=1
                shift 2
                ;;
            --cache)
                [[ "$cache_set" -eq 0 ]] || fail 'duplicate --cache option'
                [[ $# -ge 2 && "$2" != --* ]] || fail '--cache requires a directory'
                cache_candidate=$2
                cache_set=1
                shift 2
                ;;
            --allow-qemu-timer-limit)
                [[ "$allow_qemu_timer_limit" -eq 0 ]] ||
                    fail 'duplicate --allow-qemu-timer-limit option'
                allow_qemu_timer_limit=1
                shift
                ;;
            --help)
                [[ "$help_requested" -eq 0 && $# -eq 1 ]] ||
                    fail '--help must be used by itself'
                help_requested=1
                shift
                ;;
            *)
                fail "unknown option: $1"
                ;;
        esac
    done
}

resolve_executable() {
    local label=$1
    local name=$2
    local candidate
    local resolved

    candidate="$(type -P "$name" 2>/dev/null)" ||
        fail "$label was not found in PATH: $name"
    resolved="$(realpath -e -- "$candidate")" ||
        fail "$label could not be resolved: $candidate"
    [[ -f "$resolved" && -x "$resolved" ]] ||
        fail "$label is not an executable file: $resolved"
    printf '%s\n' "$resolved"
}

resolve_runner() {
    local candidate=${TASK123_COMPARISON_RUNNER:-$DEFAULT_RUNNER}
    local resolved

    [[ -n "$candidate" ]] || fail 'comparison runner path is empty'
    resolved="$(realpath -e -- "$candidate")" ||
        fail "comparison runner could not be resolved: $candidate"
    [[ -f "$resolved" && -x "$resolved" ]] ||
        fail "comparison runner is not executable: $resolved"
    printf '%s\n' "$resolved"
}

path_is_within() {
    local child=$1
    local parent=$2
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

canonical_candidate() {
    local label=$1
    local candidate=$2
    local resolved

    [[ -n "$candidate" ]] || fail "$label path is empty"
    resolved="$(realpath -m -- "$candidate")" ||
        fail "$label path could not be resolved: $candidate"
    [[ "$resolved" != / && "$resolved" != "$ROOT" ]] ||
        fail "unsafe $label directory: $resolved"
    printf '%s\n' "$resolved"
}

prepare_output() {
    local output_parent
    local timestamp
    local suffix

    if [[ "$output_set" -eq 1 ]]; then
        OUTPUT="$(canonical_candidate output "$output_candidate")"
    else
        output_parent="$ROOT/tmp/task123-runs"
        mkdir -p -- "$output_parent"
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
        OUTPUT="$output_parent/$mode-$timestamp"
        suffix=1
        while [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; do
            OUTPUT="$output_parent/$mode-$timestamp-$suffix"
            suffix=$((suffix + 1))
        done
        OUTPUT="$(canonical_candidate output "$OUTPUT")"
    fi

    output_parent="$(dirname -- "$OUTPUT")"
    mkdir -p -- "$output_parent"
    [[ -d "$output_parent" && -w "$output_parent" ]] ||
        fail "output parent is missing or unwritable: $output_parent"

    if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
        [[ -d "$OUTPUT" && ! -L "$OUTPUT" && -w "$OUTPUT" ]] ||
            fail "output is not a writable directory: $OUTPUT"
        [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
            fail "output directory must be empty: $OUTPUT"
    fi

    if [[ "$cache_set" -eq 1 ]]; then
        CACHE="$(canonical_candidate cache "$cache_candidate")"
        local cache_parent
        cache_parent="$(dirname -- "$CACHE")"
        mkdir -p -- "$cache_parent"
        [[ -d "$cache_parent" && -w "$cache_parent" ]] ||
            fail "cache parent is missing or unwritable: $cache_parent"
        if [[ -e "$CACHE" || -L "$CACHE" ]]; then
            [[ -d "$CACHE" && ! -L "$CACHE" && -w "$CACHE" ]] ||
                fail "cache is not a writable directory: $CACHE"
        else
            mkdir -- "$CACHE"
        fi
        CACHE="$(realpath -e -- "$CACHE")"
    fi

    if [[ "$cache_set" -eq 1 ]] &&
        { path_is_within "$OUTPUT" "$CACHE" || path_is_within "$CACHE" "$OUTPUT"; }; then
        fail "output and cache directories must be separate"
    fi
}

quote_command() {
    local argument

    printf 'COMMAND'
    for argument in "$@"; do
        printf ' %q' "$argument"
    done
    printf '\n'
}

temporary_log=
cleanup() {
    if [[ -n "${temporary_log:-}" ]]; then
        rm -f -- "$temporary_log"
    fi
}
trap cleanup EXIT

main() {
    parse_arguments "$@"
    if [[ "$help_requested" -eq 1 ]]; then
        usage
        return 0
    fi

    QEMU="$(resolve_executable qemu-system-aarch64 qemu-system-aarch64)"
    GIT="$(resolve_executable git git)"
    RUNNER="$(resolve_runner)"
    prepare_output

    runner_args=("--$mode")
    if [[ "$mode" == long ]]; then
        runner_args=(--full)
    fi
    runner_args+=(--output "$OUTPUT")
    if [[ "$cache_set" -eq 1 ]]; then
        runner_args+=(--cache "$CACHE")
    fi
    if [[ "$allow_qemu_timer_limit" -eq 1 ]]; then
        runner_args+=(--allow-qemu-timer-limit)
    fi

    temporary_log="$(mktemp "$(dirname -- "$OUTPUT")/.task123-run.${mode}.XXXXXX")"
    {
        printf 'MODE %s\n' "$mode"
        printf 'RUNNER %s\n' "$RUNNER"
        printf 'OUTPUT %s\n' "$OUTPUT"
        quote_command "$RUNNER" "${runner_args[@]}"
    } | tee "$temporary_log"

    set +e
    "$RUNNER" "${runner_args[@]}" 2>&1 | tee -a "$temporary_log"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    runner_status=${pipeline_status[0]}

    if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
        [[ -d "$OUTPUT" && ! -L "$OUTPUT" && -w "$OUTPUT" ]] ||
            fail "runner created an invalid output path: $OUTPUT"
    else
        mkdir -- "$OUTPUT"
    fi
    [[ "$(realpath -e -- "$OUTPUT")" == "$OUTPUT" ]] ||
        fail "runner output path changed unexpectedly: $OUTPUT"
    cp -- "$temporary_log" "$OUTPUT/run.log"

    return "$runner_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
