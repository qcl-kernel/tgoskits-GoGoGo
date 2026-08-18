#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
RUNNER="${TASK123_COMPARISON_RUNNER:-$SCRIPT_DIR/run_task123.sh}"
ANALYZER="${TASK123_COMPARISON_ANALYZER:-$SCRIPT_DIR/compare_task123_guests.py}"

mode=quick
mode_set=0
output_candidate=""

usage() {
    cat >&2 <<EOF
usage:
  $0 [--quick|--full] [--output DIR]

quick:  300-second stability run, 30000 Task2 requests per payload
full:   3600-second stability run, 240000 Task2 requests per payload
EOF
    return 2
}

fail() {
    echo "task123 guest comparison: $*" >&2
    return 1
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
            --output)
                [[ $# -ge 2 && -z "$output_candidate" ]] || usage
                output_candidate=$2
                shift 2
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
    CACHE="$(dirname -- "$OUTPUT")/.task123-comparison-cache.$(basename -- "$OUTPUT").$$"
    mkdir -- "$CACHE"
    ORCHESTRATOR_LOG="$OUTPUT/orchestrator.log"
    : > "$ORCHESTRATOR_LOG"
    {
        printf 'schema=1\nmode=%s\nstability_seconds=%s\ntask2_count=%s\ntask3_frames=3\n' \
            "$mode" "$STABILITY_SECONDS" "$TASK2_COUNT"
        printf 'guest_order=linux,starryos\nshared_artifact_cache=%s\nrunner=%s\nanalyzer=%s\n' \
            "$CACHE" "$RUNNER" "$ANALYZER"
    } > "$OUTPUT/comparison-manifest.txt"
}

run_guest() {
    local guest=$1
    local output="$OUTPUT/$guest"
    printf 'PHASE guest-%s\n' "$guest" | tee -a "$ORCHESTRATOR_LOG"
    printf 'STEP run-%s mode=stability seconds=%s task2_count=%s\n' \
        "$guest" "$STABILITY_SECONDS" "$TASK2_COUNT" | tee -a "$ORCHESTRATOR_LOG"
    TASK123_SHARED_ARTIFACT_DIR="$CACHE" \
    TASK123_TIMEOUT_S="$RUN_TIMEOUT" \
        "$RUNNER" --app-guest "$guest" --mode stability \
        --seconds "$STABILITY_SECONDS" --task2-count "$TASK2_COUNT" \
        --output "$output" 2>&1 | tee -a "$ORCHESTRATOR_LOG"
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
    RUN_TIMEOUT=$((STABILITY_SECONDS + 600))
    RUNNER="$(canonical_executable runner "$RUNNER")"
    ANALYZER="$(canonical_executable analyzer "$ANALYZER")"
    prepare_output

    printf 'OUTPUT %s\nCACHE %s\n' "$OUTPUT" "$CACHE" | tee -a "$ORCHESTRATOR_LOG"
    run_guest linux
    run_guest starryos

    printf 'PHASE comparison-analysis\n' | tee -a "$ORCHESTRATOR_LOG"
    "$ANALYZER" --linux-run "$OUTPUT/linux" --starryos-run "$OUTPUT/starryos" \
        --output "$OUTPUT/comparison" 2>&1 | tee -a "$ORCHESTRATOR_LOG"
    [[ -s "$OUTPUT/comparison/comparison.json" &&
       -s "$OUTPUT/comparison/comparison-report.md" ]] || {
        fail "comparison analyzer did not publish both output files"
        return 1
    }
    printf 'Task123 Linux/StarryOS comparison complete: %s\n' "$OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
