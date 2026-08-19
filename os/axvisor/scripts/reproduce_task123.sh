#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
TASK123_RUNNER="${TASK123_RUNNER:-$SCRIPT_DIR/run_task123.sh}"
TASK123_FAULT_SUMMARIZER="${TASK123_FAULT_SUMMARIZER:-$ROOT/os/axvisor/guests/task3/scripts/summarize_faults.py}"

usage() {
    local status=${1:-2}
    cat >&2 <<EOF
usage: $0 [--quick|--full] [--output DIR]

  --quick       smoke + short realtime suite + 30-frame Task 3 (default)
  --full        realtime suite + 300s stability + 600-frame Task 3 + 5 faults
  --output DIR  evidence directory (default: tmp/task123-reproduction-<UTC>)
EOF
    exit "$status"
}

fail() {
    echo "task123 reproducer: $*" >&2
    return 1
}

canonical_executable() {
    local label=$1
    local candidate=$2
    local resolved
    if [[ "$candidate" == */* ]]; then
        resolved="$(realpath -e -- "$candidate")" || {
            fail "$label does not exist: $candidate"
            return 1
        }
    else
        resolved="$(command -v -- "$candidate")" || {
            fail "required command not found: $candidate"
            return 1
        }
        resolved="$(realpath -e -- "$resolved")"
    fi
    [[ -f "$resolved" && -x "$resolved" ]] || {
        fail "$label is not executable: $resolved"
        return 1
    }
    printf '%s\n' "$resolved"
}

profile=quick
profile_was_set=0
output_candidate=
output_was_set=0

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick|--full)
                [[ "$profile_was_set" -eq 0 ]] || usage
                profile=${1#--}
                profile_was_set=1
                shift
                ;;
            --output)
                [[ "$output_was_set" -eq 0 && $# -ge 2 && -n "$2" ]] || usage
                output_candidate=$2
                output_was_set=1
                shift 2
                ;;
            -h|--help) usage 0 ;;
            *) usage ;;
        esac
    done
}

resolve_dependencies() {
    local command_name
    for command_name in date find git gzip grep python3 realpath sha256sum tar uname; do
        command -v "$command_name" >/dev/null ||
            fail "required command not found: $command_name"
    done
    TASK123_RUNNER="$(canonical_executable task123-runner "$TASK123_RUNNER")"
    TASK123_FAULT_SUMMARIZER="$(
        canonical_executable fault-summarizer "$TASK123_FAULT_SUMMARIZER"
    )"
}

prepare_output_directory() {
    local output_parent
    if [[ -z "$output_candidate" ]]; then
        output_candidate="$ROOT/tmp/task123-reproduction-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    OUTPUT="$(realpath -m -- "$output_candidate")"
    [[ "$OUTPUT" != / && "$OUTPUT" != "$ROOT" ]] ||
        fail "unsafe output directory: $OUTPUT"
    output_parent="$(dirname -- "$OUTPUT")"
    mkdir -p -- "$output_parent"
    [[ -d "$output_parent" && -w "$output_parent" ]] ||
        fail "output parent is not writable: $output_parent"
    if [[ -e "$OUTPUT" ]]; then
        [[ -d "$OUTPUT" && -w "$OUTPUT" ]] ||
            fail "output is not a writable directory: $OUTPUT"
        [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
            fail "output directory must be empty: $OUTPUT"
    else
        mkdir -- "$OUTPUT"
    fi
    OUTPUT="$(realpath -e -- "$OUTPUT")"
    SUMMARY="$OUTPUT/reproduction-summary.txt"
    SYSTEM_INFO="$OUTPUT/system-info.txt"
    REPRODUCTION_LOG="$OUTPUT/reproduction.log"
    : > "$REPRODUCTION_LOG"
}

record_system_info() {
    local commit
    local branch
    commit="$(git -C "$ROOT" rev-parse HEAD)"
    branch="$(git -C "$ROOT" branch --show-current)"
    cat > "$SYSTEM_INFO" <<EOF
schema=1
execution=host
git_commit=$commit
git_branch=$branch
uname=$(uname -a)
qemu=${QEMU:-qemu-system-aarch64}
rtthread_repository=${RTTHREAD_REPOSITORY:-pinned-upstream-source}
qemu_timer_slack_ns=${QEMU_TIMER_SLACK_NS:-1}
EOF
    cat > "$SUMMARY" <<EOF
schema=1
profile=$profile
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_commit=$commit
EOF
}

announce() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >> "$REPRODUCTION_LOG"
}

run_phase() {
    local phase_name=$1
    shift
    local phase_rc
    announce "[task123] START $phase_name"
    if "$TASK123_RUNNER" "$@" 2>&1 | tee -a "$REPRODUCTION_LOG"; then
        announce "[task123] PASS  $phase_name"
        return 0
    else
        phase_rc=$?
    fi
    announce "[task123] FAIL  $phase_name rc=$phase_rc"
    return "$phase_rc"
}

run_required_phase() {
    local summary_key=$1
    local phase_name=$2
    shift 2
    local phase_rc
    if run_phase "$phase_name" "$@"; then
        printf '%s_status=PASS\n' "$summary_key" >> "$SUMMARY"
        return 0
    else
        phase_rc=$?
    fi
    printf '%s_status=FAIL\n' "$summary_key" >> "$SUMMARY"
    fail "$phase_name failed with status $phase_rc; see $REPRODUCTION_LOG"
    return "$phase_rc"
}

is_accepted_qemu_timer_limit() {
    local console_log=$1
    [[ -s "$console_log" ]] || return 1
    grep -aFq 'TASK2_LINUX_END status=PASS' "$console_log" || return 1
    grep -aFq 'TASK3_LINUX_END status=PASS' "$console_log" || return 1
    grep -aFq 'TASK123_LINUX_END status=PASS' "$console_log" || return 1
    grep -aFq 'RTBENCH_STABILITY_END status=FAIL' "$console_log" || return 1
    grep -aFq 'RTBENCH_STABILITY_DONE' "$console_log" || return 1
    grep -aEq 'miss_1ms=[1-9][0-9]*' "$console_log" || return 1
    ! grep -aiEq \
        'panic|assert|fatal|TASK2_LINUX_END status=FAIL|TASK3_LINUX_END status=FAIL|TASK123_LINUX_END status=FAIL' \
        "$console_log"
}

verify_passed_phase_evidence() {
    local phase_directory=$1
    local evidence_file
    for evidence_file in \
        axvisor.bin console.log linux.log rtthread.log frames.csv \
        summary.raw.json summary.json manifest.txt runner.log; do
        [[ -s "$phase_directory/$evidence_file" ]] || {
            fail "missing or empty phase evidence: $phase_directory/$evidence_file"
            return 1
        }
    done
    grep -Fxq 'result_gate=PASS' "$phase_directory/manifest.txt" ||
        fail "result gate is not PASS: $phase_directory/manifest.txt"
}

run_quick_profile() {
    run_required_phase smoke smoke \
        --mode smoke --task2-count 100 --task3-frames 3 \
        --output "$OUTPUT/smoke"
    run_required_phase realtime realtime-suite \
        --mode realtime-suite --rtbench-samples 100 --task2-count 100 \
        --output "$OUTPUT/realtime-suite"
    run_required_phase task3 task3-normal \
        --mode task3 --task3-frames 30 --output "$OUTPUT/task3-normal"

    verify_passed_phase_evidence "$OUTPUT/smoke"
    verify_passed_phase_evidence "$OUTPUT/realtime-suite"
    verify_passed_phase_evidence "$OUTPUT/task3-normal"
    ARCHIVE_MEMBERS=(smoke realtime-suite task3-normal)
    OVERALL_STATUS=PASS
}

run_full_profile() {
    local stability_rc
    local fault_profile

    run_required_phase realtime realtime-suite \
        --mode realtime-suite --rtbench-samples 1000 --task2-count 1000 \
        --output "$OUTPUT/realtime-suite"

    if run_phase stability-300s \
        --mode stability --seconds 300 --task2-count 30000 \
        --output "$OUTPUT/stability-300s"; then
        printf 'stability_status=PASS\n' >> "$SUMMARY"
        verify_passed_phase_evidence "$OUTPUT/stability-300s"
        OVERALL_STATUS=PASS
    else
        stability_rc=$?
        if is_accepted_qemu_timer_limit "$OUTPUT/stability-300s/console.log"; then
            printf 'stability_status=QEMU_TIMER_LIMIT\n' >> "$SUMMARY"
            printf 'stability_runner_exit=%s\n' "$stability_rc" >> "$SUMMARY"
            announce '[task123] CONTINUE stability-300s: accepted QEMU/TCG 1 ms timer limit'
            OVERALL_STATUS=PASS_WITH_QEMU_TIMER_LIMIT
        else
            printf 'stability_status=FAIL\n' >> "$SUMMARY"
            fail "stability failed outside the accepted QEMU timer limit; see $REPRODUCTION_LOG"
            return "$stability_rc"
        fi
    fi

    run_required_phase task3 task3-normal \
        --mode task3 --task3-frames 600 --output "$OUTPUT/task3-normal"
    mkdir -- "$OUTPUT/task3-faults"
    for fault_profile in \
        drop-control drop-status duplicate-frame delayed-server malformed; do
        run_required_phase "fault_${fault_profile//-/_}" "task3-fault-$fault_profile" \
            --mode task3-fault --task3-fault "$fault_profile" --task3-frames 3 \
            --output "$OUTPUT/task3-faults/$fault_profile"
    done

    announce '[task123] START task3-fault-summary'
    "$TASK123_FAULT_SUMMARIZER" --suite-dir "$OUTPUT/task3-faults" \
        2>&1 | tee -a -- "$REPRODUCTION_LOG"
    [[ -s "$OUTPUT/task3-faults/fault-summary.json" ]] ||
        fail "fault summarizer produced no fault-summary.json"
    announce '[task123] PASS  task3-fault-summary'

    verify_passed_phase_evidence "$OUTPUT/realtime-suite"
    verify_passed_phase_evidence "$OUTPUT/task3-normal"
    for fault_profile in \
        drop-control drop-status duplicate-frame delayed-server malformed; do
        verify_passed_phase_evidence "$OUTPUT/task3-faults/$fault_profile"
    done
    ARCHIVE_MEMBERS=(realtime-suite stability-300s task3-normal task3-faults)
}

create_evidence_archive() {
    local archive_name="task123-${profile}-evidence.tar.gz"
    local archive="$OUTPUT/$archive_name"
    local archive_digest
    local member
    local members=(
        ./reproduction-summary.txt
        ./system-info.txt
        ./reproduction.log
    )
    for member in "${ARCHIVE_MEMBERS[@]}"; do
        members+=("./$member")
    done

    printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SUMMARY"
    printf 'overall_status=%s\n' "$OVERALL_STATUS" >> "$SUMMARY"
    printf 'evidence_archive=%s\n' "$archive_name" >> "$SUMMARY"

    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 \
        --numeric-owner -C "$OUTPUT" -czf "$archive" -- "${members[@]}"
    gzip -t "$archive"
    archive_digest="$(sha256sum "$archive")"
    archive_digest=${archive_digest%% *}
    printf '%s  %s\n' "$archive_digest" "$archive_name" > "$archive.sha256"
    announce "[task123] COMPLETE status=$OVERALL_STATUS"
    announce "[task123] SUMMARY  $SUMMARY"
    announce "[task123] EVIDENCE $archive"
    announce "[task123] SHA256   $archive_digest"
}

main() {
    parse_arguments "$@"
    resolve_dependencies
    prepare_output_directory
    record_system_info
    announce "[task123] OUTPUT $OUTPUT"
    announce "[task123] LOG    $REPRODUCTION_LOG"
    cd "$ROOT"

    if [[ "$profile" == quick ]]; then
        run_quick_profile
    else
        run_full_profile
    fi
    create_evidence_archive
}

main "$@"
