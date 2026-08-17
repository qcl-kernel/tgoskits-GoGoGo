#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
TASK3_ROOT="$ROOT/os/axvisor/guests/task3"
RUN_UNTIL="${RUN_UNTIL:-$SCRIPT_DIR/run_until_log_marker.sh}"
QEMU_REALTIME_CONTROL="${QEMU_REALTIME_CONTROL:-$SCRIPT_DIR/apply_qemu_realtime_controls.sh}"
LINUX_VMCONFIG_GENERATOR="${LINUX_VMCONFIG_GENERATOR:-$SCRIPT_DIR/generate_linux_vmconfig.sh}"
RTTHREAD_VMCONFIG_GENERATOR="${RTTHREAD_VMCONFIG_GENERATOR:-$SCRIPT_DIR/generate_rtthread_vmconfig.sh}"
RESULT_GATE="${RESULT_GATE:-$SCRIPT_DIR/verify_task123_results.sh}"
LINUX_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml"
RTTHREAD_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"
PROTOCOL_SOURCE="$ROOT/os/axvisor/guests/rt-ipc/common/rt_ipc.c"
PROTOCOL_HEADER="$ROOT/os/axvisor/guests/rt-ipc/common/rt_ipc.h"

usage() {
    cat >&2 <<EOF
usage:
  $0 --mode smoke [--task2-count N] [--task3-frames N] --output DIR
  $0 --mode realtime-suite [--rtbench-samples N] [--task2-count N] --output DIR
  $0 --mode stability [--seconds N] [--task2-count N] --output DIR
  $0 --mode task3 [--task3-frames N] --output DIR
  $0 --mode task3-fault --task3-fault PROFILE [--task3-frames N] --output DIR
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
output_candidate=
task2_count=
task3_frames=
rtbench_samples=
stability_seconds=
task3_fault=
seen_mode=0
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
            --mode|--output|--task2-count|--task3-frames|--rtbench-samples|--seconds|--task3-fault)
                [[ $# -ge 2 ]] || usage
                value=$2
                shift 2
                case "$option" in
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

    require_integer "$task2_count" 1 2147483647 task2-count
    require_integer "$task3_frames" 1 600 task3-frames
    if [[ "$mode" == realtime-suite ]]; then
        require_integer "$rtbench_samples" 1 100000 rtbench-samples
    elif [[ "$mode" == stability ]]; then
        require_integer "$stability_seconds" 1 3600 seconds
    fi
    require_integer "${TASK123_TIMEOUT_S:-600}" 1 86400 TASK123_TIMEOUT_S
    require_integer "${QEMU_UCLAMP_MIN:-1024}" 0 1024 QEMU_UCLAMP_MIN
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
    if [[ "$candidate" == */* ]]; then
        resolved="$(realpath -e -- "$candidate")" || return 1
    else
        resolved="$(command -v -- "$candidate")" || {
            fail "required command not found: $label=$candidate"
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

    RUNNER_LOG="$OUTPUT/runner.log"
    CONSOLE_LOG="$OUTPUT/console.log"
    MANIFEST="$OUTPUT/manifest.txt"
    AXVISOR_BIN="$OUTPUT/axvisor.bin"
    local paths=(
        "$RUNNER_LOG" "$CONSOLE_LOG" "$MANIFEST" "$AXVISOR_BIN"
        "$OUTPUT/linux.log" "$OUTPUT/rtthread.log" "$OUTPUT/frames.csv"
        "$OUTPUT/summary.raw.json" "$OUTPUT/summary.json"
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
qemu_pid=
RUNTIME_DIR=
LINUX_RUNTIME_DIR=
RTTHREAD_RUNTIME_DIR=
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

phase() {
    printf 'PHASE %s\n' "$1"
}

resolve_dependencies() {
    phase dependency-check
    local command_name
    for command_name in realpath sha256sum awk sed grep mktemp cp chmod date python3; do
        command -v "$command_name" >/dev/null || fail "required command not found: $command_name"
    done
    RUN_UNTIL="$(canonical_tool run-until "$RUN_UNTIL")"
    QEMU_REALTIME_CONTROL="$(canonical_tool realtime-control "$QEMU_REALTIME_CONTROL")"
    LINUX_VMCONFIG_GENERATOR="$(canonical_tool linux-vmconfig-generator "$LINUX_VMCONFIG_GENERATOR")"
    RTTHREAD_VMCONFIG_GENERATOR="$(canonical_tool rtthread-vmconfig-generator "$RTTHREAD_VMCONFIG_GENERATOR")"
    RESULT_GATE="$(canonical_tool result-gate "$RESULT_GATE")"
    QEMU="$(canonical_tool qemu "${QEMU:-qemu-system-aarch64}")"
    CARGO="$(canonical_tool cargo "${CARGO:-cargo}")"
    AARCH64_STRIP="$(canonical_tool strip "${AARCH64_STRIP:-aarch64-linux-gnu-strip}")"
    AARCH64_OBJCOPY="$(canonical_tool objcopy "${AARCH64_OBJCOPY:-aarch64-linux-gnu-objcopy}")"
    PROTOCOL_SOURCE="$(canonical_existing_file protocol-source "$PROTOCOL_SOURCE")"
    PROTOCOL_HEADER="$(canonical_existing_file protocol-header "$PROTOCOL_HEADER")"
}

build_linux_images_if_needed() {
    if [[ -n "${LINUX_KERNEL_IMAGE:-}" && -n "${LINUX_INITRAMFS_IMAGE:-}" ]]; then
        return
    fi
    local build_root="$RUNTIME_DIR/task3-linux-build"
    BUILD_DIR="$build_root" "$TASK3_ROOT/scripts/build_linux.sh"
    LINUX_KERNEL_IMAGE="$build_root/images/linux/Image"
    LINUX_INITRAMFS_IMAGE="$build_root/images/linux/rootfs.cpio"
    TASK123_MODEL_IMAGE="${TASK123_MODEL_IMAGE:-$build_root/model/model_weights.h}"
}

build_rtthread_variant() {
    local source_tree=$1
    local output=$2
    local drop_status=$3
    local delay_ms=$4
    local bsp="$source_tree/bsp/qemu-virt64-aarch64"
    env TASK3_FAULT_DROP_STATUS_ONCE="$drop_status" \
        TASK3_FAULT_DELAY_START_MS="$delay_ms" \
        uv run --with scons scons -C "$bsp" -c
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
    "$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh" "$source_tree"
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
    build_linux_images_if_needed
    build_rtthread_images_if_needed
    LINUX_KERNEL_IMAGE="$(canonical_existing_file linux-kernel "$LINUX_KERNEL_IMAGE")"
    LINUX_INITRAMFS_IMAGE="$(canonical_existing_file linux-initramfs "$LINUX_INITRAMFS_IMAGE")"
    RTTHREAD_NORMAL_IMAGE="$(canonical_existing_file rtthread-normal "$RTTHREAD_NORMAL_IMAGE")"
    RTTHREAD_DROP_STATUS_IMAGE="$(canonical_existing_file rtthread-drop-status "$RTTHREAD_DROP_STATUS_IMAGE")"
    RTTHREAD_DELAYED_SERVER_IMAGE="$(canonical_existing_file rtthread-delayed-server "$RTTHREAD_DELAYED_SERVER_IMAGE")"
    ROOTFS_IMAGE="$(canonical_existing_file rootfs "${ROOTFS_IMAGE:-$ROOT/tmp/vmconfigs/two-guest-net/current/rootfs.img}")"

    if [[ -z "${TASK123_MODEL_IMAGE:-}" ]]; then
        if [[ -f "$TASK3_ROOT/build/model/model_weights.h" ]]; then
            TASK123_MODEL_IMAGE="$TASK3_ROOT/build/model/model_weights.h"
        else
            local model_build="$RUNTIME_DIR/task3-model-build"
            BUILD_DIR="$model_build" "$TASK3_ROOT/scripts/build_model.sh"
            TASK123_MODEL_IMAGE="$model_build/model/model_weights.h"
        fi
    fi
    TASK123_MODEL_IMAGE="$(canonical_existing_file model "$TASK123_MODEL_IMAGE")"

    local source_input
    for source_input in \
        "$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS_IMAGE" "$RTTHREAD_NORMAL_IMAGE" \
        "$RTTHREAD_DROP_STATUS_IMAGE" "$RTTHREAD_DELAYED_SERVER_IMAGE" \
        "$ROOTFS_IMAGE" "$TASK123_MODEL_IMAGE"; do
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
    LINUX_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtipc-runtime.XXXXXX")"
    RTTHREAD_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtthread-runtime.XXXXXX")"
    local guest_fault=${task3_fault:-normal}
    local guest_cmdline
    guest_cmdline="console=ttyAMA0 rdinit=/init task2.count=$task2_count task2.fault=none task3.frames=$task3_frames task3.fault=$guest_fault"
    LINUX_VMCONFIG="$(
        "$LINUX_VMCONFIG_GENERATOR" "$ROOT" "$LINUX_VMCONFIG_TEMPLATE" \
            "$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS_IMAGE" \
            "$LINUX_RUNTIME_DIR" "$guest_cmdline"
    )"
    RTTHREAD_VMCONFIG="$(
        "$RTTHREAD_VMCONFIG_GENERATOR" "$ROOT" "$RTTHREAD_VMCONFIG_TEMPLATE" \
            "$SELECTED_RTTHREAD_IMAGE" "$RTTHREAD_RUNTIME_DIR"
    )"
    chmod a-w -- "$LINUX_VMCONFIG" "$RTTHREAD_VMCONFIG"
}

build_axvisor() {
    phase cargo-xtask-axvisor-build
    export CARGO_TARGET_DIR="$RUNTIME_DIR/cargo-target"
    "$CARGO" xtask axvisor build --config qemu-aarch64-two-guest-net \
        --vmconfigs "$LINUX_VMCONFIG" \
        --vmconfigs "$RTTHREAD_VMCONFIG"
    local axvisor_elf="$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/axvisor"
    axvisor_elf="$(canonical_existing_file axvisor-elf "$axvisor_elf")"

    phase strip-objcopy
    local stripped="$RUNTIME_DIR/axvisor.stripped"
    "$AARCH64_STRIP" -o "$stripped" "$axvisor_elf"
    "$AARCH64_OBJCOPY" -O binary "$stripped" "$AXVISOR_BIN"
    [[ -s "$AXVISOR_BIN" ]] || fail "AxVisor binary conversion produced no output"
}

record_artifact() {
    local label=$1
    local path=$2
    local resolved
    local digest
    resolved="$(canonical_existing_file "$label" "$path")"
    digest="$(sha256sum "$resolved")"
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid digest for $label"
    printf 'ARTIFACT name=%s path=%s sha256=%s\n' "$label" "$resolved" "$digest" >> "$MANIFEST_TMP"
}

prepare_manifest() {
    MANIFEST_TMP="$OUTPUT/.manifest.txt.tmp"
    : > "$MANIFEST_TMP"
    printf 'schema=1\nmode=%s\ntask2_count=%s\ntask3_frames=%s\ntask3_fault=%s\n' \
        "$mode" "$task2_count" "$task3_frames" "${task3_fault:-normal}" >> "$MANIFEST_TMP"
    record_artifact qemu "$QEMU"
    record_artifact axvisor "$AXVISOR_BIN"
    record_artifact linux-kernel "$LINUX_KERNEL_IMAGE"
    record_artifact linux-initramfs "$LINUX_INITRAMFS_IMAGE"
    record_artifact rtthread "$SELECTED_RTTHREAD_IMAGE"
    record_artifact rtthread-normal "$RTTHREAD_NORMAL_IMAGE"
    record_artifact rtthread-drop-status "$RTTHREAD_DROP_STATUS_IMAGE"
    record_artifact rtthread-delayed-server "$RTTHREAD_DELAYED_SERVER_IMAGE"
    record_artifact linux-vmconfig "$LINUX_VMCONFIG"
    record_artifact rtthread-vmconfig "$RTTHREAD_VMCONFIG"
    record_artifact model "$TASK123_MODEL_IMAGE"
    record_artifact protocol-source "$PROTOCOL_SOURCE"
    record_artifact protocol-header "$PROTOCOL_HEADER"
    record_artifact rootfs "$ROOTFS_IMAGE"
}

feed_benchmark_command() {
    local ready='[VM 3] msh />'
    local deadline=$(( $(date +%s) + TASK123_TIMEOUT_S ))
    while ! grep -aFq -- "$ready" "$CONSOLE_LOG"; do
        kill -0 "$watcher_pid" 2>/dev/null || return 1
        [[ "$(date +%s)" -lt "$deadline" ]] || return 124
        sleep 0.05
    done
    printf '\030]' >&3
    sleep 0.1
    if [[ "$mode" == realtime-suite ]]; then
        printf 'benchmark %s\r' "$rtbench_samples" >&3
    else
        printf 'rtbench_stability %s\r' "$stability_seconds" >&3
    fi
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

launch_one_qemu() {
    phase one-qemu
    local serial_fifo="$RUNTIME_DIR/serial.in"
    local qemu_pid_file="$RUNTIME_DIR/qemu.pid"
    mkfifo -- "$serial_fifo"
    exec 3<> "$serial_fifo"
    serial_fd_open=1

    local markers=(
        'LINUX_SMP_READY configured=2'
        'TASK123_LINUX_NET_READY'
        'RTIPC_SERVER_READY ip=192.168.77.30 port=9876'
        'TASK3_RTOS_READY ip=192.168.77.30 port=9877'
        'TASK2_LINUX_END status=PASS'
        'TASK3_LINUX_END status=PASS'
        'TASK123_LINUX_END status=PASS'
    )
    if [[ "$mode" == realtime-suite ]]; then
        markers+=('RTBENCH_END status=PASS')
    elif [[ "$mode" == stability ]]; then
        markers+=('RTBENCH_STABILITY_END status=PASS')
    fi

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
        "$RUN_UNTIL" "$TASK123_TIMEOUT_S" "$CONSOLE_LOG" "${markers[@]}" -- \
        "$QEMU" "${qemu_args[@]}" <&3 >> "$CONSOLE_LOG" 2>&1 &
    watcher_pid=$!
    wait_for_qemu_pid "$qemu_pid_file"

    phase apply-qemu-realtime-controls
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
    if [[ -n "$feeder_pid" ]]; then
        local feeder_rc=0
        if wait "$feeder_pid"; then
            feeder_rc=0
        else
            feeder_rc=$?
        fi
        feeder_pid=
        [[ "$feeder_rc" -eq 0 ]] || return "$feeder_rc"
    fi
    exec 3>&-
    serial_fd_open=0
    [[ "$watcher_rc" -eq 0 ]] || return "$watcher_rc"
}

run_result_gate() {
    phase result-gate
    local arguments=(
        --mode "$mode"
        --log "$CONSOLE_LOG"
        --output "$OUTPUT"
        --task2-count "$task2_count"
        --task3-frames "$task3_frames"
        --qemu-exit 0
    )
    if [[ "$mode" == realtime-suite ]]; then
        arguments+=(--rtbench-samples "$rtbench_samples")
    elif [[ "$mode" == stability ]]; then
        arguments+=(--seconds "$stability_seconds")
    elif [[ "$mode" == task3-fault ]]; then
        arguments+=(--task3-fault "$task3_fault")
    fi
    "$RESULT_GATE" "${arguments[@]}"
}

publish_manifest() {
    phase manifest
    printf 'qemu_exit=0\nresult_gate=PASS\n' >> "$MANIFEST_TMP"
    mv -- "$MANIFEST_TMP" "$MANIFEST"
}

main() {
    parse_arguments "$@"
    validate_mode_options
    prepare_output_directory
    exec 4>&1 5>&2
    exec >> "$RUNNER_LOG" 2>&1
    cd "$ROOT"

    TASK123_TIMEOUT_S=${TASK123_TIMEOUT_S:-600}
    QEMU_UCLAMP_MIN=${QEMU_UCLAMP_MIN:-1024}
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
