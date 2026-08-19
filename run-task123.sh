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

canonical_existing_file() {
    local label=$1
    local candidate=$2
    local resolved

    [[ -n "$candidate" ]] || fail "$label path is empty"
    resolved="$(realpath -e -- "$candidate")" ||
        fail "$label does not exist: $candidate"
    [[ -f "$resolved" && -r "$resolved" && -s "$resolved" ]] ||
        fail "$label must be a readable, non-empty file: $resolved"
    printf '%s\n' "$resolved"
}

resolve_local_rootfs() {
    local candidate
    local -a candidates=(
        "$ROOT/tmp/task123-native-inputs/rootfs.img"
        "$ROOT/tmp/vmconfigs/two-guest-net/current/rootfs.img"
        "$ROOT/tmp/rootfs-task12.img"
        "$ROOT/tmp/rootfs.img"
    )

    if [[ -n "${ROOTFS_IMAGE:-}" ]]; then
        ROOTFS_IMAGE="$(canonical_existing_file rootfs "$ROOTFS_IMAGE")"
        return 0
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            ROOTFS_IMAGE="$(canonical_existing_file rootfs "$candidate")"
            return 0
        fi
    done
    fail "no local readable non-empty rootfs.img found; prepare a local rootfs.img and set ROOTFS_IMAGE or place it under tmp/"
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
    local candidate

    if [[ "$output_set" -eq 1 ]]; then
        OUTPUT="$(canonical_candidate output "$output_candidate")"
    else
        output_parent="$ROOT/tmp/task123-runs"
        mkdir -p -- "$output_parent"
        [[ -d "$output_parent" && -w "$output_parent" ]] ||
            fail "output parent is missing or unwritable: $output_parent"
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
        candidate="$output_parent/$mode-$timestamp"
        suffix=1
        while ! mkdir -- "$candidate" 2>/dev/null; do
            candidate="$output_parent/$mode-$timestamp-$suffix"
            suffix=$((suffix + 1))
        done
        OUTPUT="$(canonical_candidate output "$candidate")"
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
    else
        mkdir -- "$OUTPUT" || {
            [[ -d "$OUTPUT" && ! -L "$OUTPUT" && -w "$OUTPUT" ]] ||
                fail "output could not be reserved as a writable directory: $OUTPUT"
            [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
                fail "output directory must be empty: $OUTPUT"
        }
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
pipeline_status_file=
pipeline_pid=
interrupted=0
interrupt_status=0
pending_signal=
run_log_saved=0

save_run_log() {
    local resolved_output

    [[ "$run_log_saved" -eq 0 ]] || return 0
    [[ -n "${temporary_log:-}" && -f "$temporary_log" ]] || return 1
    [[ -n "${OUTPUT:-}" ]] || return 1
    if [[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]]; then
        mkdir -- "$OUTPUT" || return 1
    fi
    [[ -d "$OUTPUT" && ! -L "$OUTPUT" && -w "$OUTPUT" ]] || return 1
    resolved_output="$(realpath -e -- "$OUTPUT")" || return 1
    [[ "$resolved_output" == "$OUTPUT" ]] || return 1
    cp -- "$temporary_log" "$OUTPUT/run.log" || return 1
    run_log_saved=1
}

cleanup() {
    set +e
    if [[ -n "${pipeline_pid:-}" ]] &&
        kill -0 -- "-$pipeline_pid" 2>/dev/null; then
        kill -KILL -- "-$pipeline_pid" 2>/dev/null || true
    fi
    if [[ -n "${pipeline_pid:-}" ]]; then
        while kill -0 "$pipeline_pid" 2>/dev/null; do
            wait "$pipeline_pid" 2>/dev/null || true
        done
        local cleanup_attempts=0
        while kill -0 -- "-$pipeline_pid" 2>/dev/null &&
            [[ "$cleanup_attempts" -lt 100 ]]; do
            if ! sleep 0.05; then
                :
            fi
            cleanup_attempts=$((cleanup_attempts + 1))
        done
    fi
    if [[ -n "${temporary_log:-}" ]]; then
        save_run_log || true
        rm -f -- "$temporary_log"
    fi
    if [[ -n "${pipeline_status_file:-}" ]]; then
        rm -f -- "$pipeline_status_file"
    fi
}
trap cleanup EXIT

forward_signal() {
    local signal=$1

    interrupted=1
    pending_signal=$signal
    case "$signal" in
        HUP) interrupt_status=129 ;;
        INT) interrupt_status=130 ;;
        TERM) interrupt_status=143 ;;
    esac
    if [[ -n "${pipeline_pid:-}" ]]; then
        kill -s "$signal" -- "-$pipeline_pid" 2>/dev/null || true
    fi
}
trap 'forward_signal HUP' HUP
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

wait_for_pipeline() {
    local wait_status=0
    local group_attempts=0

    while :; do
        set +e
        wait "$pipeline_pid"
        wait_status=$?
        set -e
        if [[ "$wait_status" -gt 128 && "$interrupted" -eq 1 ]] &&
            kill -0 "$pipeline_pid" 2>/dev/null; then
            continue
        fi
        break
    done

    while kill -0 -- "-$pipeline_pid" 2>/dev/null; do
        if [[ "$group_attempts" -ge 100 ]]; then
            kill -KILL -- "-$pipeline_pid" 2>/dev/null || true
            group_attempts=0
        fi
        if ! sleep 0.05; then
            :
        fi
        group_attempts=$((group_attempts + 1))
    done

    WAIT_STATUS=$wait_status
}

read_pipeline_status() {
    local -n result=$1
    local -a captured_status=()

    result=()
    if [[ -f "$pipeline_status_file" ]] &&
        mapfile -t captured_status < "$pipeline_status_file" &&
        [[ "${#captured_status[@]}" -ge 2 ]] &&
        [[ "${captured_status[0]}" =~ ^[0-9]+$ ]] &&
        [[ "${captured_status[1]}" =~ ^[0-9]+$ ]]; then
        result=("${captured_status[0]}" "${captured_status[1]}")
    fi
}

main() {
    parse_arguments "$@"
    if [[ "$help_requested" -eq 1 ]]; then
        usage
        return 0
    fi

    QEMU="$(resolve_executable qemu-system-aarch64 qemu-system-aarch64)"
    GIT="$(resolve_executable git git)"
    RUNNER="$(resolve_runner)"
    if [[ "$RUNNER" == "$(realpath -e -- "$DEFAULT_RUNNER")" ]]; then
        resolve_local_rootfs
    fi
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
    pipeline_status_file="$(mktemp "$(dirname -- "$OUTPUT")/.task123-status.${mode}.XXXXXX")"
    set +e
    {
        printf 'UTC_TIMESTAMP %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        "$GIT" --version
        "$QEMU" --version
        printf 'QEMU %s\n' "$QEMU"
        if [[ -n "${ROOTFS_IMAGE:-}" ]]; then
            printf 'ROOTFS_IMAGE %s\n' "$ROOTFS_IMAGE"
        fi
        printf 'MODE %s\n' "$mode"
        printf 'RUNNER %s\n' "$RUNNER"
        printf 'OUTPUT %s\n' "$OUTPUT"
        quote_command "$RUNNER" "${runner_args[@]}"
    } | tee "$temporary_log"
    header_status=("${PIPESTATUS[@]}")
    set -e

    if [[ "${header_status[1]}" -ne 0 ]]; then
        pipeline_result=1
        save_run_log || true
        return "$pipeline_result"
    fi

    pipeline_environment=(
        "QEMU=$QEMU"
        "TASK123_PIPELINE_LOG=$temporary_log"
        "TASK123_PIPELINE_STATUS=$pipeline_status_file"
    )
    if [[ -n "${ROOTFS_IMAGE:-}" ]]; then
        pipeline_environment+=("ROOTFS_IMAGE=$ROOTFS_IMAGE")
    fi
    env "${pipeline_environment[@]}" setsid --wait bash -c '
            set +e
            "$@" 2>&1 | tee -a "$TASK123_PIPELINE_LOG"
            pipeline_status=("${PIPESTATUS[@]}")
            status_write_status=0
            if ! printf "%s\n%s\n" "${pipeline_status[0]}" "${pipeline_status[1]}" > \
                "$TASK123_PIPELINE_STATUS"; then
                status_write_status=1
            fi
            if [[ "${pipeline_status[0]}" -ne 0 ]]; then
                exit "${pipeline_status[0]}"
            fi
            if [[ "${pipeline_status[1]}" -ne 0 || "$status_write_status" -ne 0 ]]; then
                exit 1
            fi
            exit 0
        ' task123-pipeline "$RUNNER" "${runner_args[@]}" &
    pipeline_pid=$!
    if [[ "$interrupted" -eq 1 ]]; then
        forward_signal "$pending_signal"
    fi

    wait_for_pipeline
    wait_status=$WAIT_STATUS
    pipeline_status=()
    read_pipeline_status pipeline_status
    pipeline_log_status=0
    if [[ "${#pipeline_status[@]}" -eq 2 ]]; then
        if ! printf 'PIPESTATUS runner=%s tee=%s\n' \
            "${pipeline_status[0]}" "${pipeline_status[1]}" >> "$temporary_log"; then
            pipeline_log_status=1
        fi
    else
        if ! printf 'PIPESTATUS unavailable wait=%s signal=%s\n' \
            "$wait_status" "${pending_signal:-none}" >> "$temporary_log"; then
            pipeline_log_status=1
        fi
    fi

    if [[ "$interrupted" -eq 1 ]]; then
        pipeline_result=$interrupt_status
    elif [[ "${#pipeline_status[@]}" -eq 2 ]]; then
        runner_status=${pipeline_status[0]}
        tee_status=${pipeline_status[1]}
        pipeline_result=0
        if [[ "$runner_status" -ne 0 ]]; then
            pipeline_result=$runner_status
        elif [[ "$tee_status" -ne 0 || "$pipeline_log_status" -ne 0 ||
            "$wait_status" -ne 0 ]]; then
            pipeline_result=1
        fi
    else
        pipeline_result=$wait_status
        [[ "$pipeline_result" -ne 0 ]] || pipeline_result=1
    fi

    log_copy_status=0
    save_run_log || log_copy_status=1
    if [[ "$log_copy_status" -ne 0 && "$pipeline_result" -eq 0 ]]; then
        pipeline_result=1
    fi

    return "$pipeline_result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
