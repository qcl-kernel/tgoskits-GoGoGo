#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
TASK3_ROOT="$ROOT/os/axvisor/guests/task3"
RUN_UNTIL="${RUN_UNTIL:-$SCRIPT_DIR/run_until_log_marker.sh}"
QEMU_REALTIME_CONTROL="${QEMU_REALTIME_CONTROL:-$SCRIPT_DIR/apply_qemu_realtime_controls.sh}"
QEMU_RESOURCE_SAMPLER="${QEMU_RESOURCE_SAMPLER:-$SCRIPT_DIR/sample_qemu_resources.sh}"
LINUX_VMCONFIG_GENERATOR="${LINUX_VMCONFIG_GENERATOR:-$SCRIPT_DIR/generate_linux_vmconfig.sh}"
STARRYOS_VMCONFIG_GENERATOR="${STARRYOS_VMCONFIG_GENERATOR:-$SCRIPT_DIR/generate_starryos_vmconfig.sh}"
RTTHREAD_VMCONFIG_GENERATOR="${RTTHREAD_VMCONFIG_GENERATOR:-$SCRIPT_DIR/generate_rtthread_vmconfig.sh}"
RESULT_GATE="${RESULT_GATE:-$SCRIPT_DIR/verify_task123_results.sh}"
LINUX_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml"
STARRYOS_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"
RTTHREAD_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"
STARRYOS_BUILDER="$ROOT/os/axvisor/guests/starryos-task123/build.sh"
PROTOCOL_SOURCE="$ROOT/os/axvisor/guests/rt-ipc/common/rt_ipc.c"
PROTOCOL_HEADER="$ROOT/os/axvisor/guests/rt-ipc/common/rt_ipc.h"

usage() {
    cat >&2 <<EOF
usage:
  $0 [--app-guest linux|starryos] --mode smoke [--task2-count N] [--task3-frames N] --output DIR
  $0 [--app-guest linux|starryos] --mode realtime-suite [--rtbench-samples N] [--task2-count N] --output DIR
  $0 [--app-guest linux|starryos] --mode stability [--seconds N] [--task2-count N] --output DIR
  $0 [--app-guest linux|starryos] --mode task3 [--task3-frames N] --output DIR
  $0 [--app-guest linux|starryos] --mode task3-fault --task3-fault PROFILE [--task3-frames N] --output DIR
EOF
    return 2
}

fail() {
    echo "task123 runner: $*" >&2
    return 1
}

require_integer() {
    local value=$1
    local minimum=$2
    local maximum=$3
    local label=$4
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge "$minimum" && "$value" -le "$maximum" ]] || {
        echo "$label must be an integer from $minimum to $maximum" >&2
        return 2
    }
}

mode=
app_guest=linux
output_candidate=
task2_count=
task3_frames=
rtbench_samples=
stability_seconds=
task3_fault=
seen_mode=0
seen_app_guest=0
seen_output=0
seen_task2=0
seen_task3_frames=0
seen_rtbench=0
seen_seconds=0
seen_fault=0

parse_arguments() {
    local option
    local value
    while [[ $# -gt 0 ]]; do
        option=$1
        case "$option" in
            --app-guest|--mode|--output|--task2-count|--task3-frames|--rtbench-samples|--seconds|--task3-fault)
                [[ $# -ge 2 ]] || usage
                value=$2
                shift 2
                case "$option" in
                    --app-guest)
                        [[ "$seen_app_guest" -eq 0 ]] || usage
                        app_guest=$value
                        seen_app_guest=1
                        ;;
                    --mode)
                        [[ "$seen_mode" -eq 0 ]] || usage
                        mode=$value
                        seen_mode=1
                        ;;
                    --output)
                        [[ "$seen_output" -eq 0 ]] || usage
                        output_candidate=$value
                        seen_output=1
                        ;;
                    --task2-count)
                        [[ "$seen_task2" -eq 0 ]] || usage
                        task2_count=$value
                        seen_task2=1
                        ;;
                    --task3-frames)
                        [[ "$seen_task3_frames" -eq 0 ]] || usage
                        task3_frames=$value
                        seen_task3_frames=1
                        ;;
                    --rtbench-samples)
                        [[ "$seen_rtbench" -eq 0 ]] || usage
                        rtbench_samples=$value
                        seen_rtbench=1
                        ;;
                    --seconds)
                        [[ "$seen_seconds" -eq 0 ]] || usage
                        stability_seconds=$value
                        seen_seconds=1
                        ;;
                    --task3-fault)
                        [[ "$seen_fault" -eq 0 ]] || usage
                        task3_fault=$value
                        seen_fault=1
                        ;;
                esac
                ;;
            -h|--help)
                usage
                ;;
            *) usage ;;
        esac
    done
}

validate_mode_options() {
    [[ "$seen_mode" -eq 1 && "$seen_output" -eq 1 && -n "$output_candidate" ]] ||
        usage
    case "$mode" in
        smoke)
            [[ "$seen_rtbench" -eq 0 && "$seen_seconds" -eq 0 && "$seen_fault" -eq 0 ]] || usage
            task2_count=${task2_count:-1000}
            task3_frames=${task3_frames:-3}
            ;;
        realtime-suite)
            [[ "$seen_task3_frames" -eq 0 && "$seen_seconds" -eq 0 && "$seen_fault" -eq 0 ]] || usage
            task2_count=${task2_count:-1000}
            task3_frames=3
            rtbench_samples=${rtbench_samples:-1000}
            ;;
        stability)
            [[ "$seen_task3_frames" -eq 0 && "$seen_rtbench" -eq 0 && "$seen_fault" -eq 0 ]] || usage
            task2_count=${task2_count:-30000}
            task3_frames=3
            stability_seconds=${stability_seconds:-300}
            ;;
        task3)
            [[ "$seen_task2" -eq 0 && "$seen_rtbench" -eq 0 && "$seen_seconds" -eq 0 && "$seen_fault" -eq 0 ]] || usage
            task2_count=1000
            task3_frames=${task3_frames:-600}
            ;;
        task3-fault)
            [[ "$seen_task2" -eq 0 && "$seen_rtbench" -eq 0 && "$seen_seconds" -eq 0 && "$seen_fault" -eq 1 ]] || usage
            task2_count=1000
            task3_frames=${task3_frames:-3}
            case "$task3_fault" in
                drop-control|drop-status|duplicate-frame|delayed-server|malformed) ;;
                *) usage ;;
            esac
            ;;
        *) usage ;;
    esac

    case "$app_guest" in
        linux|starryos) ;;
        *) usage ;;
    esac

    require_integer "$task2_count" 1 2147483647 task2-count
    require_integer "$task3_frames" 1 600 task3-frames
    if [[ "$mode" == realtime-suite ]]; then
        require_integer "$rtbench_samples" 1 100000 rtbench-samples
    elif [[ "$mode" == stability ]]; then
        require_integer "$stability_seconds" 1 3600 seconds
    fi
    require_integer "${TASK123_TIMEOUT_S:-600}" 1 86400 TASK123_TIMEOUT_S
    require_integer "${TASK123_BUILD_TIMEOUT_S:-1800}" 1 86400 TASK123_BUILD_TIMEOUT_S
    require_integer "${TASK123_PHASE_TIMEOUT_S:-600}" 1 86400 TASK123_PHASE_TIMEOUT_S
    require_integer "${QEMU_UCLAMP_MIN:-1024}" 0 1024 QEMU_UCLAMP_MIN
    require_integer "${QEMU_TIMER_SLACK_NS:-1}" 1 1000000000 QEMU_TIMER_SLACK_NS
    require_integer "${QEMU_RESOURCE_SAMPLE_INTERVAL_MS:-100}" 1 60000 QEMU_RESOURCE_SAMPLE_INTERVAL_MS
    require_integer "${TASK123_ALLOW_QEMU_TIMER_LIMIT:-0}" 0 1 TASK123_ALLOW_QEMU_TIMER_LIMIT
    if [[ "${TASK123_ALLOW_QEMU_TIMER_LIMIT:-0}" -eq 1 && "$mode" != stability ]]; then
        fail "TASK123_ALLOW_QEMU_TIMER_LIMIT is only valid for stability mode"
        return 2
    fi
}

canonical_existing_file() {
    local label=$1
    local candidate=$2
    local resolved
    resolved="$(realpath -e -- "$candidate")" || {
        fail "$label does not exist: $candidate"
        return 1
    }
    [[ -f "$resolved" && -r "$resolved" ]] || {
        fail "$label is not a readable file: $resolved"
        return 1
    }
    printf '%s\n' "$resolved"
}

canonical_tool() {
    local label=$1
    local candidate=$2
    local resolved
    local resolved_directory
    if [[ "$candidate" == */* ]]; then
        resolved=$candidate
    else
        resolved="$(command -v -- "$candidate")" || {
            fail "required command not found: $label=$candidate"
            return 1
        }
    fi
    resolved_directory="$(realpath -e -- "$(dirname -- "$resolved")")" || return 1
    resolved="$resolved_directory/$(basename -- "$resolved")"
    [[ -f "$resolved" && -x "$resolved" ]] || {
        fail "$label is not executable: $resolved"
        return 1
    }
    printf '%s\n' "$resolved"
}

path_is_within() {
    local child=$1
    local parent=$2
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

validate_output_against_source() {
    local source_candidate=$1
    local source_path
    [[ -n "$source_candidate" ]] || return 0
    source_path="$(realpath -e -- "$source_candidate")" || {
        fail "source input does not exist: $source_candidate"
        return 1
    }
    if [[ -d "$source_path" ]]; then
        ! path_is_within "$OUTPUT" "$source_path" || {
            fail "output directory is within source input: $OUTPUT"
            return 1
        }
    else
        [[ "$OUTPUT" != "$source_path" ]] || {
            fail "output path equals source input: $OUTPUT"
            return 1
        }
    fi
}

prepare_shared_artifact_cache() {
    [[ -n "$SHARED_ARTIFACT_DIR" ]] || return 0
    SHARED_ARTIFACT_DIR="$(realpath -m -- "$SHARED_ARTIFACT_DIR")" || return 2
    [[ "$SHARED_ARTIFACT_DIR" != / && "$SHARED_ARTIFACT_DIR" != "$ROOT" ]] || {
        fail "unsafe shared artifact cache: $SHARED_ARTIFACT_DIR"
        return 2
    }
    local cache_parent
    cache_parent="$(dirname -- "$SHARED_ARTIFACT_DIR")"
    [[ -d "$cache_parent" && -w "$cache_parent" ]] || {
        fail "shared artifact cache parent is missing or unwritable: $cache_parent"
        return 2
    }
    if [[ -e "$SHARED_ARTIFACT_DIR" ]]; then
        [[ -d "$SHARED_ARTIFACT_DIR" && -w "$SHARED_ARTIFACT_DIR" ]] || {
            fail "shared artifact cache is not a writable directory: $SHARED_ARTIFACT_DIR"
            return 2
        }
    else
        mkdir -- "$SHARED_ARTIFACT_DIR"
    fi
    SHARED_ARTIFACT_DIR="$(realpath -e -- "$SHARED_ARTIFACT_DIR")"
    if path_is_within "$OUTPUT" "$SHARED_ARTIFACT_DIR" ||
       path_is_within "$SHARED_ARTIFACT_DIR" "$OUTPUT"; then
        fail "output and shared artifact cache must be separate: output=$OUTPUT cache=$SHARED_ARTIFACT_DIR"
        return 2
    fi
}

shared_cache_file() {
    local filename=$1
    [[ -n "$SHARED_ARTIFACT_DIR" ]] || return 1
    printf '%s/%s\n' "$SHARED_ARTIFACT_DIR" "$filename"
}

stage_shared_artifact() {
    local label=$1
    local filename=$2
    local source=$3
    local target
    local temporary
    [[ -n "$SHARED_ARTIFACT_DIR" ]] || {
        printf '%s\n' "$source"
        return 0
    }
    target="$(shared_cache_file "$filename")"
    if [[ -e "$target" ]]; then
        target="$(canonical_existing_file "shared-cache-$label" "$target")"
        cmp -s -- "$source" "$target" || {
            fail "shared cache artifact differs from explicit $label: $target"
            return 1
        }
    else
        temporary="$target.tmp.$$"
        cp -- "$source" "$temporary"
        chmod a+r -- "$temporary"
        mv -- "$temporary" "$target"
    fi
    printf '%s\n' "$(canonical_existing_file "shared-cache-$label" "$target")"
}

resolve_input_artifact() {
    local variable=$1
    local label=$2
    local filename=$3
    local current="${!variable:-}"
    local cached
    if [[ -n "$current" ]]; then
        current="$(canonical_existing_file "$label" "$current")"
        current="$(stage_shared_artifact "$label" "$filename" "$current")"
        printf -v "$variable" '%s' "$current"
        return 0
    fi
    if [[ -n "$SHARED_ARTIFACT_DIR" && -e "$SHARED_ARTIFACT_DIR/$filename" ]]; then
        cached="$(canonical_existing_file "shared-cache-$label" "$SHARED_ARTIFACT_DIR/$filename")"
        printf -v "$variable" '%s' "$cached"
    fi
}

resolve_legacy_model_fallback() {
    [[ -n "${TASK123_MODEL_IMAGE:-}" ]] && return 0
    local fallback="$TASK3_ROOT/build/model/model_weights.h"
    if [[ -f "$fallback" && -r "$fallback" && -s "$fallback" ]]; then
        TASK123_MODEL_IMAGE="$fallback"
    fi
}

check_no_network_artifacts() {
    [[ "${TASK123_NO_NETWORK:-0}" == 1 ]] || return 0

    local -a required_artifacts=(
        RTTHREAD_NORMAL_IMAGE
        RTTHREAD_DROP_STATUS_IMAGE
        RTTHREAD_DELAYED_SERVER_IMAGE
        ROOTFS_IMAGE
        TASK123_MODEL_IMAGE
    )
    if [[ "$app_guest" == linux ]]; then
        required_artifacts=(LINUX_KERNEL_IMAGE LINUX_INITRAMFS_IMAGE "${required_artifacts[@]}")
    else
        required_artifacts=(STARRYOS_IMAGE "${required_artifacts[@]}")
    fi

    local artifact
    local -a missing_artifacts=()
    for artifact in "${required_artifacts[@]}"; do
        [[ -n "${!artifact:-}" ]] || missing_artifacts+=("$artifact")
    done
    if [[ "${#missing_artifacts[@]}" -gt 0 ]]; then
        fail "TASK123_NO_NETWORK=1 missing local artifacts: ${missing_artifacts[*]}"
        return 1
    fi
}

prepare_output_directory() {
    local output_parent
    local source_input
    OUTPUT="$(realpath -m -- "$output_candidate")" || return 2
    [[ "$OUTPUT" != / && "$OUTPUT" != "$ROOT" ]] || {
        fail "unsafe output directory: $OUTPUT"
        return 2
    }
    output_parent="$(dirname -- "$OUTPUT")"
    [[ -d "$output_parent" && -w "$output_parent" ]] || {
        fail "output parent is missing or unwritable: $output_parent"
        return 2
    }

    validate_output_against_source "$TASK3_ROOT"
    validate_output_against_source "$ROOT/os/axvisor/configs"
    validate_output_against_source "$ROOT/os/axvisor/guests/rt-ipc"
    if [[ -n "${TASK123_ADDITIONAL_SOURCE_INPUTS:-}" ]]; then
        IFS=: read -r -a extra_sources <<< "$TASK123_ADDITIONAL_SOURCE_INPUTS"
        for source_input in "${extra_sources[@]}"; do
            validate_output_against_source "$source_input"
        done
    fi

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
    prepare_shared_artifact_cache

    RUNNER_LOG="$OUTPUT/runner.log"
    CONSOLE_LOG="$OUTPUT/console.log"
    MANIFEST="$OUTPUT/manifest.txt"
    AXVISOR_BIN="$OUTPUT/axvisor.bin"
    APP_GUEST_LOG="$OUTPUT/${app_guest}.log"
    local paths=(
        "$RUNNER_LOG" "$CONSOLE_LOG" "$MANIFEST" "$AXVISOR_BIN"
        "$OUTPUT/${app_guest}.log" "$OUTPUT/rtthread.log" "$OUTPUT/frames.csv"
        "$OUTPUT/summary.raw.json" "$OUTPUT/summary.json" "$OUTPUT/host-metrics.txt"
    )
    local i
    local j
    for ((i = 0; i < ${#paths[@]}; i++)); do
        paths[$i]="$(realpath -m -- "${paths[$i]}")"
        [[ "${paths[$i]}" == "$OUTPUT"/* ]] || return 2
        for ((j = 0; j < i; j++)); do
            [[ "${paths[$i]}" != "${paths[$j]}" ]] || {
                fail "output paths collide: ${paths[$i]}"
                return 2
            }
        done
    done
    : > "$RUNNER_LOG"
    : > "$CONSOLE_LOG"
}

watcher_pid=
feeder_pid=
resource_sampler_pid=
qemu_pid=
raw_qemu_exit=
termination_reason=
normalized_qemu_exit=
RUNTIME_DIR=
LINUX_RUNTIME_DIR=
STARRYOS_RUNTIME_DIR=
RTTHREAD_RUNTIME_DIR=
APP_GUEST_IMAGE=
APP_GUEST_VMCONFIG=
APP_GUEST_RUNTIME_DIR=
APP_GUEST_LOG=
APP_GUEST_SMP_MARKER=
APP_GUEST_NET_MARKER=
APP_GUEST_TASK2_END_MARKER=
APP_GUEST_TASK3_END_MARKER=
APP_GUEST_TASK123_END_MARKER=
APP_GUEST_FAILURE_MARKER=
HOST_METRICS=
SHARED_ARTIFACT_DIR="${TASK123_SHARED_ARTIFACT_DIR:-}"
RESULT_GATE_STATUS=PASS
serial_fd_open=0

terminate_owned_pid() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup_owned_processes() {
    terminate_owned_pid "$feeder_pid"
    feeder_pid=
    terminate_owned_pid "$resource_sampler_pid"
    resource_sampler_pid=
    terminate_owned_pid "$watcher_pid"
    watcher_pid=
    if [[ "$serial_fd_open" -eq 1 ]]; then
        exec 3>&-
        serial_fd_open=0
    fi
}

remove_runtime_directory() {
    local directory=$1
    [[ -n "$directory" && "$directory" == "$ROOT/tmp/"* ]] || return 0
    rm -rf -- "$directory"
}

cleanup_runtime() {
    remove_runtime_directory "$LINUX_RUNTIME_DIR"
    remove_runtime_directory "$STARRYOS_RUNTIME_DIR"
    remove_runtime_directory "$RTTHREAD_RUNTIME_DIR"
    remove_runtime_directory "$RUNTIME_DIR"
}

cleanup() {
    cleanup_owned_processes
    cleanup_runtime
}

handle_signal() {
    local status=$1
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}

progress() {
    printf '%s\n' "$*" >&6
    printf '%s\n' "$*" >&4
}

phase() {
    progress "PHASE $1"
}

run_timed() {
    local timeout_s=$1
    local phase_name=$2
    local phase_rc
    shift 2

    progress "STEP $phase_name timeout_s=$timeout_s"
    if timeout --signal TERM --kill-after 5s \
        "$timeout_s" "$@"; then
        return 0
    else
        phase_rc=$?
    fi
    if [[ "$phase_rc" -eq 124 || "$phase_rc" -eq 137 || "$phase_rc" -eq 143 ]]; then
        echo "task123 runner: $phase_name timed out after ${timeout_s}s" >&2
    fi
    return "$phase_rc"
}

configure_app_guest_markers() {
    if [[ "$app_guest" == linux ]]; then
        APP_GUEST_SMP_MARKER='LINUX_SMP_READY configured=2'
        APP_GUEST_NET_MARKER='TASK123_LINUX_NET_READY'
        APP_GUEST_TASK2_END_MARKER='TASK2_LINUX_END status=PASS'
        APP_GUEST_TASK3_END_MARKER='TASK3_LINUX_END status=PASS'
        APP_GUEST_TASK123_END_MARKER='TASK123_LINUX_END status=PASS'
        APP_GUEST_FAILURE_MARKER='TASK123_LINUX_END status=FAIL'
    else
        APP_GUEST_SMP_MARKER='STARRY_SMP_READY configured=2'
        APP_GUEST_NET_MARKER='STARRY_NET_READY'
        APP_GUEST_TASK2_END_MARKER='TASK2_STARRY_END status=PASS'
        APP_GUEST_TASK3_END_MARKER='TASK3_STARRY_END status=PASS'
        APP_GUEST_TASK123_END_MARKER='TASK123_STARRY_END status=PASS'
        APP_GUEST_FAILURE_MARKER='TASK123_STARRY_END status=FAIL'
    fi
}

resolve_dependencies() {
    phase dependency-check
    local command_name
    for command_name in realpath sha256sum awk sed grep find mktemp cp chmod cmp date python3 timeout tee; do
        command -v "$command_name" >/dev/null || fail "required command not found: $command_name"
    done
    RUN_UNTIL="$(canonical_tool run-until "$RUN_UNTIL")"
    QEMU_REALTIME_CONTROL="$(canonical_tool realtime-control "$QEMU_REALTIME_CONTROL")"
    QEMU_RESOURCE_SAMPLER="$(canonical_tool qemu-resource-sampler "$QEMU_RESOURCE_SAMPLER")"
    if [[ "$app_guest" == linux ]]; then
        LINUX_VMCONFIG_GENERATOR="$(canonical_tool linux-vmconfig-generator "$LINUX_VMCONFIG_GENERATOR")"
    else
        STARRYOS_VMCONFIG_GENERATOR="$(canonical_tool starryos-vmconfig-generator "$STARRYOS_VMCONFIG_GENERATOR")"
        STARRYOS_BUILDER="$(canonical_tool starryos-builder "$STARRYOS_BUILDER")"
    fi
    RTTHREAD_VMCONFIG_GENERATOR="$(canonical_tool rtthread-vmconfig-generator "$RTTHREAD_VMCONFIG_GENERATOR")"
    RESULT_GATE="$(canonical_tool result-gate "$RESULT_GATE")"
    QEMU="$(canonical_tool qemu "${QEMU:-qemu-system-aarch64}")"
    CARGO="$(canonical_tool cargo "${CARGO:-cargo}")"
    AARCH64_STRIP="$(canonical_tool strip "${AARCH64_STRIP:-aarch64-linux-gnu-strip}")"
    AARCH64_OBJCOPY="$(canonical_tool objcopy "${AARCH64_OBJCOPY:-aarch64-linux-gnu-objcopy}")"
    PROTOCOL_SOURCE="$(canonical_existing_file protocol-source "$PROTOCOL_SOURCE")"
    PROTOCOL_HEADER="$(canonical_existing_file protocol-header "$PROTOCOL_HEADER")"
}

resolve_rootfs_image() {
    if [[ -n "${ROOTFS_IMAGE:-}" ]]; then
        ROOTFS_IMAGE="$(canonical_existing_file rootfs "$ROOTFS_IMAGE")"
        return
    fi

    local rootfs_dir="$RUNTIME_DIR/rootfs"
    local rootfs_candidates=()
    run_timed "$TASK123_BUILD_TIMEOUT_S" image-pull \
        "$CARGO" xtask image pull qemu-aarch64 -o "$rootfs_dir"
    mapfile -t rootfs_candidates < <(find "$rootfs_dir" -type f -name rootfs.img -print)
    [[ "${#rootfs_candidates[@]}" -eq 1 ]] || {
        fail "image pull must produce exactly one rootfs.img (found ${#rootfs_candidates[@]})"
        return 1
    }
    ROOTFS_IMAGE="$(canonical_existing_file rootfs "${rootfs_candidates[0]}")"
}

build_linux_images_if_needed() {
    if [[ -n "${LINUX_KERNEL_IMAGE:-}" && -n "${LINUX_INITRAMFS_IMAGE:-}" ]]; then
        return
    fi
    local build_root="$RUNTIME_DIR/task3-linux-build"
    run_timed "$TASK123_BUILD_TIMEOUT_S" linux-image-build \
        env BUILD_DIR="$build_root" "$TASK3_ROOT/scripts/build_linux.sh"
    LINUX_KERNEL_IMAGE="$build_root/images/linux/Image"
    LINUX_INITRAMFS_IMAGE="$build_root/images/linux/rootfs.cpio"
    TASK123_MODEL_IMAGE="${TASK123_MODEL_IMAGE:-$build_root/model/model_weights.h}"
}

build_starryos_image_if_needed() {
    if [[ -n "${STARRYOS_IMAGE:-}" ]]; then
        return
    fi
    [[ -n "${LINUX_INITRAMFS_IMAGE:-}" ]] || {
        fail "StarryOS build requires the Linux Task123 initramfs as its application source"
        return 1
    }
    run_timed "$TASK123_BUILD_TIMEOUT_S" starryos-image-build \
        env TASK123_LINUX_ROOTFS="$LINUX_INITRAMFS_IMAGE" \
        "$STARRYOS_BUILDER" --source-cpio "$LINUX_INITRAMFS_IMAGE"
    STARRYOS_IMAGE="$ROOT/target/aarch64-unknown-none-softfloat/release/starryos-task123.bin"
}

build_rtthread_variant() {
    local source_tree=$1
    local output=$2
    local drop_status=$3
    local delay_ms=$4
    local bsp="$source_tree/bsp/qemu-virt64-aarch64"
    run_timed "$TASK123_BUILD_TIMEOUT_S" rtthread-clean \
        env TASK3_FAULT_DROP_STATUS_ONCE="$drop_status" \
        TASK3_FAULT_DELAY_START_MS="$delay_ms" \
        uv run --with scons scons -C "$bsp" -c
    run_timed "$TASK123_BUILD_TIMEOUT_S" rtthread-build \
        env TASK3_FAULT_DROP_STATUS_ONCE="$drop_status" \
        TASK3_FAULT_DELAY_START_MS="$delay_ms" \
        uv run --with scons scons -C "$bsp" -j"$(getconf _NPROCESSORS_ONLN)"
    cp -- "$bsp/rtthread.bin" "$output"
}

build_rtthread_images_if_needed() {
    if [[ -n "${RTTHREAD_NORMAL_IMAGE:-}" &&
          -n "${RTTHREAD_DROP_STATUS_IMAGE:-}" &&
          -n "${RTTHREAD_DELAYED_SERVER_IMAGE:-}" ]]; then
        return
    fi
    command -v uv >/dev/null || fail "uv is required to build RT-Thread images"
    local source_tree="$RUNTIME_DIR/rtthread-source"
    local image_dir="$RUNTIME_DIR/rtthread-images"
    mkdir -- "$image_dir"
    run_timed "$TASK123_PHASE_TIMEOUT_S" prepare-rtthread-source \
        "$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh" "$source_tree"
    run_timed "$TASK123_PHASE_TIMEOUT_S" apply-rtthread-patches \
        "$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh" "$source_tree"
    RTTHREAD_NORMAL_IMAGE="$image_dir/rtthread-normal.bin"
    RTTHREAD_DROP_STATUS_IMAGE="$image_dir/rtthread-drop-status.bin"
    RTTHREAD_DELAYED_SERVER_IMAGE="$image_dir/rtthread-delayed-server.bin"
    build_rtthread_variant "$source_tree" "$RTTHREAD_NORMAL_IMAGE" 0 0
    build_rtthread_variant "$source_tree" "$RTTHREAD_DROP_STATUS_IMAGE" 1 0
    build_rtthread_variant "$source_tree" "$RTTHREAD_DELAYED_SERVER_IMAGE" 0 3000
}

resolve_or_build_images() {
    phase build-select-images
    resolve_input_artifact LINUX_KERNEL_IMAGE linux-kernel linux-kernel
    resolve_input_artifact LINUX_INITRAMFS_IMAGE linux-initramfs linux-initramfs.cpio
    resolve_input_artifact STARRYOS_IMAGE starryos-image starryos-task123.bin
    resolve_input_artifact RTTHREAD_NORMAL_IMAGE rtthread-normal rtthread-normal.bin
    resolve_input_artifact RTTHREAD_DROP_STATUS_IMAGE rtthread-drop-status rtthread-drop-status.bin
    resolve_input_artifact RTTHREAD_DELAYED_SERVER_IMAGE rtthread-delayed-server rtthread-delayed-server.bin
    resolve_input_artifact ROOTFS_IMAGE rootfs rootfs.img
    resolve_input_artifact TASK123_MODEL_IMAGE model model_weights.h
    resolve_legacy_model_fallback
    check_no_network_artifacts || return $?
    if [[ "$app_guest" == linux ]]; then
        build_linux_images_if_needed
    elif [[ -z "${STARRYOS_IMAGE:-}" ]]; then
        build_linux_images_if_needed
    fi
    build_rtthread_images_if_needed
    if [[ "$app_guest" == linux ]]; then
        LINUX_KERNEL_IMAGE="$(canonical_existing_file linux-kernel "$LINUX_KERNEL_IMAGE")"
        LINUX_INITRAMFS_IMAGE="$(canonical_existing_file linux-initramfs "$LINUX_INITRAMFS_IMAGE")"
        APP_GUEST_IMAGE="$LINUX_KERNEL_IMAGE"
    else
        build_starryos_image_if_needed
        STARRYOS_IMAGE="$(canonical_existing_file starryos-image "$STARRYOS_IMAGE")"
        APP_GUEST_IMAGE="$STARRYOS_IMAGE"
    fi
    RTTHREAD_NORMAL_IMAGE="$(canonical_existing_file rtthread-normal "$RTTHREAD_NORMAL_IMAGE")"
    RTTHREAD_DROP_STATUS_IMAGE="$(canonical_existing_file rtthread-drop-status "$RTTHREAD_DROP_STATUS_IMAGE")"
    RTTHREAD_DELAYED_SERVER_IMAGE="$(canonical_existing_file rtthread-delayed-server "$RTTHREAD_DELAYED_SERVER_IMAGE")"
    resolve_rootfs_image

    if [[ -z "${TASK123_MODEL_IMAGE:-}" ]]; then
        if [[ -f "$TASK3_ROOT/build/model/model_weights.h" ]]; then
            TASK123_MODEL_IMAGE="$TASK3_ROOT/build/model/model_weights.h"
        else
            local model_build="$RUNTIME_DIR/task3-model-build"
            run_timed "$TASK123_BUILD_TIMEOUT_S" model-build \
                env BUILD_DIR="$model_build" "$TASK3_ROOT/scripts/build_model.sh"
            TASK123_MODEL_IMAGE="$model_build/model/model_weights.h"
        fi
    fi
    TASK123_MODEL_IMAGE="$(canonical_existing_file model "$TASK123_MODEL_IMAGE")"

    if [[ -n "${LINUX_KERNEL_IMAGE:-}" ]]; then
        LINUX_KERNEL_IMAGE="$(stage_shared_artifact linux-kernel linux-kernel "$LINUX_KERNEL_IMAGE")"
    fi
    if [[ -n "${LINUX_INITRAMFS_IMAGE:-}" ]]; then
        LINUX_INITRAMFS_IMAGE="$(stage_shared_artifact linux-initramfs linux-initramfs.cpio "$LINUX_INITRAMFS_IMAGE")"
    fi
    if [[ -n "${STARRYOS_IMAGE:-}" ]]; then
        STARRYOS_IMAGE="$(stage_shared_artifact starryos-image starryos-task123.bin "$STARRYOS_IMAGE")"
    fi
    RTTHREAD_NORMAL_IMAGE="$(stage_shared_artifact rtthread-normal rtthread-normal.bin "$RTTHREAD_NORMAL_IMAGE")"
    RTTHREAD_DROP_STATUS_IMAGE="$(stage_shared_artifact rtthread-drop-status rtthread-drop-status.bin "$RTTHREAD_DROP_STATUS_IMAGE")"
    RTTHREAD_DELAYED_SERVER_IMAGE="$(stage_shared_artifact rtthread-delayed-server rtthread-delayed-server.bin "$RTTHREAD_DELAYED_SERVER_IMAGE")"
    ROOTFS_IMAGE="$(stage_shared_artifact rootfs rootfs.img "$ROOTFS_IMAGE")"
    TASK123_MODEL_IMAGE="$(stage_shared_artifact model model_weights.h "$TASK123_MODEL_IMAGE")"

    local source_input
    local source_inputs=(
        "$RTTHREAD_NORMAL_IMAGE"
        "$RTTHREAD_DROP_STATUS_IMAGE"
        "$RTTHREAD_DELAYED_SERVER_IMAGE"
        "$ROOTFS_IMAGE"
        "$TASK123_MODEL_IMAGE"
        "$APP_GUEST_IMAGE"
    )
    if [[ "$app_guest" == linux ]]; then
        source_inputs+=("$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS_IMAGE")
    elif [[ -n "${LINUX_INITRAMFS_IMAGE:-}" ]]; then
        source_inputs+=("$LINUX_INITRAMFS_IMAGE")
    fi
    for source_input in "${source_inputs[@]}"; do
        validate_output_against_source "$source_input"
    done

    SELECTED_RTTHREAD_IMAGE=$RTTHREAD_NORMAL_IMAGE
    if [[ "$mode" == task3-fault && "$task3_fault" == drop-status ]]; then
        SELECTED_RTTHREAD_IMAGE=$RTTHREAD_DROP_STATUS_IMAGE
    elif [[ "$mode" == task3-fault && "$task3_fault" == delayed-server ]]; then
        SELECTED_RTTHREAD_IMAGE=$RTTHREAD_DELAYED_SERVER_IMAGE
    fi
}

generate_vmconfigs() {
    phase immutable-runtime-vmconfigs
    APP_GUEST_RUNTIME_DIR=
    if [[ "$app_guest" == linux ]]; then
        LINUX_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtipc-runtime.XXXXXX")"
        APP_GUEST_RUNTIME_DIR="$LINUX_RUNTIME_DIR"
    else
        STARRYOS_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/starryos-runtime.XXXXXX")"
        APP_GUEST_RUNTIME_DIR="$STARRYOS_RUNTIME_DIR"
    fi
    RTTHREAD_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtthread-runtime.XXXXXX")"
    local guest_fault=${task3_fault:-normal}
    local guest_cmdline
    if [[ "$app_guest" == linux ]]; then
        guest_cmdline="console=ttyAMA0 rdinit=/init task2.count=$task2_count task2.fault=none task3.frames=$task3_frames task3.fault=$guest_fault"
        LINUX_VMCONFIG="$(
            run_timed "$TASK123_PHASE_TIMEOUT_S" linux-vmconfig-generator \
                "$LINUX_VMCONFIG_GENERATOR" "$ROOT" "$LINUX_VMCONFIG_TEMPLATE" \
                "$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS_IMAGE" \
                "$LINUX_RUNTIME_DIR" "$guest_cmdline"
        )"
        APP_GUEST_VMCONFIG="$LINUX_VMCONFIG"
    else
        guest_cmdline="task2.count=$task2_count task2.fault=none task3.frames=$task3_frames task3.fault=$guest_fault"
        STARRYOS_VMCONFIG="$(
            run_timed "$TASK123_PHASE_TIMEOUT_S" starryos-vmconfig-generator \
                "$STARRYOS_VMCONFIG_GENERATOR" "$ROOT" "$STARRYOS_VMCONFIG_TEMPLATE" \
                "$STARRYOS_IMAGE" "$STARRYOS_RUNTIME_DIR" "$guest_cmdline"
        )"
        APP_GUEST_VMCONFIG="$STARRYOS_VMCONFIG"
    fi
    RTTHREAD_VMCONFIG="$(
        run_timed "$TASK123_PHASE_TIMEOUT_S" rtthread-vmconfig-generator \
            "$RTTHREAD_VMCONFIG_GENERATOR" "$ROOT" "$RTTHREAD_VMCONFIG_TEMPLATE" \
            "$SELECTED_RTTHREAD_IMAGE" "$RTTHREAD_RUNTIME_DIR"
    )"
    chmod a-w -- "$APP_GUEST_VMCONFIG" "$RTTHREAD_VMCONFIG"
}

build_axvisor() {
    phase cargo-xtask-axvisor-build
    export CARGO_TARGET_DIR="$RUNTIME_DIR/cargo-target"
    local build_evidence="$RUNTIME_DIR/axbuild-output.log"
    run_timed "$TASK123_BUILD_TIMEOUT_S" cargo-xtask-axvisor-build \
        "$CARGO" xtask axvisor build --config qemu-aarch64-two-guest-net \
        --smp 4 \
        --vmconfigs "$APP_GUEST_VMCONFIG" \
        --vmconfigs "$RTTHREAD_VMCONFIG" 2>&1 | tee "$build_evidence"
    local axvisor_artifacts=()
    mapfile -t axvisor_artifacts < <(
        sed -n 's/^\[axbuild\] cargo build elf=//p' "$build_evidence"
    )
    [[ "${#axvisor_artifacts[@]}" -eq 1 ]] || {
        fail "AxVisor build must report exactly one ELF artifact (found ${#axvisor_artifacts[@]})"
        return 1
    }
    local axvisor_elf="${axvisor_artifacts[0]}"
    axvisor_elf="$(canonical_existing_file axvisor-elf "$axvisor_elf")"

    phase strip-objcopy
    local stripped="$RUNTIME_DIR/axvisor.stripped"
    run_timed "$TASK123_BUILD_TIMEOUT_S" strip \
        "$AARCH64_STRIP" -o "$stripped" "$axvisor_elf"
    run_timed "$TASK123_BUILD_TIMEOUT_S" objcopy \
        "$AARCH64_OBJCOPY" -O binary "$stripped" "$AXVISOR_BIN"
    [[ -s "$AXVISOR_BIN" ]] || fail "AxVisor binary conversion produced no output"
}

record_artifact() {
    local label=$1
    local path=$2
    local resolved
    local digest
    resolved="$(canonical_existing_file "$label" "$path")"
    digest="$(run_timed "$TASK123_PHASE_TIMEOUT_S" artifact-digest sha256sum "$resolved")"
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid digest for $label"
    printf 'ARTIFACT name=%s path=%s sha256=%s\n' "$label" "$resolved" "$digest" >> "$MANIFEST_TMP"
}

prepare_manifest() {
    MANIFEST_TMP="$OUTPUT/.manifest.txt.tmp"
    : > "$MANIFEST_TMP"
    printf 'schema=1\napp_guest=%s\nmode=%s\ntask2_count=%s\ntask3_frames=%s\ntask3_fault=%s\nqemu_timer_slack_ns=%s\n' \
        "$app_guest" "$mode" "$task2_count" "$task3_frames" "${task3_fault:-normal}" \
        "$QEMU_TIMER_SLACK_NS" >> "$MANIFEST_TMP"
    record_artifact qemu "$QEMU"
    record_artifact axvisor "$AXVISOR_BIN"
    if [[ "$app_guest" == linux ]]; then
        record_artifact linux-kernel "$LINUX_KERNEL_IMAGE"
        record_artifact linux-initramfs "$LINUX_INITRAMFS_IMAGE"
        record_artifact linux-vmconfig "$APP_GUEST_VMCONFIG"
    else
        if [[ -n "${LINUX_KERNEL_IMAGE:-}" ]]; then
            record_artifact linux-kernel "$LINUX_KERNEL_IMAGE"
        fi
        if [[ -n "${LINUX_INITRAMFS_IMAGE:-}" ]]; then
            record_artifact linux-initramfs "$LINUX_INITRAMFS_IMAGE"
        fi
        record_artifact starryos "$STARRYOS_IMAGE"
        record_artifact starryos-vmconfig "$APP_GUEST_VMCONFIG"
    fi
    record_artifact rtthread "$SELECTED_RTTHREAD_IMAGE"
    record_artifact rtthread-normal "$RTTHREAD_NORMAL_IMAGE"
    record_artifact rtthread-drop-status "$RTTHREAD_DROP_STATUS_IMAGE"
    record_artifact rtthread-delayed-server "$RTTHREAD_DELAYED_SERVER_IMAGE"
    record_artifact rtthread-vmconfig "$RTTHREAD_VMCONFIG"
    record_artifact model "$TASK123_MODEL_IMAGE"
    record_artifact protocol-source "$PROTOCOL_SOURCE"
    record_artifact protocol-header "$PROTOCOL_HEADER"
    record_artifact rootfs "$ROOTFS_IMAGE"
}

wait_for_console_marker() {
    local marker=$1
    local deadline=$(( $(date +%s) + TASK123_TIMEOUT_S ))

    while :; do
        grep -aFq -- "$marker" "$CONSOLE_LOG" && return 0
        kill -0 "$watcher_pid" 2>/dev/null || return 1
        [[ "$(date +%s)" -lt "$deadline" ]] || return 124
        sleep 0.05
    done
}

feed_benchmark_command() {
    local ready='[VM 3] msh />'
    local command=
    wait_for_console_marker "$ready"
    printf '\030]' >&3
    sleep 0.1
    if [[ "$mode" == realtime-suite ]]; then
        command="benchmark $rtbench_samples"
        ready='RTBENCH_END status=PASS'
    else
        command="rtbench_stability $stability_seconds"
        ready='RTBENCH_STABILITY_DONE'
    fi
    printf '%s\r' "$command" >&3
    # Keep Linux in the foreground until it emits its final evidence. Stopped
    # guests are removed from the mux together with any buffered output.
    printf '\030[' >&3
    if ! wait_for_console_marker "$APP_GUEST_TASK123_END_MARKER"; then
        return 1
    fi
    # Replay VM 3's benchmark output and final counters.
    printf '\030]' >&3
    if ! wait_for_console_marker "$ready"; then
        return 1
    fi
    wait_for_console_marker 'TASK3_RTOS_FINAL requests='
}

wait_for_qemu_pid() {
    local pid_file=$1
    local deadline=$(( $(date +%s) + 5 ))
    while [[ ! -s "$pid_file" ]]; do
        kill -0 "$watcher_pid" 2>/dev/null || return 1
        [[ "$(date +%s)" -lt "$deadline" ]] || return 1
        sleep 0.01
    done
    qemu_pid="$(<"$pid_file")"
    require_integer "$qemu_pid" 1 2147483647 qemu-pid
    kill -0 "$qemu_pid" 2>/dev/null || fail "recorded QEMU PID is not running: $qemu_pid"
}

read_qemu_completion() {
    local watcher_rc=$1
    local status_file=$2
    local reason_file=$3

    [[ -s "$status_file" && -s "$reason_file" ]] || {
        fail "run-until did not publish QEMU completion evidence"
        return 1
    }
    raw_qemu_exit="$(<"$status_file")"
    termination_reason="$(<"$reason_file")"
    require_integer "$raw_qemu_exit" 0 255 raw-qemu-exit
    case "$termination_reason" in
        marker-complete)
            case "$raw_qemu_exit" in
                0|137|143) normalized_qemu_exit=0 ;;
                *) normalized_qemu_exit=$raw_qemu_exit ;;
            esac
            ;;
        child-exit)
            normalized_qemu_exit=$raw_qemu_exit
            ;;
        timeout)
            normalized_qemu_exit=124
            ;;
        failure-marker)
            normalized_qemu_exit=1
            ;;
        signal)
            normalized_qemu_exit=$watcher_rc
            ;;
        *)
            fail "invalid QEMU termination reason: $termination_reason"
            return 1
            ;;
    esac
    [[ "$watcher_rc" -eq "$normalized_qemu_exit" ]] || {
        fail "run-until status mismatch: returned=$watcher_rc normalized=$normalized_qemu_exit"
        return 1
    }
}

launch_one_qemu() {
    phase one-qemu
    local serial_fifo="$RUNTIME_DIR/serial.in"
    local qemu_pid_file="$RUNTIME_DIR/qemu.pid"
    local qemu_status_file="$RUNTIME_DIR/qemu.raw-status"
    local qemu_reason_file="$RUNTIME_DIR/qemu.termination-reason"
    mkfifo -- "$serial_fifo"
    exec 3<> "$serial_fifo"
    serial_fd_open=1

    local markers=(
        "$APP_GUEST_SMP_MARKER"
        "$APP_GUEST_NET_MARKER"
        'RTIPC_SERVER_READY ip=192.168.77.30 port=9876'
        'TASK3_RTOS_READY ip=192.168.77.30 port=9877'
        "$APP_GUEST_TASK2_END_MARKER"
        "$APP_GUEST_TASK3_END_MARKER"
        "$APP_GUEST_TASK123_END_MARKER"
        'TASK3_RTOS_FINAL requests='
    )
    local failure_markers=("$APP_GUEST_FAILURE_MARKER")
    if [[ "$mode" == realtime-suite ]]; then
        markers+=('RTBENCH_END status=PASS')
        failure_markers+=('RTBENCH_END status=FAIL')
    elif [[ "$mode" == stability ]]; then
        if [[ "${TASK123_ALLOW_QEMU_TIMER_LIMIT:-0}" -eq 1 ]]; then
            markers+=('RTBENCH_STABILITY_DONE')
        else
            markers+=('RTBENCH_STABILITY_END status=PASS')
            failure_markers+=('RTBENCH_STABILITY_END status=FAIL')
        fi
    fi
    local failure_marker_args=()
    local failure_marker
    for failure_marker in "${failure_markers[@]}"; do
        failure_marker_args+=(--failure-marker "$failure_marker")
    done

    local qemu_args=(
        -display none
        -monitor none
        -snapshot
        -cpu cortex-a72
        -machine virt,virtualization=on,gic-version=3
        -global virtio-mmio.force-legacy=false
        -smp 4
        -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65
        -drive "id=disk0,if=none,format=raw,file=$ROOTFS_IMAGE"
        # This is the AxVisor host cmdline; Linux workload controls live only in its VM config.
        -append 'root=/dev/nvme0n1 rw init=/bin/sh'
        -m 8g
        -netdev hubport,id=net0,hubid=77
        -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01
        -netdev hubport,id=net2,hubid=77
        -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03
        -serial stdio
        -no-reboot
        -kernel "$AXVISOR_BIN"
    )

    RUN_UNTIL_CHILD_PID_FILE="$qemu_pid_file" \
    RUN_UNTIL_CHILD_STATUS_FILE="$qemu_status_file" \
    RUN_UNTIL_TERMINATION_REASON_FILE="$qemu_reason_file" \
    RUN_UNTIL_CHILD_TIMERSLACK_NS="$QEMU_TIMER_SLACK_NS" \
        "$RUN_UNTIL" "$TASK123_TIMEOUT_S" "$CONSOLE_LOG" "${markers[@]}" \
        "${failure_marker_args[@]}" -- \
        "$QEMU" "${qemu_args[@]}" <&3 >> "$CONSOLE_LOG" 2>&1 &
    watcher_pid=$!
    wait_for_qemu_pid "$qemu_pid_file"

    HOST_METRICS="$OUTPUT/host-metrics.txt"
    "$QEMU_RESOURCE_SAMPLER" "$qemu_pid" "$HOST_METRICS" \
        "${QEMU_RESOURCE_SAMPLE_INTERVAL_MS:-100}" &
    resource_sampler_pid=$!

    phase apply-qemu-realtime-controls
    run_timed "$TASK123_PHASE_TIMEOUT_S" apply-qemu-realtime-controls \
        "$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN"
    if [[ "$mode" == realtime-suite || "$mode" == stability ]]; then
        feed_benchmark_command &
        feeder_pid=$!
    fi

    phase marker-collection
    local watcher_rc=0
    if wait "$watcher_pid"; then
        watcher_rc=0
    else
        watcher_rc=$?
    fi
    watcher_pid=
    local resource_sampler_rc=0
    if wait "$resource_sampler_pid"; then
        resource_sampler_rc=0
    else
        resource_sampler_rc=$?
    fi
    resource_sampler_pid=
    local feeder_rc=0
    if [[ -n "$feeder_pid" ]]; then
        if wait "$feeder_pid"; then
            feeder_rc=0
        else
            feeder_rc=$?
        fi
        feeder_pid=
    fi
    exec 3>&-
    serial_fd_open=0
    read_qemu_completion "$watcher_rc" "$qemu_status_file" "$qemu_reason_file"
    [[ "$normalized_qemu_exit" -eq 0 ]] || {
        fail "unexpected QEMU exit code $raw_qemu_exit (reason=$termination_reason)"
        return 1
    }
    if [[ "$feeder_rc" -ne 0 ]]; then
        fail "benchmark command reported failure (see $CONSOLE_LOG)"
        return "$feeder_rc"
    fi
    [[ "$resource_sampler_rc" -eq 0 && -s "$HOST_METRICS" ]] || {
        fail "QEMU resource sampler did not produce host metrics"
        return 1
    }
}

run_result_gate() {
    phase result-gate
    local arguments=(
        --mode "$mode"
        --app-guest "$app_guest"
        --log "$CONSOLE_LOG"
        --output "$OUTPUT"
        --task2-count "$task2_count"
        --task3-frames "$task3_frames"
        --qemu-exit "$normalized_qemu_exit"
    )
    if [[ "$mode" == realtime-suite ]]; then
        arguments+=(--rtbench-samples "$rtbench_samples")
    elif [[ "$mode" == stability ]]; then
        arguments+=(--seconds "$stability_seconds")
    elif [[ "$mode" == task3-fault ]]; then
        arguments+=(--task3-fault "$task3_fault")
    fi
    RESULT_GATE_STATUS=PASS
    if [[ "$mode" == stability && "${TASK123_ALLOW_QEMU_TIMER_LIMIT:-0}" -eq 1 ]]; then
        arguments+=(--allow-qemu-timer-limit)
        RESULT_GATE_STATUS=PASS_WITH_QEMU_TIMER_LIMIT
    fi
    run_timed "$TASK123_PHASE_TIMEOUT_S" result-gate \
        "$RESULT_GATE" "${arguments[@]}"
}

publish_manifest() {
    phase manifest
    printf 'raw_qemu_exit=%s\ntermination_reason=%s\nqemu_exit=%s\nresult_gate=%s\n' \
        "$raw_qemu_exit" "$termination_reason" "$normalized_qemu_exit" "$RESULT_GATE_STATUS" >> "$MANIFEST_TMP"
    mv -- "$MANIFEST_TMP" "$MANIFEST"
}

main() {
    parse_arguments "$@"
    validate_mode_options
    prepare_output_directory
    exec 4>&1 5>&2 6>> "$RUNNER_LOG"
    exec >> "$RUNNER_LOG" 2>&1
    cd "$ROOT"

    TASK123_TIMEOUT_S=${TASK123_TIMEOUT_S:-600}
    TASK123_BUILD_TIMEOUT_S=${TASK123_BUILD_TIMEOUT_S:-1800}
    TASK123_PHASE_TIMEOUT_S=${TASK123_PHASE_TIMEOUT_S:-600}
    QEMU_UCLAMP_MIN=${QEMU_UCLAMP_MIN:-1024}
    QEMU_TIMER_SLACK_NS=${QEMU_TIMER_SLACK_NS:-1}
    configure_app_guest_markers
    mkdir -p -- "$ROOT/tmp"
    RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/task123-runtime.XXXXXX")"
    trap cleanup EXIT
    trap 'handle_signal 129' HUP
    trap 'handle_signal 130' INT
    trap 'handle_signal 143' TERM

    resolve_dependencies
    resolve_or_build_images
    generate_vmconfigs
    build_axvisor
    prepare_manifest
    launch_one_qemu
    phase scoped-cleanup
    cleanup_owned_processes
    run_result_gate
    publish_manifest
    printf 'Task 1/2/3 run complete: %s\n' "$OUTPUT" >&4
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
