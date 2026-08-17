#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TASK123_RUNNER="${NATIVE_TASK123_RUNNER:-$ROOT/os/axvisor/scripts/run_task123.sh}"
RTTHREAD_COMMIT="${NATIVE_RTTHREAD_COMMIT:-ddf52e2cdd977f14fc04035c88672ac204aec713}"
mode=smoke
mode_was_set=0
input_dir="${NATIVE_INPUT_DIR:-}"
output_candidate="${NATIVE_OUTPUT_DIR:-}"

usage() {
    local status=${1:-2}
    cat >&2 <<EOF
Usage: ./run-native.sh [smoke|suite|stability] [--input-dir DIR] [--output DIR]

Native one-command runner for one 2-vCPU Linux guest and one RT-Thread guest.
No environment exports are required.

Modes:
  smoke       Short Linux/RT-Thread network and protocol verification (default)
  suite       1000-sample realtime suite
  stability   300-second stability test
EOF
    exit "$status"
}

fail() {
    echo "native task123 runner: $*" >&2
    return 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            smoke|suite|stability)
                [[ "$mode_was_set" -eq 0 ]] || usage
                mode=$1
                mode_was_set=1
                shift
                ;;
            --input-dir)
                [[ $# -ge 2 && -z "$input_dir" ]] || usage
                input_dir=$2
                shift 2
                ;;
            --output)
                [[ $# -ge 2 && -z "$output_candidate" ]] || usage
                output_candidate=$2
                shift 2
                ;;
            -h|--help) usage 0 ;;
            *) usage ;;
        esac
    done
}

canonical_file() {
    local label=$1
    local candidate=$2
    local resolved
    resolved="$(realpath -e -- "$candidate")" || return 1
    [[ -f "$resolved" && -r "$resolved" && -s "$resolved" ]] || {
        fail "$label is not a readable nonempty file: $candidate"
        return 1
    }
    printf '%s\n' "$resolved"
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

first_file() {
    local label=$1
    shift
    local candidate
    local resolved
    for candidate in "$@"; do
        [[ -n "$candidate" && -e "$candidate" ]] || continue
        if resolved="$(canonical_file "$label" "$candidate")"; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}

workspace_root() {
    local common_dir
    local primary_repository
    if common_dir="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)"; then
        [[ "$common_dir" == /* ]] || common_dir="$ROOT/$common_dir"
        common_dir="$(realpath -e -- "$common_dir")"
        primary_repository="$(dirname -- "$common_dir")"
        dirname -- "$primary_repository"
    else
        dirname -- "$ROOT"
    fi
}

prepare_output() {
    local output_parent
    if [[ -z "$output_candidate" ]]; then
        output_candidate="$ROOT/tmp/native-runs/$mode-$(date -u +%Y%m%dT%H%M%SZ)"
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
    fi
}

resolve_explicit_inputs() {
    local directory
    directory="$(realpath -e -- "$input_dir")" || {
        fail "input directory does not exist: $input_dir"
        return 1
    }
    [[ -d "$directory" ]] || fail "input is not a directory: $directory"
    LINUX_KERNEL_IMAGE="$(first_file linux-kernel \
        "$directory/linux-kernel" "$directory/Image")" ||
        fail "input directory has no Linux kernel: $directory"
    LINUX_INITRAMFS_IMAGE="$(first_file linux-initramfs \
        "$directory/linux-initramfs.cpio" \
        "$directory/linux-1-initramfs.cpio" \
        "$directory/rootfs.cpio")" ||
        fail "input directory has no Linux initramfs: $directory"
    ROOTFS_IMAGE="$(first_file rootfs "$directory/rootfs.img")" ||
        fail "input directory has no rootfs.img: $directory"
    TASK123_MODEL_IMAGE="$(first_file model \
        "$directory/model_weights.h" 2>/dev/null || true)"
}

resolve_local_inputs() {
    local workspace=$1
    local primary_repository="$workspace/$(basename -- "$(dirname -- "$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || printf '.git')")")"
    local local_inputs="$ROOT/tmp/task123-native-inputs"

    LINUX_KERNEL_IMAGE="$(first_file linux-kernel \
        "$local_inputs/linux-kernel" \
        "$ROOT/tmp/task123-linux-build-v3/images/linux/Image" \
        "$primary_repository/tmp/vmconfigs/two-guest-net/current/linux-kernel" \
        2>/dev/null || true)"
    LINUX_INITRAMFS_IMAGE="$(first_file linux-initramfs \
        "$local_inputs/linux-initramfs.cpio" \
        "$local_inputs/linux-1-initramfs.cpio" \
        "$ROOT/tmp/task123-linux-build-v3/images/linux/rootfs.cpio" \
        "$primary_repository/tmp/vmconfigs/two-guest-net/current/linux-1-initramfs.cpio" \
        2>/dev/null || true)"
    TASK123_MODEL_IMAGE="$(first_file model \
        "$local_inputs/model_weights.h" \
        "$ROOT/tmp/task123-linux-build-v3/model/model_weights.h" \
        2>/dev/null || true)"
    ROOTFS_IMAGE="$(first_file rootfs \
        "$local_inputs/rootfs.img" \
        "$ROOT/tmp/vmconfigs/two-guest-net/current/rootfs.img" \
        "$primary_repository/tmp/vmconfigs/two-guest-net/current/rootfs.img" \
        2>/dev/null || true)"
}

valid_rtthread_repository() {
    local repository=$1
    [[ -d "$repository" ]] || return 1
    GIT_NO_LAZY_FETCH=1 git -C "$repository" cat-file -e \
        "$RTTHREAD_COMMIT^{commit}" 2>/dev/null || return 1
    [[ -z "$(git -C "$repository" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ]] ||
        return 1
    local required_path
    for required_path in bsp/qemu-virt64-aarch64 components src; do
        [[ "$(GIT_NO_LAZY_FETCH=1 git -C "$repository" cat-file -t \
            "$RTTHREAD_COMMIT:$required_path" 2>/dev/null)" == tree ]] || return 1
    done
    ! GIT_NO_LAZY_FETCH=1 git -C "$repository" rev-list --objects \
        --missing=print "$RTTHREAD_COMMIT" 2>/dev/null |
        grep -q '^?' || return 1
    GIT_NO_LAZY_FETCH=1 git -C "$repository" archive --format=tar \
        "$RTTHREAD_COMMIT" >/dev/null 2>&1
}

resolve_rtthread_repository() {
    local workspace=$1
    local candidate
    if [[ -n "${RTTHREAD_SRC:-}" ]]; then
        candidate="$(realpath -e -- "$RTTHREAD_SRC")" ||
            fail "explicit RT-Thread source does not exist: $RTTHREAD_SRC"
        valid_rtthread_repository "$candidate" ||
            fail "explicit RT-Thread source is incomplete, dirty, or unpinned: $candidate"
        RTTHREAD_REPOSITORY=$candidate
        return
    fi

    while IFS= read -r candidate; do
        candidate="$(dirname -- "$candidate")"
        if valid_rtthread_repository "$candidate"; then
            RTTHREAD_REPOSITORY="$(realpath -e -- "$candidate")"
            return
        fi
    done < <(
        find "$ROOT/tmp" "$workspace" -maxdepth 6 \
            \( -type d -o -type f \) -name .git -print 2>/dev/null | sort -u
    )
    RTTHREAD_REPOSITORY=
}

runner_arguments() {
    case "$mode" in
        smoke)
            RUNNER_ARGS=(--mode smoke --task2-count 100 --task3-frames 3)
            ;;
        suite)
            RUNNER_ARGS=(
                --mode realtime-suite --rtbench-samples 1000 --task2-count 1000
            )
            ;;
        stability)
            RUNNER_ARGS=(
                --mode stability --seconds 300 --task2-count 30000
            )
            ;;
    esac
}

run_native() {
    local environment=(env -u QEMU)
    [[ -z "${LINUX_KERNEL_IMAGE:-}" ]] ||
        environment+=("LINUX_KERNEL_IMAGE=$LINUX_KERNEL_IMAGE")
    [[ -z "${LINUX_INITRAMFS_IMAGE:-}" ]] ||
        environment+=("LINUX_INITRAMFS_IMAGE=$LINUX_INITRAMFS_IMAGE")
    [[ -z "${TASK123_MODEL_IMAGE:-}" ]] ||
        environment+=("TASK123_MODEL_IMAGE=$TASK123_MODEL_IMAGE")
    [[ -z "${ROOTFS_IMAGE:-}" ]] ||
        environment+=("ROOTFS_IMAGE=$ROOTFS_IMAGE")
    [[ -z "${RTTHREAD_REPOSITORY:-}" ]] ||
        environment+=("RTTHREAD_REPOSITORY=$RTTHREAD_REPOSITORY")

    printf 'Native mode: %s\n' "$mode"
    printf 'Output: %s\n' "$OUTPUT"
    printf 'QEMU: qemu-system-aarch64 (PATH)\n'
    printf 'Linux kernel: %s\n' "${LINUX_KERNEL_IMAGE:-runner fallback}"
    printf 'Linux initramfs: %s\n' "${LINUX_INITRAMFS_IMAGE:-runner fallback}"
    printf 'Rootfs: %s\n' "${ROOTFS_IMAGE:-runner fallback}"
    printf 'Model: %s\n' "${TASK123_MODEL_IMAGE:-runner fallback}"
    printf 'RT-Thread source: %s\n' "${RTTHREAD_REPOSITORY:-runner fallback}"

    "${environment[@]}" "$TASK123_RUNNER" "${RUNNER_ARGS[@]}" --output "$OUTPUT"
}

main() {
    parse_arguments "$@"
    command -v qemu-system-aarch64 >/dev/null ||
        fail "required command not found in PATH: qemu-system-aarch64"
    command -v git >/dev/null || fail "required command not found in PATH: git"
    TASK123_RUNNER="$(canonical_executable task123-runner "$TASK123_RUNNER")"
    prepare_output
    local workspace
    workspace="$(workspace_root)"
    if [[ -n "$input_dir" ]]; then
        resolve_explicit_inputs
    else
        resolve_local_inputs "$workspace"
    fi
    resolve_rtthread_repository "$workspace"
    runner_arguments
    run_native
}

main "$@"
