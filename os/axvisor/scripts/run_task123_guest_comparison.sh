#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
RUNNER="${TASK123_COMPARISON_RUNNER:-$SCRIPT_DIR/run_task123.sh}"
ANALYZER="${TASK123_COMPARISON_ANALYZER:-$SCRIPT_DIR/compare_task123_guests.py}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$ROOT/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img}"

mode=quick
mode_set=0
rtos=rtthread
app_guest=
matrix=0
output_candidate=""
cache_candidate=""
allow_qemu_timer_limit=0
comparison_status=NOT_STARTED

usage() {
    cat >&2 <<EOF
usage:
  $0 [--quick|--full] [--rtos rtthread|zephyr]
       [--matrix all] [--cache DIR] [--output DIR] [--allow-qemu-timer-limit]

quick:  300-second stability run, 30000 Task2 requests per payload
full:   3600-second stability run, 240000 Task2 requests per payload
default: Linux/StarryOS comparison with RT-Thread
matrix:  run all four RTOS/app-guest combinations sequentially; --quick uses
         a short functional profile (1 second, 10 requests per payload)
EOF
    return 2
}

fail() {
    echo "task123 guest comparison: $*" >&2
    return 1
}

path_is_within() {
    local child=$1
    local parent=$2
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick|--full)
                [[ "$mode_set" -eq 0 ]] || usage
                mode=${1#--}
                mode_set=1
                shift
                ;;
            --rtos)
                [[ $# -ge 2 && "$rtos" == rtthread ]] || usage
                case "$2" in rtthread|zephyr) ;; *) usage ;; esac
                rtos=$2
                shift 2
                ;;
            --app-guest)
                [[ $# -ge 2 && -z "$app_guest" ]] || usage
                case "$2" in linux|starryos) ;; *) usage ;; esac
                app_guest=$2
                shift 2
                ;;
            --matrix)
                [[ $# -ge 2 && "$matrix" -eq 0 ]] || usage
                [[ "$2" == all ]] || usage
                [[ -z "$app_guest" ]] || usage
                matrix=1
                shift 2
                ;;
            --output)
                [[ $# -ge 2 && -z "$output_candidate" ]] || usage
                output_candidate=$2
                shift 2
                ;;
            --cache)
                [[ $# -ge 2 && -z "$cache_candidate" ]] || usage
                cache_candidate=$2
                shift 2
                ;;
            --allow-qemu-timer-limit)
                [[ "$allow_qemu_timer_limit" -eq 0 ]] || usage
                allow_qemu_timer_limit=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                usage
                ;;
        esac
    done
}

canonical_executable() {
    local label=$1
    local candidate=$2
    local resolved
    resolved="$(realpath -e -- "$candidate")" || {
        fail "$label does not exist: $candidate"
        return 1
    }
    [[ -f "$resolved" && -x "$resolved" ]] || {
        fail "$label is not executable: $resolved"
        return 1
    }
    printf '%s\n' "$resolved"
}

prepare_local_rootfs() {
    local source
    if [[ -s "$ROOTFS_IMAGE" ]]; then
        return 0
    fi

    local -a candidates=(
        "$ROOT/tmp/vmconfigs/two-guest-net/current/rootfs.img"
        "$ROOT/tmp/task123-native-inputs/rootfs.img"
        "$ROOT/tmp/rootfs-task12.img"
        "$ROOT/tmp/rootfs.img"
    )
    for source in "${candidates[@]}"; do
        if [[ -s "$source" ]]; then
            mkdir -p "$(dirname -- "$ROOTFS_IMAGE")"
            cp -- "$source" "$ROOTFS_IMAGE.tmp.$$"
            mv -- "$ROOTFS_IMAGE.tmp.$$" "$ROOTFS_IMAGE"
            return 0
        fi
    done

    ROOTFS_IMAGE=
}

prepare_output() {
    local parent
    if [[ -z "$output_candidate" ]]; then
        output_candidate="$ROOT/tmp/task123-guest-comparison-$mode-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    OUTPUT="$(realpath -m -- "$output_candidate")" || return 2
    [[ "$OUTPUT" != / && "$OUTPUT" != "$ROOT" ]] || {
        fail "unsafe output directory: $OUTPUT"
        return 2
    }
    parent="$(dirname -- "$OUTPUT")"
    [[ -d "$parent" && -w "$parent" ]] || {
        fail "output parent is missing or unwritable: $parent"
        return 2
    }
    if [[ -e "$OUTPUT" ]]; then
        [[ -d "$OUTPUT" && -w "$OUTPUT" ]] || {
            fail "output is not a writable directory: $OUTPUT"
            return 2
        }
        [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
            fail "output directory must be empty: $OUTPUT"
            return 2
        }
    else
        mkdir -- "$OUTPUT"
    fi
    OUTPUT="$(realpath -e -- "$OUTPUT")"
    if [[ -n "$cache_candidate" ]]; then
        CACHE="$(realpath -m -- "$cache_candidate")" || return 2
        [[ "$CACHE" != / && "$CACHE" != "$ROOT" ]] || {
            fail "unsafe artifact cache: $CACHE"
            return 2
        }
        local cache_parent
        cache_parent="$(dirname -- "$CACHE")"
        [[ -d "$cache_parent" && -w "$cache_parent" ]] || {
            fail "artifact cache parent is missing or unwritable: $cache_parent"
            return 2
        }
        if [[ -e "$CACHE" ]]; then
            [[ -d "$CACHE" && -w "$CACHE" ]] || {
                fail "artifact cache is not a writable directory: $CACHE"
                return 2
            }
        else
            mkdir -- "$CACHE"
        fi
        CACHE="$(realpath -e -- "$CACHE")"
    else
        CACHE="$(dirname -- "$OUTPUT")/.task123-comparison-cache.$(basename -- "$OUTPUT").$$"
        mkdir -- "$CACHE"
    fi
    if path_is_within "$OUTPUT" "$CACHE" || path_is_within "$CACHE" "$OUTPUT"; then
        fail "output and artifact cache must be separate: output=$OUTPUT cache=$CACHE"
        return 2
    fi
    comparison_status=RUNNING
    publish_comparison_manifest RUNNING
}

publish_comparison_manifest() {
    local status=$1
    local gate=${2:-}
    local temporary

    temporary="$(mktemp "$OUTPUT/.comparison-manifest.XXXXXX")" || return 1
    if ! {
        printf 'schema=1\nmode=%s\nstability_seconds=%s\ntask2_count=%s\ntask3_frames=3\n' \
            "$mode" "$STABILITY_SECONDS" "$TASK2_COUNT"
        printf 'guest_order=linux,starryos\nshared_artifact_cache=%s\nrunner=%s\nanalyzer=%s\n' \
            "$CACHE" "$RUNNER" "$ANALYZER"
        if [[ "$matrix" -eq 1 ]]; then
            printf 'matrix=all\nrtos_order=rtthread,zephyr\napp_guest_order=linux,starryos\n'
        elif [[ -n "$app_guest" ]]; then
            printf 'rtos=%s\napp_guest=%s\nsingle_combination=1\n' "$rtos" "$app_guest"
        else
            printf 'rtos=%s\n' "$rtos"
        fi
        printf 'status=%s\n' "$status"
        if [[ -n "$gate" ]]; then
            printf 'stability_gate=%s\n' "$gate"
        fi
    } > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -- "$temporary" "$OUTPUT/comparison-manifest.txt"; then
        rm -f -- "$temporary"
        return 1
    fi
}

complete_comparison_manifest() {
    local gate=PASS
    if [[ "$allow_qemu_timer_limit" -eq 1 ]]; then
        gate=PASS_WITH_QEMU_TIMER_LIMIT
    fi
    publish_comparison_manifest COMPLETE "$gate"
    comparison_status=COMPLETE
}

handle_comparison_error() {
    local status=$?
    trap - ERR
    if [[ "$comparison_status" == RUNNING ]]; then
        publish_comparison_manifest FAILED || true
        comparison_status=FAILED
    fi
    exit "$status"
}

handle_comparison_signal() {
    local signal=$1
    local status=$2
    trap - ERR HUP INT TERM
    if [[ "$comparison_status" == RUNNING ]]; then
        publish_comparison_manifest INTERRUPTED || true
        comparison_status=INTERRUPTED
    fi
    exit "$status"
}

run_guest() {
    local guest=$1
    local output=$2
    local guest_mode=stability
    local -a runner_arguments
    if [[ "$matrix" -eq 1 && "$mode" == quick ]]; then
        guest_mode=smoke
    fi
    printf 'PHASE guest-%s\n' "$guest"
    printf 'STEP run-%s mode=%s task2_count=%s\n' \
        "$guest" "$guest_mode" "$TASK2_COUNT"
    if [[ "$guest_mode" == stability ]]; then
        printf 'STABILITY_SECONDS %s\n' "$STABILITY_SECONDS"
    fi
    local runner_environment=(
        "TASK123_SHARED_ARTIFACT_DIR=$CACHE"
        "TASK123_TIMEOUT_S=$RUN_TIMEOUT"
    )
    if [[ "$matrix" -eq 1 ]]; then
        # Matrix quick is a functional coverage run. Multi-threaded TCG keeps
        # one guest vCPU from monopolizing the emulator while another guest
        # is still booting; formal realtime runs retain single-thread TCG.
        runner_environment+=(QEMU_TCG_THREAD=multi)
    fi
    if [[ -n "$ROOTFS_IMAGE" ]]; then
        runner_environment+=("ROOTFS_IMAGE=$ROOTFS_IMAGE")
    fi
    if [[ "$allow_qemu_timer_limit" -eq 1 ]]; then
        runner_environment+=(TASK123_ALLOW_QEMU_TIMER_LIMIT=1)
    fi
    runner_arguments=(
        --rtos "$rtos"
        --app-guest "$guest"
        --mode "$guest_mode"
        --task2-count "$TASK2_COUNT"
        --output "$output"
    )
    if [[ "$guest_mode" == stability ]]; then
        runner_arguments+=(--seconds "$STABILITY_SECONDS")
    else
        runner_arguments+=(--task3-frames 3)
    fi
    env "${runner_environment[@]}" "$RUNNER" "${runner_arguments[@]}"
}

main() {
    parse_arguments "$@"
    case "$mode" in
        quick)
            STABILITY_SECONDS=300
            TASK2_COUNT=30000
            ;;
        full)
            STABILITY_SECONDS=3600
            TASK2_COUNT=240000
            ;;
        *)
            usage
            ;;
    esac
    if [[ "$matrix" -eq 1 && "$mode" == quick ]]; then
        # A four-run matrix is an entrypoint/function check, not a replacement
        # for the formal realtime measurement.  Single-thread TCG can dilate a
        # 300-second guest window to roughly 45 host-minutes per combination,
        # so quick matrix uses a short complete profile.  Single-pair --quick
        # and --full intentionally retain their formal workloads.
        STABILITY_SECONDS=1
        TASK2_COUNT=10
    fi
    if [[ "$mode" == full ]]; then
        # The host budget covers both the Task2 workload and the virtual-clock
        # dilation caused by single-thread TCG with precise icount.  A guest
        # stability window can take several times its nominal virtual duration.
        RUN_TIMEOUT=$((STABILITY_SECONDS * 5 + 5400))
    else
        RUN_TIMEOUT=$((STABILITY_SECONDS * 5 + 5400))
    fi
    RUNNER="$(canonical_executable runner "$RUNNER")"
    ANALYZER="$(canonical_executable analyzer "$ANALYZER")"
    comparison_required=1
    prepare_local_rootfs
    prepare_output

    printf 'OUTPUT %s\nCACHE %s\n' "$OUTPUT" "$CACHE"
    if [[ "$matrix" -eq 1 ]]; then
        for rtos in rtthread zephyr; do
            for guest in linux starryos; do
                run_guest "$guest" "$OUTPUT/$rtos-$guest"
            done
        done
        complete_comparison_manifest
        printf 'Task123 RTOS/app-guest matrix complete: %s\n' "$OUTPUT"
        return 0
    elif [[ -n "$app_guest" ]]; then
        comparison_required=0
        run_guest "$app_guest" "$OUTPUT/$rtos-$app_guest"
    else
        run_guest linux "$OUTPUT/linux"
        run_guest starryos "$OUTPUT/starryos"
    fi

    printf 'PHASE comparison-analysis\n'
    if [[ "$comparison_required" -eq 0 ]]; then
        complete_comparison_manifest
        printf 'Task123 single RTOS/app-guest run complete: %s\n' "$OUTPUT"
        return 0
    fi
    analyzer_arguments=(
        --linux-run "$OUTPUT/linux"
        --starryos-run "$OUTPUT/starryos"
        --output "$OUTPUT/comparison"
    )
    if [[ "$allow_qemu_timer_limit" -eq 1 ]]; then
        analyzer_arguments+=(--allow-qemu-timer-limit)
    fi
    "$ANALYZER" "${analyzer_arguments[@]}"
    [[ -s "$OUTPUT/comparison/comparison.json" &&
       -s "$OUTPUT/comparison/comparison-report.md" ]] || {
        fail "comparison analyzer did not publish both output files"
       return 1
    }
    complete_comparison_manifest
    printf 'Task123 Linux/StarryOS comparison complete: %s\n' "$OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap handle_comparison_error ERR
    trap 'handle_comparison_signal HUP 129' HUP
    trap 'handle_comparison_signal INT 130' INT
    trap 'handle_comparison_signal TERM 143' TERM
    main "$@"
fi
