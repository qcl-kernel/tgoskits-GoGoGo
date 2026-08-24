#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_task123.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

wait_for_file_record() {
    local path=$1
    local attempts=0
    local lines=0
    while [[ "$attempts" -lt 500 ]]; do
        if [[ -r "$path" ]]; then
            lines=$(wc -l < "$path")
            [[ "$lines" -ge 1 ]] && return 0
        fi
        sleep 0.01
        attempts=$((attempts + 1))
    done
    return 1
}

assert_reaped() {
    local pid=$1
    local attempts=0
    while kill -0 "$pid" 2>/dev/null && [[ "$attempts" -lt 300 ]]; do
        sleep 0.01
        attempts=$((attempts + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        fail "owned fake PID was not reaped: $pid"
    fi
}

fixtures="$tmp/fixtures"
tools="$tmp/tools"
records="$tmp/records"
mkdir -p "$fixtures/source-input" "$fixtures/rtthread-source" "$tools" "$records"
for artifact in linux-kernel initramfs.cpio rtthread-normal.bin \
    rtthread-drop-status.bin rtthread-delayed-server.bin starryos-task123.bin \
    zephyr.bin rootfs.img model.bin; do
    printf '%s\n' "$artifact" > "$fixtures/$artifact"
done
printf '%s\n' '{"schema":1,"rtos":"zephyr","image_sha256":"'"$(sha256sum -- "$fixtures/zephyr.bin" | cut -d' ' -f1)"'","image_size":'"$(stat -c %s -- "$fixtures/zephyr.bin")"',"entry_point":1073746180,"zephyr_version":"fixture","zephyr_commit":"fixture","zephyr_sdk_version":"fixture","board":"fixture","virtio_net":true,"real_spi_interrupt":true}' \
    > "$fixtures/zephyr.bin.meta.json"
printf '%s\n' 'ddf52e2cdd977f14fc04035c88672ac204aec713' \
    > "$fixtures/rtthread-source/.axvisor-rtthread-source-commit"
rtthread_input_digest="$(
    python3 "$ROOT/os/axvisor/scripts/rtthread_image_metadata.py" \
        input-digest --root "$ROOT"
)"
python3 "$ROOT/os/axvisor/scripts/rtthread_image_metadata.py" write \
    --image "$fixtures/rtthread-normal.bin" \
    --source "$fixtures/rtthread-source" \
    --patch-digest fixture-patch-set \
    --input-digest "$rtthread_input_digest" \
    --output "$fixtures/rtthread-normal.bin.meta.json"

cat > "$tools/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_CARGO_LOG"
printf '\n' >> "$FAKE_CARGO_LOG"
if [[ "$1" == xtask && "$2" == image && "$3" == pull && "$4" == --arch && "$5" == aarch64 ]]; then
    output_dir="${TGOS_IMAGE_LOCAL_STORAGE:?}"
    mkdir -p "$output_dir/rootfs-aarch64-alpine.img"
    case "${FAKE_ROOTFS_BEHAVIOR:-one}" in
        zero) ;;
        one) printf 'pulled rootfs\n' > "$output_dir/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img" ;;
        multiple)
            exit 93
            ;;
        *) exit 93 ;;
    esac
    exit 0
fi
if [[ "${FAKE_CARGO_BEHAVIOR:-pass}" == hang ]]; then
    printf '%s\n' "$$" > "$FAKE_CARGO_PID_FILE"
    sleep 30 &
    child_pid=$!
    printf '%s\n' "$child_pid" > "$FAKE_CARGO_CHILD_PID_FILE"
    trap 'exit 143' TERM
    wait "$child_pid"
fi
[[ "${FAKE_BUILD_FAIL:-0}" != 1 ]] || exit 41
mkdir -p "$(dirname -- "$FAKE_AXVISOR_ELF")"
printf 'fake axvisor elf\n' > "$FAKE_AXVISOR_ELF"
printf '[axbuild] cargo build elf=%s\n' "$FAKE_AXVISOR_ELF"
index=0
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --vmconfigs ]]; then
        shift
        index=$((index + 1))
        cp --remove-destination "$1" "$FAKE_CARGO_VMCONFIG_DIR/$index.toml"
        awk -F '"' '/^kernel_path[[:space:]]*=/ {print $2; exit}' "$1" |
            while IFS= read -r image; do
                realpath -e -- "$(dirname -- "$1")/$image" \
                    > "$FAKE_CARGO_VMCONFIG_DIR/$index.image"
            done
    fi
    shift
done
EOF

cat > "$tools/cargo-multicall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(basename -- "$0")" == cargo-shim ]] || exit 97
exec "$(dirname -- "$0")/cargo" "$@"
EOF
ln -s cargo-multicall "$tools/cargo-shim"

cat > "$tools/aarch64-linux-gnu-strip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -o ]]
cp "$3" "$2"
EOF

cat > "$tools/aarch64-linux-gnu-objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cp "${@: -2:1}" "${@: -1}"
EOF

cat > "$tools/realtime-control" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$FAKE_CONTROL_LOG"
[[ "${FAKE_CONTROL_FAIL:-0}" != 1 ]] || exit 42
kill -0 "$1"
EOF

cat > "$tools/qemu-system-aarch64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_QEMU_LOG"
printf '\n' >> "$FAKE_QEMU_LOG"
printf '%s\n' "$$" > "$FAKE_QEMU_PID_FILE"
cat /proc/self/timerslack_ns >> "$FAKE_QEMU_TIMERSLACK_LOG"
case "${FAKE_QEMU_BEHAVIOR:-pass}" in
    build-only) exit 0 ;;
    fail) exit 17 ;;
    missing) exit 0 ;;
    hang)
        trap 'exit 143' TERM
        while :; do sleep 1; done
        ;;
esac

cmdline="$(awk -F '"' '/^[[:space:]]*cmdline[[:space:]]*=/ {print $2; exit}' \
    "$FAKE_CARGO_VMCONFIG_DIR/1.toml")"
task2_count="$(sed -n 's/.*task2.count=\([0-9][0-9]*\).*/\1/p' <<< "$cmdline")"
task3_frames="$(sed -n 's/.*task3.frames=\([0-9][0-9]*\).*/\1/p' <<< "$cmdline")"
task3_fault="$(sed -n 's/.*task3.fault=\([^ ]*\).*/\1/p' <<< "$cmdline")"

emit_initial() {
local app_guest=linux
if grep -Fq 'kernel_path = "starryos-task123.bin"' "$FAKE_CARGO_VMCONFIG_DIR/1.toml"; then
    app_guest=starryos
fi
local app_smp_marker='LINUX_SMP_READY configured=2 online=0-1 nproc=2'
local app_net_marker='TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30'
if [[ "$app_guest" == starryos ]]; then
    app_smp_marker='STARRY_SMP_READY configured=2 online=0-1 nproc=2'
    app_net_marker='STARRY_NET_READY ip=192.168.77.11 peer=192.168.77.30'
fi
printf '[VM 1] %s\n' "$app_smp_marker"
printf '[VM 1] %s\n' "$app_net_marker"
rtos_shell_marker='msh />'
if grep -Fq 'kernel_path = "zephyr.bin"' "$FAKE_CARGO_VMCONFIG_DIR/2.toml"; then
    rtos_shell_marker=''
fi
if [[ -n "$rtos_shell_marker" ]]; then
    printf '[VM 3] [32m[I/rtipic.srv] server starting on 192.168.77.30:9876[0m\n'
else
    printf '[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876\n'
fi
printf '[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877\n'
if [[ -n "$rtos_shell_marker" ]]; then
    printf '[VM 3] %s\n' "$rtos_shell_marker"
fi
for payload in 64 256 1024; do
    printf '[VM 1] --- Payload %sB ---\n' "$payload"
    printf '[VM 1] sent=%s recv=%s\n' "$task2_count" "$task2_count"
    echo '[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0'
    echo '[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0'
done
echo '[VM 1] RT-IPC client exited with rc=0'
echo '[VM 1] ALL TESTS COMPLETE'

retries=0
rtos_retries=0
rtos_errors=0
rtos_duplicates=0
injected_drops=0
case "$task3_fault" in
    drop-control) retries=1; injected_drops=1 ;;
    drop-status) rtos_retries=1 ;;
    duplicate-frame) rtos_duplicates=1 ;;
    malformed) rtos_errors=3 ;;
esac
for task3_mode in FIXED AI; do
    for ((frame = 0; frame < task3_frames; frame++)); do
        printf '[VM 1] TASK3_FRAME_CSV=%s,%s,100,1,1,30000,10,%s,0,0,100,2,3,0,0,0\n' \
            "$task3_mode" "$frame" "$retries"
        retries=0
    done
done
records=$((task3_frames * 2))
printf '[VM 1] TASK3_SUMMARY_JSON={"schema":1,"frames_per_mode":%s,"records":%s,"requests":%s,"successes":%s,"success_rate":1.0,"application_errors":0,"application_timeouts":0,"reconnects":0,"injected_drops":%s,"elapsed_us":1000,"settling":{"fixed":{},"ai":{}}}\n' \
    "$task3_frames" "$records" "$records" "$records" "$injected_drops"
if [[ -z "${FAKE_QEMU_EXPECT_COMMAND:-}" &&
      "${FAKE_QEMU_DROP_FIRST_CONSOLE_SWITCH:-0}" != 1 &&
      "${FAKE_QEMU_BEHAVIOR:-pass}" != split-final ]]; then
    emit_rtos_final
fi
case "$task3_fault" in
    drop-status) echo '[VM 3] TASK3_FAULT_DROP_STATUS dropped=1' ;;
    duplicate-frame) echo '[VM 1] TASK3_FAULT_DUPLICATE frame=0 duplicate=1 actuator_before=0 actuator_after=0 applied_delta=0' ;;
    delayed-server) echo '[VM 3] TASK3_FAULT_DELAYED_SERVER delay_ms=3000' ;;
    malformed) echo '[VM 1] TASK3_FAULT_MALFORMED schema2=rejected short=rejected crc=rejected rejected=3 actuator_before=0 actuator_after=0 applied_delta=0' ;;
esac
if [[ -n "${FAKE_QEMU_EXPECT_COMMAND:-}" ]]; then
    emit_linux_finals
    linux_finals_emitted=1
fi
if [[ -z "${FAKE_QEMU_EXPECT_COMMAND:-}" &&
      "${FAKE_QEMU_DROP_FIRST_CONSOLE_SWITCH:-0}" == 1 ]]; then
    emit_linux_finals
fi
}

emit_linux_finals() {
    local app_guest=linux
    if grep -Fq 'kernel_path = "starryos-task123.bin"' "$FAKE_CARGO_VMCONFIG_DIR/1.toml"; then
        app_guest=starryos
    fi
    local task2_marker='TASK2_LINUX_END status=PASS'
    local task3_marker='TASK3_LINUX_END status=PASS'
    local task123_marker='TASK123_LINUX_END status=PASS'
    if [[ "$app_guest" == starryos ]]; then
        task2_marker='TASK2_STARRY_END status=PASS'
        task3_marker='TASK3_STARRY_END status=PASS'
        task123_marker='TASK123_STARRY_END status=PASS'
    fi
    if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == linux-fail ]]; then
        printf '[VM 1] %s\n' "$task2_marker"
        printf '[VM 1] %s\n' "${task3_marker/PASS/FAIL}"
        printf '[VM 1] %s\n' "${task123_marker/PASS/FAIL}"
        return
    fi
    if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == linux-task2-fail ]]; then
        printf '[VM 1] %s\n' "${task2_marker/PASS/FAIL}"
        printf '[VM 1] %s\n' "$task3_marker"
        printf '[VM 1] %s\n' "$task123_marker"
        return
    fi
    printf '[VM 1] %s\n' "$task2_marker"
    printf '[VM 1] %s\n' "$task3_marker"
    printf '[VM 1] %s\n' "$task123_marker"
}

emit_benchmark() {
    local command=$1
    local value=${command##* }
    if [[ "$command" == benchmark\ * ]]; then
        local counters='p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=2'
        printf 'RTBENCH_BEGIN samples=%s frequency=1000000 pmu_event=0x8\n' "$value"
        echo 'RTBENCH_PMU status=ready event=0x8 cycles_delta=100 instructions_delta=100'
        for run in 1 2 3; do
            for metric in timer_jitter callback_exec; do
                printf 'RTBENCH metric=%s run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
                    "$metric" "$run" "$value" "$value" "$counters"
            done
        done
        for metric in preemption irq irq_to_task irq_disabled_duration mutex_inversion wake_under_load \
            context_switch scheduler_decision sync_sem sync_mutex sync_mailbox irq_handler_exec \
            deadline_miss_under_load net_event_latency; do
            printf 'RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2 %s\n' \
                "$metric" "$value" "$value" "$counters"
        done
        if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == benchmark-fail ]]; then
            echo 'RTBENCH_END status=FAIL'
        else
            echo 'RTBENCH_END status=PASS'
        fi
    else
        local expected=$((value * 1000 - 1))
        local counters='p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=2 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=2'
        if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == interleaved-begin-marker ]]; then
            printf 'RTBENCH_STABILITY_BEGIN seconds=%s exp' "$value"
            printf '\033[37m[ 40.877348 0:25 axvm::runtime::hvc:272] \033[32mVM[1] PSCI_CPU_ON\033[m\r\n\033[m'
            printf 'ected=%s frequency=1000000 pmu_event=0x8\n' "$expected"
        else
            printf 'RTBENCH_STABILITY_BEGIN seconds=%s expected=%s frequency=1000000 pmu_event=0x8\n' "$value" "$expected"
        fi
        if [[ "${FAKE_QEMU_PMU_UNAVAILABLE:-0}" == 1 ]]; then
            echo 'RTBENCH_PMU status=unavailable event=0x8 cycles_delta=0 instructions_delta=0 units=ns'
        elif [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == interleaved-pmu-marker ]]; then
            printf 'RTmBTBENECNCH_PMU status=ready event=0x8 cycles_delta=100 instructions_delta=100\n'
        else
            echo 'RTBENCH_PMU status=ready event=0x8 cycles_delta=100 instructions_delta=100'
        fi
        for metric in stability_jitter callback_exec; do
            local miss_1ms=0
            if [[ "$metric" == stability_jitter &&
                  "${FAKE_QEMU_BEHAVIOR:-pass}" == stability-timer-limit ]]; then
                miss_1ms=1
            fi
            printf 'RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=%s mean_ns=2 %s\n' \
                "$metric" "$expected" "$expected" "$miss_1ms" "$counters"
        done
        if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == stability-fail ||
              "${FAKE_QEMU_BEHAVIOR:-pass}" == stability-timer-limit ]]; then
            printf 'RTBENCH_STABILITY_END status=FAIL expected=%s collected=%s missing=0\n' "$expected" "$expected"
        else
            printf 'RTBENCH_STABILITY_END status=PASS expected=%s collected=%s missing=0\n' "$expected" "$expected"
        fi
        if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == interleaved-stability-done ]]; then
            printf 'RTBENCH_STABILITY'
            printf '_ONE\n'
        else
            echo 'RTBENCH_STABILITY_DONE'
        fi
    fi
}

wait_for_control() {
    local target=$1
    local first
    local second
    while IFS= read -r -n 1 first; do
        [[ "$first" == $'\030' ]] || continue
        IFS= read -r -n 1 second || return 1
        [[ "$second" == "$target" ]] && return 0
    done
    return 1
}

emit_rtos_final() {
    if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == split-final ]]; then
        printf '[VM 3] TASK3_RTOS_FINAL requests=%s errors=%s duplicates=%s applied_st' \
            "$records" "$rtos_errors" "$rtos_duplicates"
        sleep 1
        printf 'eps=%s retries=%s\n' "$records" "$rtos_retries"
    else
        printf '[VM 3] TASK3_RTOS_FINAL requests=%s errors=%s duplicates=%s applied_steps=%s retries=%s\n' \
            "$records" "$rtos_errors" "$rtos_duplicates" "$records" "$rtos_retries"
    fi
    if [[ "${FAKE_QEMU_DROP_FINAL_DONE:-0}" == 1 ]]; then
        return
    elif [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == split-final-done ]]; then
        printf '[VM 3] TASK3_RTOS_FINAL_DON'
        printf '\033[37m[ 52.430151 0:30 axvm::runtime::vcpus:667] \033[32mVM[1] VCpu[1] exiting...\033[m\r\n'
        printf 'E\n'
    else
        printf '[VM 3] TASK3_RTOS_FINAL_DONE\n'
    fi
}

rtos_final_emitted=0

if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == complete-nonzero ]]; then
    sleep 0.2
fi
emit_initial
if [[ -n "${FAKE_QEMU_EXPECT_COMMAND:-}" ]]; then
    # AxVisor prints an earlier VM3 attachment during startup, followed by
    # VM1 becoming the active console. A later switch must wait for a new
    # confirmation rather than treating this stale line as the result.
    printf '[Axvisor] attached VM[3] console; use Ctrl+X, then h to return to the shell\n'
    printf '[Axvisor] attached VM[1] console; use Ctrl+X, then h to return to the shell\n'
    wait_for_control ']'
    echo 'select-vm3' >> "$FAKE_QEMU_STDIN_LOG"
    printf '[Axvisor] attached VM[3] console; use Ctrl+X, then h to return to the shell\n'
    if [[ "${FAKE_QEMU_FINAL_WITHOUT_BENCHMARK:-0}" == 1 ]]; then
        printf '%s
' '[Axvisor] attached VM[3] console; use Ctrl+X, then h to return to the shell'
        emit_rtos_final
        rtos_final_emitted=1
        trap 'exit 143' TERM
        while :; do sleep 1; done
    fi
    emit_rtos_final
    rtos_final_emitted=1
    benchmark_command=
    while IFS= read -r -n 1 command_byte; do
        [[ "$command_byte" == $'\r' ]] && break
        benchmark_command+=$command_byte
    done
    if [[ -z "$benchmark_command" ]]; then
        while IFS= read -r -n 1 command_byte; do
            [[ "$command_byte" == $'\r' ]] && break
            benchmark_command+=$command_byte
        done
    fi
    [[ "$benchmark_command" == "$FAKE_QEMU_EXPECT_COMMAND" ]]
    printf 'command=%s\n' "$benchmark_command" >> "$FAKE_QEMU_STDIN_LOG"
    if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" != missing-benchmark ]]; then
        emit_benchmark "$benchmark_command"
        if [[ "$rtos_final_emitted" -eq 0 ]]; then
            emit_rtos_final
            rtos_final_emitted=1
        fi
    fi
fi
if [[ "${FAKE_QEMU_DROP_FIRST_CONSOLE_SWITCH:-0}" -eq 1 ]]; then
    wait_for_control ']'
    echo 'drop-first-switch' >> "$FAKE_QEMU_STDIN_LOG"
    wait_for_control ']'
    echo 'retry-switch' >> "$FAKE_QEMU_STDIN_LOG"
    printf '[Axvisor] attached VM[3] console; use Ctrl+X, then h to return to the shell\n'
    if [[ "$rtos_final_emitted" -eq 0 ]]; then
        emit_rtos_final
        rtos_final_emitted=1
    fi
    trap 'exit 143' TERM
    while :; do sleep 1; done
fi
if [[ "${linux_finals_emitted:-0}" != 1 && \
      "${FAKE_QEMU_FINAL_WITHOUT_BENCHMARK:-0}" != 1 ]]; then
    emit_linux_finals
fi
if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == split-final ]]; then
    if [[ "$rtos_final_emitted" -eq 0 ]]; then
        emit_rtos_final
        rtos_final_emitted=1
    fi
fi
if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == duplicate ]]; then
    echo '[VM 1] TASK2_LINUX_END status=PASS'
fi
if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == complete-nonzero ]]; then
    exit 17
fi
trap 'exit 143' TERM
while :; do sleep 1; done
EOF
chmod +x "$tools"/*

common_env=(
    PATH="$tools:$PATH"
    QEMU="$tools/qemu-system-aarch64"
    CARGO="$tools/cargo"
    AARCH64_STRIP="$tools/aarch64-linux-gnu-strip"
    AARCH64_OBJCOPY="$tools/aarch64-linux-gnu-objcopy"
    QEMU_REALTIME_CONTROL="$tools/realtime-control"
    LINUX_KERNEL_IMAGE="$fixtures/linux-kernel"
    LINUX_INITRAMFS_IMAGE="$fixtures/initramfs.cpio"
    RTTHREAD_IMAGE="$fixtures/rtthread-normal.bin"
    ZEPHYR_IMAGE="$fixtures/zephyr.bin"
    ROOTFS_IMAGE="$fixtures/rootfs.img"
    TASK123_MODEL_IMAGE="$fixtures/model.bin"
    STARRYOS_IMAGE="$fixtures/starryos-task123.bin"
    RTTHREAD_IMAGE_META="$fixtures/rtthread-normal.bin.meta.json"
    FAKE_CARGO_LOG="$records/cargo.log"
    FAKE_CARGO_PID_FILE="$records/fake-cargo.pid"
    FAKE_CARGO_CHILD_PID_FILE="$records/fake-cargo-child.pid"
    FAKE_CARGO_VMCONFIG_DIR="$records"
    FAKE_AXVISOR_ELF="$fixtures/generated/axvisor"
    FAKE_QEMU_LOG="$records/qemu.log"
    FAKE_QEMU_PID_FILE="$records/qemu.pid"
    FAKE_QEMU_TIMERSLACK_LOG="$records/qemu-timerslack.log"
    FAKE_QEMU_STDIN_LOG="$records/qemu-stdin.log"
    FAKE_CONTROL_LOG="$records/control.log"
)

run_runner() {
    local output=$1
    shift
    rm -f -- "$records/qemu.pid"
    env "${common_env[@]}" "$@" "$RUNNER" --mode smoke \
        --task2-count 2 --task3-frames 3 --output "$output"
}

run_fault_runner() {
    local output=$1
    local profile=$2
    rm -f -- "$records/qemu.pid"
    env "${common_env[@]}" "$RUNNER" --mode task3-fault --task3-fault "$profile" \
        --task3-frames 3 --output "$output"
}

expect_failure() {
    local description=$1
    shift
    if "$@" >"$tmp/failure.out" 2>&1; then
        fail "$description"
    fi
}

assert_mode_contract() {
    local label=$1
    local expected_cmdline=$2
    local expected_image=$3

    [[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
        fail "$label did not launch exactly one QEMU"
    [[ "$(grep -o -- '--vmconfigs' "$records/cargo.log" | wc -l)" -eq 2 ]] ||
        fail "$label did not generate exactly two VM configs"
    grep -Fq "cmdline = \"$expected_cmdline\"" "$records/1.toml" ||
        fail "$label Linux workload cmdline is incorrect"
    [[ "$(cat "$records/2.image")" == "$(realpath -e "$expected_image")" ]] ||
        fail "$label selected the wrong RT-Thread image"
    [[ "$(grep -o -- '-append' "$records/qemu.log" | wc -l)" -eq 1 ]] ||
        fail "$label did not pass exactly one outer -append"
    grep -Fq -- '-append root=/dev/nvme0n1\ rw\ init=/bin/sh ' "$records/qemu.log" ||
        fail "$label outer -append was not the exact AxVisor host rootfs value"
    grep -Fq -- '-serial stdio ' "$records/qemu.log" ||
        fail "$label did not use the owned stdio serial channel"
    if grep -Eq -- '(-append[^-]*)(task2\.|task3\.|rdinit=/init)' "$records/qemu.log"; then
        fail "$label leaked the Linux workload cmdline into outer -append"
    fi
}

assert_starryos_contract() {
    [[ "$(grep -Fx 'app_guest=starryos' "$1/manifest.txt")" == 'app_guest=starryos' ]] ||
        fail "StarryOS manifest did not record app_guest"
    grep -Fq 'STARRY_SMP_READY configured=2 online=0-1 nproc=2' "$1/console.log" ||
        fail "StarryOS SMP marker is missing"
    grep -Fq 'STARRY_NET_READY ip=192.168.77.11 peer=192.168.77.30' "$1/console.log" ||
        fail "StarryOS network marker is missing"
    grep -Fq 'TASK123_STARRY_END status=PASS' "$1/console.log" ||
        fail "StarryOS completion marker is missing"
    grep -Eq '^ARTIFACT name=starryos path=/.* sha256=[0-9a-f]{64}$' "$1/manifest.txt" ||
        fail "StarryOS image was not recorded in the manifest"
}

[[ -x "$RUNNER" ]] || fail "run_task123.sh is missing or not executable"

stale_metadata="$fixtures/rtthread-stale-inputs.bin.meta.json"
cp -- "$fixtures/rtthread-normal.bin.meta.json" "$stale_metadata"
python3 - "$stale_metadata" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
metadata = json.loads(path.read_text(encoding="utf-8"))
metadata["build_inputs_sha256"] = "0" * 64
path.write_text(json.dumps(metadata) + "\n", encoding="utf-8")
PY
expect_failure "stale RT-Thread build inputs passed metadata validation" \
    env "${common_env[@]}" RTTHREAD_IMAGE_META="$stale_metadata" \
        RTTHREAD_REQUIRE_IMAGE_METADATA=1 \
        "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
        --output "$tmp/stale-rtthread-inputs"

normal_output="$tmp/normal-output"
if ! run_runner "$normal_output" > "$tmp/normal.stdout" 2>"$tmp/normal.stderr"; then
    [[ ! -f "$normal_output/console.log" ]] || cat "$normal_output/console.log" >&2
    cat "$tmp/normal.stdout" >&2
    cat "$tmp/normal.stderr" >&2
    fail "normal fake run failed"
fi
grep -Fq 'PHASE dependency-check' "$tmp/normal.stdout" ||
    fail "runner did not stream phase progress to stdout"
grep -Fq 'STEP cargo-xtask-axvisor-build' "$tmp/normal.stdout" ||
    fail "runner did not stream timed-step progress to stdout"
[[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
    fail "runner did not launch exactly one QEMU"
qemu_pid="$(cat "$records/qemu.pid")"
assert_reaped "$qemu_pid"

[[ "$(sed -n '1p' "$records/qemu-timerslack.log")" == 1 ]] ||
    fail "runner did not apply 1 ns timer slack before QEMU exec"
grep -Fxq 'qemu_timer_slack_ns=1' "$normal_output/manifest.txt" ||
    fail "manifest did not record the QEMU timer slack"

grep -Fq -- "-kernel $normal_output/axvisor.bin" "$records/qemu.log" ||
    fail "QEMU did not boot the generated AxVisor binary"
if grep -Fq -- "$fixtures/linux-kernel" "$records/qemu.log" ||
    grep -Fq -- "$fixtures/initramfs.cpio" "$records/qemu.log"; then
    fail "QEMU booted a guest artifact directly"
fi
if grep -Eq -- 'task[23]\.(count|fault|frames)=' "$records/qemu.log"; then
    fail "guest command line leaked onto the outer QEMU command line"
fi

[[ "$(grep -o -- '--vmconfigs' "$records/cargo.log" | wc -l)" -eq 2 ]] ||
    fail "cargo axvisor build did not receive exactly two VM configs"
grep -Eq '^xtask axvisor build .*--vmconfigs .*--vmconfigs ' "$records/cargo.log" ||
    fail "runner did not use cargo xtask axvisor build"
grep -Eq '^xtask axvisor build .*--smp 4 ' "$records/cargo.log" ||
    fail "runner did not build AxVisor for all four QEMU CPUs"
grep -Fq 'task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal' \
    "$records/1.toml" || fail "guest controls were not written through Linux VM config"
[[ "$(cat "$records/2.image")" == "$(realpath -e "$fixtures/rtthread-normal.bin")" ]] ||
    fail "smoke mode did not select the normal RT-Thread image"
assert_mode_contract smoke \
    'console=ttyAMA0 rdinit=/init task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal' \
    "$fixtures/rtthread-normal.bin"
grep -Fq 'AxVisor host cmdline' "$RUNNER" ||
    fail "runner does not document that outer -append belongs to the AxVisor host"

: > "$records/cargo.log"
: > "$records/qemu.log"
split_final_output="$tmp/split-final-output"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=split-final \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$split_final_output" >/dev/null; then
    [[ ! -f "$split_final_output/console.log" ]] || cat "$split_final_output/console.log" >&2
    fail "runner terminated before the complete RTOS final marker"
fi
grep -Fq 'TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0' \
    "$split_final_output/rtthread.log" ||
    fail "runner did not preserve the complete split RTOS final marker"
grep -Fq 'TASK3_RTOS_FINAL_DONE' "$split_final_output/console.log" ||
    fail "runner did not wait for the RTOS final completion marker"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
split_final_done_output="$tmp/split-final-done-output"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=split-final-done TASK123_TIMEOUT_S=2 \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$split_final_done_output" >/dev/null; then
    [[ ! -f "$split_final_done_output/console.log" ]] || cat "$split_final_done_output/console.log" >&2
    fail "runner rejected a final marker split across shared-console writes"
fi
grep -Fq 'TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0' \
    "$split_final_done_output/rtthread.log" ||
    fail "runner did not preserve the final summary when final marker was split"
grep -Fq 'TASK3_RTOS_FINAL_DONE' "$split_final_done_output/rtthread.log" ||
    fail "result gate did not reconstruct the split RTOS final completion marker"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
starry_output="$tmp/starry-output"
if ! env "${common_env[@]}" "$RUNNER" --app-guest starryos --mode smoke \
    --task2-count 2 --task3-frames 3 --output "$starry_output" >/dev/null; then
    [[ ! -f "$starry_output/console.log" ]] || cat "$starry_output/console.log" >&2
    fail "StarryOS fake run failed"
fi
grep -Fq 'kernel_path = "starryos-task123.bin"' "$records/1.toml" ||
    fail "StarryOS run did not select the StarryOS VM config"
[[ "$(cat "$records/1.image")" == "$(realpath -e "$fixtures/starryos-task123.bin")" ]] ||
    fail "StarryOS run selected the wrong application image"
assert_starryos_contract "$starry_output"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
zephyr_output="$tmp/zephyr-output"
if ! env "${common_env[@]}" TASK123_TIMEOUT_S=2 \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 300' \
    TASK123_ZEPHYR_SMOKE_COMMAND='rtbench_stability 300' \
    "$RUNNER" --rtos zephyr --app-guest linux \
    --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$zephyr_output" >/dev/null; then
    fail "Zephyr/Linux fake run failed"
fi
[[ "$(cat "$records/qemu-stdin.log")" == $'select-vm3\ncommand=rtbench_stability 300' ]] ||
    fail "Zephyr smoke mode did not collect its final marker with a benchmark command"
grep -Fxq 'rtos=zephyr' "$zephyr_output/manifest.txt" ||
    fail "Zephyr manifest did not record rtos"
grep -Fxq 'app_guest=linux' "$zephyr_output/manifest.txt" ||
    fail "Zephyr run did not retain the Linux app guest"
[[ "$(cat "$records/2.image")" == "$(realpath -e "$fixtures/zephyr.bin")" ]] ||
    fail "Zephyr run selected the wrong RTOS image"
grep -Fq 'kernel_path = "zephyr.bin"' "$records/2.toml" ||
    fail "Zephyr run selected the wrong VM template"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
zephyr_smoke_output="$tmp/zephyr-smoke-output"
if ! env "${common_env[@]}" FAKE_QEMU_EXPECT_COMMAND='collect-final-only' \
    FAKE_QEMU_FINAL_WITHOUT_BENCHMARK=1 \
    "$RUNNER" --rtos zephyr --app-guest linux \
    --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$zephyr_smoke_output" >"$tmp/zephyr-smoke.stdout" 2>"$tmp/zephyr-smoke.stderr"; then
    [[ ! -f "$zephyr_smoke_output/console.log" ]] ||
        cat "$zephyr_smoke_output/console.log" >&2
    cat "$tmp/zephyr-smoke.stdout" >&2
    cat "$tmp/zephyr-smoke.stderr" >&2
    fail "Zephyr/Linux smoke fake run failed without a benchmark command"
fi
grep -Fxq 'select-vm3' "$records/qemu-stdin.log" ||
    fail "Zephyr smoke mode did not switch to VM3 to collect its final marker"
grep -Fq 'TASK3_RTOS_FINAL requests=' "$zephyr_smoke_output/console.log" ||
    fail "Zephyr smoke run did not collect the RTOS final marker"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
zephyr_switch_retry_output="$tmp/zephyr-switch-retry-output"
if ! env "${common_env[@]}" FAKE_QEMU_DROP_FIRST_CONSOLE_SWITCH=1 \
    "$RUNNER" --rtos zephyr --app-guest linux \
    --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$zephyr_switch_retry_output" >/dev/null; then
    [[ ! -f "$zephyr_switch_retry_output/console.log" ]] ||
        cat "$zephyr_switch_retry_output/console.log" >&2
    fail "Zephyr/Linux smoke did not retry a dropped console switch"
fi
[[ "$(cat "$records/qemu-stdin.log")" == $'drop-first-switch\nretry-switch' ]] ||
    fail "Zephyr smoke did not resend the complete console-switch prefix"
grep -Fq '[Axvisor] attached VM[3] console' \
    "$zephyr_switch_retry_output/console.log" ||
    fail "Zephyr smoke retried without requiring console-switch confirmation"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
zephyr_unavailable_pmu_output="$tmp/zephyr-unavailable-pmu-output"
if ! env "${common_env[@]}" TASK123_TIMEOUT_S=3 \
    TASK123_ALLOW_QEMU_TIMER_LIMIT=1 \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' \
    FAKE_QEMU_PMU_UNAVAILABLE=1 \
    "$RUNNER" --rtos zephyr --app-guest linux --mode stability \
    --seconds 1 --task2-count 2 --output "$zephyr_unavailable_pmu_output" \
    >/dev/null; then
    [[ ! -f "$zephyr_unavailable_pmu_output/console.log" ]] ||
        cat "$zephyr_unavailable_pmu_output/console.log" >&2
    fail "Zephyr stability rejected PMU-unavailable evidence"
fi
grep -Fxq 'rtbench_pmu_status=unavailable' \
    "$zephyr_unavailable_pmu_output/manifest.txt" ||
    fail "Zephyr manifest did not record unavailable PMU status"
assert_reaped "$(cat "$records/qemu.pid")"

for realtime_case in 'realtime-suite:benchmark 2' 'stability:rtbench_stability 1'; do
    realtime_mode=${realtime_case%%:*}
    realtime_command=${realtime_case#*:}
    realtime_output="$tmp/$realtime_mode-output"
    : > "$records/cargo.log"
    : > "$records/qemu.log"
    : > "$records/qemu-stdin.log"
    if [[ "$realtime_mode" == realtime-suite ]]; then
        realtime_args=(--rtbench-samples 2 --task2-count 2)
        expected_guest_cmdline='console=ttyAMA0 rdinit=/init task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal rtbench.net.count=2'
    else
        realtime_args=(--seconds 1 --task2-count 2)
        expected_guest_cmdline='console=ttyAMA0 rdinit=/init task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal'
    fi
    if ! env "${common_env[@]}" FAKE_QEMU_EXPECT_COMMAND="$realtime_command" \
        TASK123_TIMEOUT_S=2 "$RUNNER" --mode "$realtime_mode" \
        "${realtime_args[@]}" --output "$realtime_output" >/dev/null; then
        [[ ! -f "$realtime_output/console.log" ]] ||
            cat "$realtime_output/console.log" >&2
        fail "$realtime_mode feeder run failed"
    fi
    [[ "$(cat "$records/qemu-stdin.log")" == $'select-vm3\ncommand='"$realtime_command" ]] ||
        fail "$realtime_mode did not start the benchmark after Linux final evidence"
    assert_mode_contract "$realtime_mode" \
        "$expected_guest_cmdline" \
        "$fixtures/rtthread-normal.bin"
    assert_reaped "$(cat "$records/qemu.pid")"
done

: > "$records/cargo.log"
: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
missing_final_done_output="$tmp/stability-missing-final-done"
if ! env "${common_env[@]}" FAKE_QEMU_DROP_FINAL_DONE=1 \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=2 \
    TASK123_ALLOW_QEMU_TIMER_LIMIT=1 \
    "$RUNNER" --mode stability --rtos rtthread --app-guest starryos \
    --seconds 1 --task2-count 2 --output "$missing_final_done_output" >/dev/null; then
    [[ ! -f "$missing_final_done_output/console.log" ]] ||
        cat "$missing_final_done_output/console.log" >&2
    fail "runner required the lossy RTOS final DONE write after a complete final record"
fi
grep -Fq 'TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0' \
    "$missing_final_done_output/console.log" ||
    fail "missing-DONE run lost the complete RTOS final record"
if grep -Fq 'TASK3_RTOS_FINAL_DONE' "$missing_final_done_output/console.log"; then
    fail "missing-DONE fixture unexpectedly emitted the optional completion marker"
fi
[[ "$(cat "$records/qemu-stdin.log")" == \
   $'select-vm3\ncommand=rtbench_stability 1' ]] ||
    fail "runner did not start the benchmark after the complete RTOS final record"
assert_reaped "$(cat "$records/qemu.pid")"

feed_function="$tmp/feed_benchmark_command.txt"
sed -n '/^feed_benchmark_command()/,/^collect_rtos_final_command()/p' "$RUNNER" > "$feed_function"
app_done_line="$(grep -nF 'if ! wait_for_console_marker "$APP_GUEST_TASK123_END_MARKER"' "$feed_function" | head -n 1 | cut -d: -f1 || true)"
switch_to_rtos_line="$(grep -nF 'switch_console_to_next_guest || return 1' "$feed_function" | head -n 1 | cut -d: -f1 || true)"
benchmark_started_line="$(grep -nF 'if ! wait_for_console_marker "$started"' "$feed_function" | cut -d: -f1 || true)"
benchmark_ready_line="$(grep -nF 'if ! wait_for_console_marker "$ready"' "$feed_function" | tail -n 1 | cut -d: -f1 || true)"
[[ "$app_done_line" =~ ^[0-9]+$ && "$switch_to_rtos_line" =~ ^[0-9]+$ &&
   "$benchmark_started_line" =~ ^[0-9]+$ && "$benchmark_ready_line" =~ ^[0-9]+$ ]] ||
    fail "benchmark feeder ordering markers are missing"
grep -Fq "started='pmu_event=0x8'" "$feed_function" ||
    fail "benchmark start boundary can split the begin evidence line"
(( app_done_line < switch_to_rtos_line && switch_to_rtos_line < benchmark_started_line &&
   benchmark_started_line < benchmark_ready_line )) ||
    fail "benchmark feeder did not preserve app-final, RTOS-final, benchmark ordering"
if grep -Fq "printf '\\030['" "$feed_function"; then
    fail "benchmark feeder switches back to an application guest that may already be stopped"
fi

interleaved_pmu_output="$tmp/stability-interleaved-pmu"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=interleaved-pmu-marker \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode stability --rtos rtthread --app-guest linux \
    --seconds 1 --task2-count 2 \
    --output "$interleaved_pmu_output" >/dev/null; then
    cat "$interleaved_pmu_output/console.log" >&2 || true
    fail "runner rejected an RT-Thread PMU marker interleaved with shell echo"
fi
grep -Fxq 'rtbench_pmu_status=ready' \
    "$interleaved_pmu_output/manifest.txt" ||
    fail "interleaved PMU marker was not recorded in the manifest"

interleaved_begin_output="$tmp/stability-interleaved-begin"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=interleaved-begin-marker \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode stability --rtos rtthread --app-guest linux \
    --seconds 1 --task2-count 2 \
    --output "$interleaved_begin_output" >/dev/null; then
    cat "$interleaved_begin_output/console.log" >&2 || true
    fail "runner rejected a benchmark begin marker interleaved with host output"
fi
grep -Fxq 'rtbench_counter_frequency=1000000' \
    "$interleaved_begin_output/manifest.txt" ||
    fail "interleaved benchmark frequency was not recorded in the manifest"

interleaved_done_output="$tmp/stability-interleaved-done"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=interleaved-stability-done \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=2 \
    TASK123_ALLOW_QEMU_TIMER_LIMIT=1 \
    "$RUNNER" --mode stability --rtos rtthread --app-guest starryos \
    --seconds 1 --task2-count 2 \
    --output "$interleaved_done_output" >/dev/null; then
    [[ ! -f "$interleaved_done_output/console.log" ]] ||
        cat "$interleaved_done_output/console.log" >&2
    fail "runner waited for a stability DONE marker corrupted by shared-console output"
fi
grep -Fq 'TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0' \
    "$interleaved_done_output/console.log" ||
    fail "stability feeder did not wait for the RTOS final record"
awk '
    /TASK3_RTOS_FINAL requests=/ { final = NR }
    /RTBENCH_STABILITY_BEGIN / { begin = NR }
    END { exit !(final > 0 && begin > final) }
' "$interleaved_done_output/console.log" ||
    fail "stability benchmark started before the RTOS final record"
grep -Fxq 'result_gate=PASS_WITH_QEMU_TIMER_LIMIT' \
    "$interleaved_done_output/manifest.txt" ||
    fail "interleaved QEMU timer-limit run was not accepted by the result gate"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
linux_first_output="$tmp/linux-first-output"
if ! env "${common_env[@]}" \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=2 \
    "$RUNNER" --mode stability --seconds 1 --task2-count 2 \
    --output "$linux_first_output" >/dev/null; then
    fail "runner did not drain Linux before waiting for benchmark completion"
fi
[[ "$(cat "$records/qemu-stdin.log")" == \
   $'select-vm3\ncommand=rtbench_stability 1' ]] ||
    fail "Linux-first run used the wrong console drain order"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
default_rootfs_output="$tmp/default-rootfs-output"
default_rootfs_cache="$tmp/default-rootfs-cache"
env "${common_env[@]}" ROOTFS_IMAGE= TGOS_SOURCE_CACHE="$default_rootfs_cache" \
    "$RUNNER" --mode smoke \
    --task2-count 2 --task3-frames 3 --output "$default_rootfs_output" >/dev/null ||
    fail "default rootfs pull run failed"
grep -Eq '^xtask image pull --arch aarch64[[:space:]]*$' \
    "$records/cargo.log" || fail "runner did not pull the managed aarch64 rootfs"
grep -Eq '^ARTIFACT name=rootfs path=/.*rootfs/rootfs-aarch64-alpine\.img/rootfs-aarch64-alpine\.img sha256=[0-9a-f]{64}$' \
    "$default_rootfs_output/manifest.txt" ||
    fail "manifest did not record the uniquely pulled rootfs"
[[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
    fail "default rootfs run did not reach exactly one QEMU"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/cargo.log"
: > "$records/qemu.log"
reused_rootfs_output="$tmp/reused-rootfs-output"
env "${common_env[@]}" ROOTFS_IMAGE= TGOS_SOURCE_CACHE="$default_rootfs_cache" \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$reused_rootfs_output" >/dev/null ||
    fail "cached rootfs reuse run failed"
[[ "$(grep -Ec 'xtask image pull --arch aarch64' "$records/cargo.log")" -eq 0 ]] ||
    fail "cached rootfs was pulled again"
[[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
    fail "cached rootfs run did not reach exactly one QEMU"

for rootfs_behavior in zero failure; do
    : > "$records/cargo.log"
    : > "$records/qemu.log"
    bad_rootfs_output="$tmp/rootfs-$rootfs_behavior-output"
    bad_rootfs_cache="$tmp/rootfs-$rootfs_behavior-cache"
    expect_failure "rootfs pull with $rootfs_behavior candidates returned success" \
        env "${common_env[@]}" ROOTFS_IMAGE= TGOS_SOURCE_CACHE="$bad_rootfs_cache" \
        FAKE_ROOTFS_BEHAVIOR="$rootfs_behavior" \
            "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
            --output "$bad_rootfs_output"
    [[ ! -s "$records/qemu.log" ]] ||
        fail "QEMU started after rootfs $rootfs_behavior candidate failure"
done

: > "$records/cargo.log"
: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
task3_output="$tmp/task3-output"
if ! env "${common_env[@]}" "$RUNNER" --mode task3 --task3-frames 3 \
    --output "$task3_output" >/dev/null; then
    cat "$task3_output/console.log" >&2
    fail "task3 lifecycle run failed"
fi
assert_mode_contract task3 \
    'console=ttyAMA0 rdinit=/init task2.count=1000 task2.fault=none task3.frames=3 task3.fault=normal' \
    "$fixtures/rtthread-normal.bin"
[[ ! -s "$records/qemu-stdin.log" ]] ||
    fail "task3 unexpectedly sent an RT-Thread serial command"
assert_reaped "$(cat "$records/qemu.pid")"

for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
    : > "$records/cargo.log"
    : > "$records/qemu.log"
    : > "$records/qemu-stdin.log"
    fault_output="$tmp/$profile-output"
    if ! run_fault_runner "$fault_output" "$profile" >/dev/null; then
        cat "$fault_output/console.log" >&2
        fail "$profile lifecycle run failed"
    fi
    expected_rtthread="$fixtures/rtthread-normal.bin"
    assert_mode_contract "task3-fault/$profile" \
        "console=ttyAMA0 rdinit=/init task2.count=1000 task2.fault=none task3.frames=3 task3.fault=$profile" \
        "$expected_rtthread"
    [[ -s "$fault_output/fault-event.json" ]] ||
        fail "$profile did not run the real fault result gate"
    [[ ! -s "$records/qemu-stdin.log" ]] ||
        fail "$profile unexpectedly sent an RT-Thread serial command"
    assert_reaped "$(cat "$records/qemu.pid")"
done

for label in qemu axvisor linux-kernel linux-initramfs rtthread \
    linux-vmconfig rtthread-vmconfig model protocol-source protocol-header; do
    grep -Eq "^ARTIFACT name=$label path=/.* sha256=[0-9a-f]{64}$" \
        "$normal_output/manifest.txt" || fail "manifest is missing $label hash"
done
for vmconfig in linux rtthread; do
    persisted="$normal_output/vmconfig-$vmconfig.toml"
    [[ -s "$persisted" ]] ||
        fail "successful run did not preserve the $vmconfig VM config"
    grep -Eq "^ARTIFACT name=$vmconfig-vmconfig path=$persisted sha256=[0-9a-f]{64}$" \
        "$normal_output/manifest.txt" ||
        fail "manifest does not reference the persisted $vmconfig VM config"
done
grep -Fxq 'raw_qemu_exit=143' "$normal_output/manifest.txt" ||
    fail "manifest did not preserve the raw marker-complete QEMU status"
grep -Fxq 'termination_reason=marker-complete' "$normal_output/manifest.txt" ||
    fail "manifest did not record marker-complete termination"
grep -Fxq 'qemu_exit=0' "$normal_output/manifest.txt" ||
    fail "manifest did not record the computed normalized QEMU status"
[[ -s "$normal_output/console.log" ]] || fail "normal console log was not preserved"
for output_path in \
    "$normal_output/axvisor.bin" "$normal_output/manifest.txt" \
    "$normal_output/console.log" \
    "$normal_output/linux.log" "$normal_output/rtthread.log" \
    "$normal_output/frames.csv" "$normal_output/summary.raw.json" \
    "$normal_output/summary.json"; do
    [[ -w "$output_path" ]] || fail "caller output is not writable: $output_path"
done

for forbidden in 'pkill' 'killall' 'mcast=' 'tap,' 'ip link add' 'brctl'; do
    ! grep -Fq -- "$forbidden" "$RUNNER" ||
        fail "runner contains forbidden process/network operation: $forbidden"
done

expect_failure "unknown option was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode smoke --output "$tmp/invalid" --unknown
expect_failure "out-of-range task3 frame count was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode smoke --task3-frames 601 \
    --output "$tmp/invalid-frames"
expect_failure "zero task3 frame count was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode smoke --task3-frames 0 \
    --output "$tmp/zero-frames"
expect_failure "zero task2 count was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode smoke --task2-count 0 \
    --output "$tmp/zero-task2"
expect_failure "zero build timeout was accepted" \
    env "${common_env[@]}" TASK123_BUILD_TIMEOUT_S=0 \
    "$RUNNER" --mode smoke --output "$tmp/zero-build-timeout"
expect_failure "phase timeout above the limit was accepted" \
    env "${common_env[@]}" TASK123_PHASE_TIMEOUT_S=86401 \
    "$RUNNER" --mode smoke --output "$tmp/large-phase-timeout"
expect_failure "out-of-range realtime sample count was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode realtime-suite \
    --rtbench-samples 100001 --output "$tmp/invalid-samples"
expect_failure "zero realtime sample count was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode realtime-suite \
    --rtbench-samples 0 --output "$tmp/zero-samples"
expect_failure "out-of-range stability duration was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode stability --seconds 3601 \
    --output "$tmp/invalid-seconds"
expect_failure "zero stability duration was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode stability --seconds 0 \
    --output "$tmp/zero-seconds"
expect_failure "missing Task 3 fault profile was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode task3-fault \
    --output "$tmp/missing-fault"
expect_failure "normal Task 3 fault profile was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode task3-fault \
    --task3-fault normal --output "$tmp/normal-fault"
expect_failure "mode-inapplicable option was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode task3 --seconds 1 \
    --output "$tmp/invalid-mode-option"
expect_failure "missing output parent was accepted" \
    env "${common_env[@]}" "$RUNNER" --mode smoke \
    --output "$tmp/missing-parent/output"

source_nested="$fixtures/source-input/nested-output"
expect_failure "output nested in a source input was accepted" \
    env "${common_env[@]}" \
    TASK123_ADDITIONAL_SOURCE_INPUTS="$fixtures/source-input" \
    "$RUNNER" --mode smoke --output "$source_nested"

: > "$records/qemu.log"
build_output="$tmp/build-failure"
expect_failure "build failure returned success" \
    run_runner "$build_output" FAKE_BUILD_FAIL=1
[[ -s "$tmp/failure.out" ]] || fail "build failure discarded its diagnostic"
[[ ! -s "$records/qemu.log" ]] || fail "QEMU started after build failure"

: > "$records/qemu.log"
gate_output="$tmp/gate-failure"
expect_failure "result-gate failure returned success" \
    run_runner "$gate_output" FAKE_QEMU_BEHAVIOR=duplicate
if [[ ! -s "$gate_output/console.log" ]]; then
    cat "$tmp/failure.out" >&2
    fail "result-gate failure discarded console log"
fi
gate_pid="$(cat "$records/qemu.pid")"
assert_reaped "$gate_pid"

: > "$records/qemu.log"
marker_output="$tmp/marker-failure"
expect_failure "marker failure returned success" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=missing TASK123_TIMEOUT_S=2 \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$marker_output"
[[ -e "$marker_output/console.log" ]] || fail "marker failure discarded console log"
marker_pid="$(cat "$records/qemu.pid")"
assert_reaped "$marker_pid"

: > "$records/qemu.log"
qemu_failure_output="$tmp/qemu-failure"
expect_failure "nonzero QEMU returned success" \
    run_runner "$qemu_failure_output" FAKE_QEMU_BEHAVIOR=fail
[[ -e "$qemu_failure_output/console.log" ]] ||
    fail "nonzero QEMU discarded console log"
qemu_failure_pid="$(cat "$records/qemu.pid")"
assert_reaped "$qemu_failure_pid"

: > "$records/qemu.log"
complete_nonzero_output="$tmp/complete-nonzero"
expect_failure "complete markers hid a nonzero QEMU exit" \
    run_runner "$complete_nonzero_output" FAKE_QEMU_BEHAVIOR=complete-nonzero
grep -Fq 'TASK123_LINUX_END status=PASS' "$complete_nonzero_output/console.log" ||
    fail "complete-nonzero run did not preserve its complete console"
grep -Fq 'unexpected QEMU exit code 17' "$tmp/failure.out" ||
    fail "runner did not validate the raw nonzero QEMU status"
if [[ -e "$complete_nonzero_output/manifest.txt" ]] &&
   grep -Fq 'result_gate=PASS' "$complete_nonzero_output/manifest.txt"; then
    fail "complete-nonzero run published a PASS manifest"
fi
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
control_failure_output="$tmp/control-failure"
expect_failure "realtime-control failure returned success" \
    run_runner "$control_failure_output" FAKE_QEMU_BEHAVIOR=hang FAKE_CONTROL_FAIL=1
[[ -e "$control_failure_output/console.log" ]] ||
    fail "realtime-control failure discarded console log"
control_failure_pid="$(cat "$records/qemu.pid")"
assert_reaped "$control_failure_pid"

: > "$records/qemu.log"
timeout_output="$tmp/timeout"
expect_failure "timeout returned success" \
    run_runner "$timeout_output" FAKE_QEMU_BEHAVIOR=hang TASK123_TIMEOUT_S=1
[[ -e "$timeout_output/console.log" ]] || fail "timeout discarded console log"
timeout_pid="$(cat "$records/qemu.pid")"
assert_reaped "$timeout_pid"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
feeder_timeout_output="$tmp/feeder-timeout"
expect_failure "missing benchmark completion marker returned success" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=missing-benchmark \
    FAKE_QEMU_EXPECT_COMMAND='benchmark 2' TASK123_TIMEOUT_S=1 \
    "$RUNNER" --mode realtime-suite --rtbench-samples 2 --task2-count 2 \
    --output "$feeder_timeout_output"
[[ -s "$feeder_timeout_output/console.log" ]] ||
    fail "feeder timeout discarded console log"
grep -Fxq 'command=benchmark 2' "$records/qemu-stdin.log" ||
    fail "feeder timeout did not send the realtime command"
feeder_timeout_pid="$(cat "$records/qemu.pid")"
assert_reaped "$feeder_timeout_pid"

: > "$records/qemu.log"
for no_feeder_case in smoke task3 task3-fault; do
    no_feeder_output="$tmp/linux-failure-$no_feeder_case"
    no_feeder_start_ns=$(date +%s%N)
    case "$no_feeder_case" in
        smoke)
            expect_failure "Linux failure in smoke mode returned success" \
                run_runner "$no_feeder_output" \
                FAKE_QEMU_BEHAVIOR=linux-fail TASK123_TIMEOUT_S=3
            ;;
        task3)
            expect_failure "Linux failure in task3 mode returned success" \
                env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=linux-fail \
                TASK123_TIMEOUT_S=3 "$RUNNER" --mode task3 --task3-frames 3 \
                --output "$no_feeder_output"
            ;;
        task3-fault)
            expect_failure "Linux failure in task3-fault mode returned success" \
                env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=linux-fail \
                TASK123_TIMEOUT_S=3 "$RUNNER" --mode task3-fault \
                --task3-fault drop-status --task3-frames 3 \
                --output "$no_feeder_output"
            ;;
    esac
    no_feeder_elapsed_ms=$(( ($(date +%s%N) - no_feeder_start_ns) / 1000000 ))
    [[ "$no_feeder_elapsed_ms" -lt 2000 ]] ||
        fail "Linux failure in $no_feeder_case mode waited for the full timeout"
    grep -Fq 'TASK123_LINUX_END status=FAIL' \
        "$no_feeder_output/console.log" ||
        fail "Linux failure in $no_feeder_case mode was not preserved"
    grep -Fq 'failure-marker' "$tmp/failure.out" ||
        fail "Linux failure in $no_feeder_case mode lacked failure-marker diagnostics"
    assert_reaped "$(cat "$records/qemu.pid")"
done

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
linux_failure_output="$tmp/linux-failure"
linux_failure_start_ns=$(date +%s%N)
expect_failure "explicit Linux failure returned success" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=linux-fail \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode stability --seconds 1 --task2-count 2 \
    --output "$linux_failure_output"
linux_failure_elapsed_ms=$(( ($(date +%s%N) - linux_failure_start_ns) / 1000000 ))
[[ "$linux_failure_elapsed_ms" -lt 2000 ]] ||
    fail "explicit Linux failure waited for the full timeout"
grep -Fq 'TASK123_LINUX_END status=FAIL' \
    "$linux_failure_output/console.log" ||
    fail "explicit Linux failure was not preserved"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
task2_failure_output="$tmp/task2-failure"
task2_failure_start_ns=$(date +%s%N)
expect_failure "Task 2 failure waited for the full timeout" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=linux-task2-fail \
    FAKE_QEMU_EXPECT_COMMAND='benchmark 2' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode realtime-suite --rtbench-samples 2 --task2-count 2 \
    --output "$task2_failure_output"
task2_failure_elapsed_ms=$(( ($(date +%s%N) - task2_failure_start_ns) / 1000000 ))
[[ "$task2_failure_elapsed_ms" -lt 2000 ]] ||
    fail "Task 2 failure did not fail promptly"
grep -Fq 'TASK2_LINUX_END status=FAIL' "$task2_failure_output/console.log" ||
    fail "Task 2 failure was not preserved"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
benchmark_failure_output="$tmp/benchmark-failure"
benchmark_failure_start_ns=$(date +%s%N)
expect_failure "explicit benchmark failure waited for the full timeout" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=benchmark-fail \
    FAKE_QEMU_EXPECT_COMMAND='benchmark 2' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode realtime-suite --rtbench-samples 2 --task2-count 2 \
    --output "$benchmark_failure_output"
benchmark_failure_elapsed_ms=$(( ($(date +%s%N) - benchmark_failure_start_ns) / 1000000 ))
[[ "$benchmark_failure_elapsed_ms" -lt 2000 ]] ||
    fail "explicit benchmark failure did not fail promptly"
grep -Fq 'RTBENCH_END status=FAIL' "$benchmark_failure_output/console.log" ||
    fail "explicit benchmark failure was not preserved"
grep -Fq 'failure-marker' \
    "$tmp/failure.out" ||
    fail "explicit benchmark failure did not retain a focused diagnostic"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
timer_limit_output="$tmp/stability-timer-limit"
if ! env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=stability-timer-limit \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=3 \
    TASK123_ALLOW_QEMU_TIMER_LIMIT=1 \
    "$RUNNER" --mode stability --seconds 1 --task2-count 2 \
    --output "$timer_limit_output" >/dev/null; then
    [[ ! -f "$timer_limit_output/console.log" ]] || cat "$timer_limit_output/console.log" >&2
    fail "explicit QEMU timer-limit mode did not preserve the completed run"
fi
grep -Fxq 'result_gate=PASS_WITH_QEMU_TIMER_LIMIT' \
    "$timer_limit_output/manifest.txt" ||
    fail "QEMU timer-limit run was not explicitly marked in the manifest"
[[ -s "$timer_limit_output/linux.log" && -s "$timer_limit_output/rtthread.log" ]] ||
    fail "QEMU timer-limit run did not publish authenticated guest logs"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
stability_failure_output="$tmp/stability-failure"
stability_failure_start_ns=$(date +%s%N)
expect_failure "explicit stability failure waited for the full timeout" \
    env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=stability-fail \
    FAKE_QEMU_EXPECT_COMMAND='rtbench_stability 1' TASK123_TIMEOUT_S=3 \
    "$RUNNER" --mode stability --seconds 1 --task2-count 2 \
    --output "$stability_failure_output"
stability_failure_elapsed_ms=$(( ($(date +%s%N) - stability_failure_start_ns) / 1000000 ))
[[ "$stability_failure_elapsed_ms" -lt 2000 ]] ||
    fail "explicit stability failure followed by DONE did not fail promptly"
grep -Fq 'RTBENCH_STABILITY_END status=FAIL' \
    "$stability_failure_output/console.log" ||
    fail "explicit stability failure was not preserved"
grep -Fq 'failure-marker' \
    "$tmp/failure.out" ||
    fail "explicit stability failure did not retain a focused diagnostic"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
build_timeout_output="$tmp/build-timeout"
rm -f -- "$records/fake-cargo.pid" "$records/fake-cargo-child.pid"
sleep 30 &
unrelated_pid=$!
build_timeout_start_ns=$(date +%s%N)
expect_failure "cargo build timeout returned success" \
    timeout -k 2 10 env "${common_env[@]}" \
    FAKE_CARGO_BEHAVIOR=hang TASK123_BUILD_TIMEOUT_S=1 \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$build_timeout_output"
build_timeout_elapsed_ms=$(( ($(date +%s%N) - build_timeout_start_ns) / 1000000 ))
[[ "$build_timeout_elapsed_ms" -lt 9000 ]] ||
    fail "cargo build timeout did not stop the phase promptly"
[[ -s "$tmp/failure.out" ]] ||
    fail "cargo build timeout discarded its diagnostic"
grep -Fq 'cargo-xtask-axvisor-build timed out after 1s' \
    "$tmp/failure.out" ||
    fail "cargo build timeout did not preserve timeout diagnostics"
[[ ! -s "$records/qemu.log" ]] ||
    fail "QEMU started after cargo build timeout"
kill -0 "$unrelated_pid" 2>/dev/null ||
    fail "cargo build timeout terminated an unrelated process"
kill -TERM "$unrelated_pid"
wait "$unrelated_pid" 2>/dev/null || true
[[ -s "$records/fake-cargo.pid" && -s "$records/fake-cargo-child.pid" ]] ||
    fail "fake cargo did not record its process tree"
assert_reaped "$(cat "$records/fake-cargo.pid")"
assert_reaped "$(cat "$records/fake-cargo-child.pid")"

: > "$records/qemu.log"
term_output="$tmp/term"
rm -f -- "$records/qemu.pid"
env "${common_env[@]}" FAKE_QEMU_BEHAVIOR=hang TASK123_TIMEOUT_S=30 \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$term_output" >"$tmp/term.out" 2>&1 &
runner_pid=$!
wait_for_file_record "$records/qemu.pid" || fail "TERM test did not start QEMU"
term_qemu_pid="$(cat "$records/qemu.pid")"
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
term_rc=$?
set -e
[[ "$term_rc" -ne 0 ]] || fail "TERM returned success"
assert_reaped "$term_qemu_pid"
[[ -e "$term_output/console.log" ]] || fail "TERM discarded console log"

: > "$records/qemu.log"
run_runner "$tmp/cargo-symlink" CARGO="$tools/cargo-shim"

cache="$tmp/shared-artifact-cache"
cache_output="$tmp/cache-first"
env "${common_env[@]}" TASK123_SHARED_ARTIFACT_DIR="$cache" \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$cache_output" >"$tmp/cache-first.stdout" || {
    [[ ! -f "$cache_output/console.log" ]] || cat "$cache_output/console.log" >&2
    fail "cache population run failed"
}
for cached_name in \
    linux-kernel linux-initramfs.cpio model_weights.h rootfs.img \
    rtthread.bin rtthread.bin.meta.json starryos-task123.bin; do
    [[ -s "$cache/$cached_name" ]] || fail "cache did not populate $cached_name"
done

cache_second_output="$tmp/cache-second"
cache_env=(
    PATH="$tools:$PATH"
    QEMU="$tools/qemu-system-aarch64"
    CARGO="$tools/cargo"
    AARCH64_STRIP="$tools/aarch64-linux-gnu-strip"
    AARCH64_OBJCOPY="$tools/aarch64-linux-gnu-objcopy"
    QEMU_REALTIME_CONTROL="$tools/realtime-control"
    FAKE_CARGO_LOG="$records/cargo.log"
    FAKE_CARGO_PID_FILE="$records/fake-cargo.pid"
    FAKE_CARGO_CHILD_PID_FILE="$records/fake-cargo-child.pid"
    FAKE_CARGO_VMCONFIG_DIR="$records"
    FAKE_AXVISOR_ELF="$fixtures/generated/axvisor"
    FAKE_QEMU_LOG="$records/qemu.log"
    FAKE_QEMU_PID_FILE="$records/qemu.pid"
    FAKE_QEMU_TIMERSLACK_LOG="$records/qemu-timerslack.log"
    FAKE_QEMU_STDIN_LOG="$records/qemu-stdin.log"
    FAKE_CONTROL_LOG="$records/control.log"
)
: > "$records/cargo.log"
: > "$records/qemu.log"
env "${cache_env[@]}" TASK123_SHARED_ARTIFACT_DIR="$cache" \
    RTTHREAD_REQUIRE_IMAGE_METADATA=1 \
    "$RUNNER" --app-guest starryos --mode smoke --task2-count 2 \
    --task3-frames 3 --output "$cache_second_output" >"$tmp/cache-second.stdout" || {
    [[ ! -f "$cache_second_output/console.log" ]] || cat "$cache_second_output/console.log" >&2
    fail "cache reuse run failed"
}
! grep -Fq 'xtask image pull qemu-aarch64' "$records/cargo.log" ||
    fail "cache reuse unexpectedly pulled rootfs"
! grep -Fq 'STEP linux-image-build' "$tmp/cache-second.stdout" ||
    fail "cache reuse unexpectedly rebuilt Linux images"
grep -Fq 'app_guest=starryos' "$cache_second_output/manifest.txt" ||
    fail "cache reuse did not run the StarryOS guest"
assert_reaped "$(cat "$records/qemu.pid")"

expect_failure "output nested in shared cache was accepted" \
    env "${cache_env[@]}" TASK123_SHARED_ARTIFACT_DIR="$cache" \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$cache/nested-output"

echo "PASS: Task 1/2/3 runner owns and reaps one AxVisor QEMU"
