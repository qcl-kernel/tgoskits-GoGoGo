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

wait_for_file() {
    local path=$1
    local attempts=0
    while [[ ! -s "$path" && "$attempts" -lt 500 ]]; do
        sleep 0.01
        attempts=$((attempts + 1))
    done
    [[ -s "$path" ]]
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
mkdir -p "$fixtures/source-input" "$tools" "$records"
for artifact in linux-kernel initramfs.cpio rtthread-normal.bin \
    rtthread-drop-status.bin rtthread-delayed-server.bin rootfs.img model.bin; do
    printf '%s\n' "$artifact" > "$fixtures/$artifact"
done

cat > "$tools/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_CARGO_LOG"
printf '\n' >> "$FAKE_CARGO_LOG"
if [[ "$*" == "xtask image pull qemu-aarch64 -o "* ]]; then
    output_dir=${@: -1}
    mkdir -p "$output_dir/pulled"
    case "${FAKE_ROOTFS_BEHAVIOR:-one}" in
        zero) ;;
        one) printf 'pulled rootfs\n' > "$output_dir/pulled/rootfs.img" ;;
        multiple)
            printf 'rootfs one\n' > "$output_dir/pulled/rootfs.img"
            mkdir -p "$output_dir/second"
            printf 'rootfs two\n' > "$output_dir/second/rootfs.img"
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
cat <<'LOG'
[VM 1] LINUX_SMP_READY configured=2 online=0-1 nproc=2
[VM 1] TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876
[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877
[VM 3] msh />
LOG
printf '[VM 1] [client] fault injection: force disconnect at request=%s\n' \
    "$((task2_count / 2))"
echo '[VM 1] [client] reconnect complete recovery_ms=1 attempts=1'
for payload in 64 256 1024; do
    printf '[VM 1] --- Payload %sB ---\n' "$payload"
    printf '[VM 1] sent=%s recv=%s\n' "$task2_count" "$task2_count"
    if [[ "$payload" == 64 ]]; then
        echo '[VM 1] request_timeouts=0 protocol_errors=0 reconnects=1'
        echo '[VM 1] transport: retrans=1 timeouts=0 dup=0 reorder=0 errors=0'
    else
        echo '[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0'
        echo '[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0'
    fi
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
printf '[VM 3] TASK3_RTOS_FINAL requests=%s errors=%s duplicates=%s applied_steps=%s retries=%s\n' \
    "$records" "$rtos_errors" "$rtos_duplicates" "$records" "$rtos_retries"
case "$task3_fault" in
    drop-status) echo '[VM 3] TASK3_FAULT_DROP_STATUS dropped=1' ;;
    duplicate-frame) echo '[VM 1] TASK3_FAULT_DUPLICATE frame=0 duplicate=1 actuator_before=0 actuator_after=0 applied_delta=0' ;;
    delayed-server) echo '[VM 3] TASK3_FAULT_DELAYED_SERVER delay_ms=3000' ;;
    malformed) echo '[VM 1] TASK3_FAULT_MALFORMED schema2=rejected short=rejected crc=rejected rejected=3 actuator_before=0 actuator_after=0 applied_delta=0' ;;
esac
}

emit_linux_finals() {
    cat <<'LOG'
[VM 1] TASK2_LINUX_END status=PASS
[VM 1] TASK3_LINUX_END status=PASS
[VM 1] TASK123_LINUX_END status=PASS
LOG
}

emit_benchmark() {
    local command=$1
    local value=${command##* }
    if [[ "$command" == benchmark\ * ]]; then
        printf 'RTBENCH_BEGIN samples=%s frequency=1000000\n' "$value"
        for run in 1 2 3; do
            for metric in timer_jitter callback_exec; do
                printf 'RTBENCH metric=%s run=%s expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
                    "$metric" "$run" "$value" "$value"
            done
        done
        for metric in preemption irq; do
            printf 'RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
                "$metric" "$value" "$value"
        done
        echo 'RTBENCH_END status=PASS'
    else
        local expected=$((value * 1000 - 1))
        printf 'RTBENCH_STABILITY_BEGIN seconds=%s expected=%s\n' "$value" "$expected"
        for metric in stability_jitter callback_exec; do
            printf 'RTBENCH metric=%s run=1 expected=%s collected=%s missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n' \
                "$metric" "$expected" "$expected"
        done
        printf 'RTBENCH_STABILITY_END status=PASS expected=%s collected=%s missing=0\n' "$expected" "$expected"
        echo 'RTBENCH_STABILITY_DONE'
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

if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == complete-nonzero ]]; then
    sleep 0.2
fi
emit_initial
if [[ -n "${FAKE_QEMU_EXPECT_COMMAND:-}" ]]; then
    wait_for_control ']'
    echo 'select-vm3' >> "$FAKE_QEMU_STDIN_LOG"
    benchmark_command=
    while IFS= read -r -n 1 command_byte; do
        [[ "$command_byte" == $'\r' ]] && break
        benchmark_command+=$command_byte
    done
    [[ "$benchmark_command" == "$FAKE_QEMU_EXPECT_COMMAND" ]]
    printf 'command=%s\n' "$benchmark_command" >> "$FAKE_QEMU_STDIN_LOG"
    if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" != missing-benchmark ]]; then
        emit_benchmark "$benchmark_command"
    fi
    wait_for_control '['
    echo 'select-vm1' >> "$FAKE_QEMU_STDIN_LOG"
fi
emit_linux_finals
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
    RTTHREAD_NORMAL_IMAGE="$fixtures/rtthread-normal.bin"
    RTTHREAD_DROP_STATUS_IMAGE="$fixtures/rtthread-drop-status.bin"
    RTTHREAD_DELAYED_SERVER_IMAGE="$fixtures/rtthread-delayed-server.bin"
    ROOTFS_IMAGE="$fixtures/rootfs.img"
    TASK123_MODEL_IMAGE="$fixtures/model.bin"
    FAKE_CARGO_LOG="$records/cargo.log"
    FAKE_CARGO_PID_FILE="$records/fake-cargo.pid"
    FAKE_CARGO_CHILD_PID_FILE="$records/fake-cargo-child.pid"
    FAKE_CARGO_VMCONFIG_DIR="$records"
    FAKE_AXVISOR_ELF="$fixtures/generated/axvisor"
    FAKE_QEMU_LOG="$records/qemu.log"
    FAKE_QEMU_PID_FILE="$records/qemu.pid"
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

[[ -x "$RUNNER" ]] || fail "run_task123.sh is missing or not executable"

normal_output="$tmp/normal-output"
if ! run_runner "$normal_output" >/dev/null; then
    [[ ! -f "$normal_output/runner.log" ]] || cat "$normal_output/runner.log" >&2
    fail "normal fake run failed"
fi
[[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
    fail "runner did not launch exactly one QEMU"
qemu_pid="$(cat "$records/qemu.pid")"
assert_reaped "$qemu_pid"

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
grep -Fq 'task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal' \
    "$records/1.toml" || fail "guest controls were not written through Linux VM config"
[[ "$(cat "$records/2.image")" == "$(realpath -e "$fixtures/rtthread-normal.bin")" ]] ||
    fail "smoke mode did not select the normal RT-Thread image"
assert_mode_contract smoke \
    'console=ttyAMA0 rdinit=/init task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal' \
    "$fixtures/rtthread-normal.bin"
grep -Fq 'AxVisor host cmdline' "$RUNNER" ||
    fail "runner does not document that outer -append belongs to the AxVisor host"

for realtime_case in 'realtime-suite:benchmark 2' 'stability:rtbench_stability 1'; do
    realtime_mode=${realtime_case%%:*}
    realtime_command=${realtime_case#*:}
    realtime_output="$tmp/$realtime_mode-output"
    : > "$records/cargo.log"
    : > "$records/qemu.log"
    : > "$records/qemu-stdin.log"
    if [[ "$realtime_mode" == realtime-suite ]]; then
        realtime_args=(--rtbench-samples 2 --task2-count 2)
    else
        realtime_args=(--seconds 1 --task2-count 2)
    fi
    if ! env "${common_env[@]}" FAKE_QEMU_EXPECT_COMMAND="$realtime_command" \
        TASK123_TIMEOUT_S=2 "$RUNNER" --mode "$realtime_mode" \
        "${realtime_args[@]}" --output "$realtime_output" >/dev/null; then
        [[ ! -f "$realtime_output/runner.log" ]] ||
            cat "$realtime_output/runner.log" >&2
        [[ ! -f "$realtime_output/console.log" ]] ||
            cat "$realtime_output/console.log" >&2
        fail "$realtime_mode feeder run failed"
    fi
    [[ "$(cat "$records/qemu-stdin.log")" == $'select-vm3\ncommand='"$realtime_command"$'\nselect-vm1' ]] ||
        fail "$realtime_mode did not perform the exact VM3 command/VM1 replay sequence"
    assert_mode_contract "$realtime_mode" \
        'console=ttyAMA0 rdinit=/init task2.count=2 task2.fault=none task3.frames=3 task3.fault=normal' \
        "$fixtures/rtthread-normal.bin"
    assert_reaped "$(cat "$records/qemu.pid")"
done

: > "$records/cargo.log"
: > "$records/qemu.log"
default_rootfs_output="$tmp/default-rootfs-output"
env "${common_env[@]}" ROOTFS_IMAGE= "$RUNNER" --mode smoke \
    --task2-count 2 --task3-frames 3 --output "$default_rootfs_output" >/dev/null ||
    fail "default rootfs pull run failed"
grep -Eq '^xtask image pull qemu-aarch64 -o /.*task123-runtime\.[^/]+/rootfs[[:space:]]*$' \
    "$records/cargo.log" || fail "runner did not pull qemu-aarch64 into its runtime directory"
grep -Eq '^ARTIFACT name=rootfs path=/.*task123-runtime\.[^/]+/rootfs/pulled/rootfs\.img sha256=[0-9a-f]{64}$' \
    "$default_rootfs_output/manifest.txt" ||
    fail "manifest did not record the uniquely pulled rootfs"
[[ "$(wc -l < "$records/qemu.log")" -eq 1 ]] ||
    fail "default rootfs run did not reach exactly one QEMU"
assert_reaped "$(cat "$records/qemu.pid")"

for rootfs_behavior in zero multiple; do
    : > "$records/cargo.log"
    : > "$records/qemu.log"
    bad_rootfs_output="$tmp/rootfs-$rootfs_behavior-output"
    expect_failure "rootfs pull with $rootfs_behavior candidates returned success" \
        env "${common_env[@]}" ROOTFS_IMAGE= \
        FAKE_ROOTFS_BEHAVIOR="$rootfs_behavior" \
        "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
        --output "$bad_rootfs_output"
    grep -Fq 'image pull must produce exactly one rootfs.img' \
        "$bad_rootfs_output/runner.log" ||
        fail "rootfs $rootfs_behavior candidate failure was not diagnosed"
    [[ ! -s "$records/qemu.log" ]] ||
        fail "QEMU started after rootfs $rootfs_behavior candidate failure"
done

: > "$records/cargo.log"
: > "$records/qemu.log"
: > "$records/qemu-stdin.log"
task3_output="$tmp/task3-output"
if ! env "${common_env[@]}" "$RUNNER" --mode task3 --task3-frames 3 \
    --output "$task3_output" >/dev/null; then
    cat "$task3_output/runner.log" >&2
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
        cat "$fault_output/runner.log" >&2
        fail "$profile lifecycle run failed"
    fi
    expected_rtthread="$fixtures/rtthread-normal.bin"
    case "$profile" in
        drop-status) expected_rtthread="$fixtures/rtthread-drop-status.bin" ;;
        delayed-server) expected_rtthread="$fixtures/rtthread-delayed-server.bin" ;;
    esac
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
grep -Fxq 'raw_qemu_exit=143' "$normal_output/manifest.txt" ||
    fail "manifest did not preserve the raw marker-complete QEMU status"
grep -Fxq 'termination_reason=marker-complete' "$normal_output/manifest.txt" ||
    fail "manifest did not record marker-complete termination"
grep -Fxq 'qemu_exit=0' "$normal_output/manifest.txt" ||
    fail "manifest did not record the computed normalized QEMU status"
[[ -s "$normal_output/console.log" && -s "$normal_output/runner.log" ]] ||
    fail "normal run logs were not preserved"
for output_path in \
    "$normal_output/axvisor.bin" "$normal_output/manifest.txt" \
    "$normal_output/console.log" "$normal_output/runner.log" \
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
[[ -s "$build_output/runner.log" ]] || fail "build failure discarded its log"
[[ ! -s "$records/qemu.log" ]] || fail "QEMU started after build failure"

: > "$records/qemu.log"
gate_output="$tmp/gate-failure"
expect_failure "result-gate failure returned success" \
    run_runner "$gate_output" FAKE_QEMU_BEHAVIOR=duplicate
if [[ ! -s "$gate_output/console.log" ]]; then
    cat "$tmp/failure.out" >&2
    [[ ! -f "$gate_output/runner.log" ]] || cat "$gate_output/runner.log" >&2
    fail "result-gate failure discarded console log"
fi
gate_pid="$(cat "$records/qemu.pid")"
assert_reaped "$gate_pid"

: > "$records/qemu.log"
marker_output="$tmp/marker-failure"
expect_failure "marker failure returned success" \
    run_runner "$marker_output" FAKE_QEMU_BEHAVIOR=missing
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
grep -Fq 'unexpected QEMU exit code 17' "$complete_nonzero_output/runner.log" ||
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
build_timeout_output="$tmp/build-timeout"
rm -f -- "$records/fake-cargo.pid" "$records/fake-cargo-child.pid"
sleep 30 &
unrelated_pid=$!
build_timeout_start_ns=$(date +%s%N)
expect_failure "cargo build timeout returned success" \
    timeout -k 2 5 env "${common_env[@]}" \
    FAKE_CARGO_BEHAVIOR=hang TASK123_BUILD_TIMEOUT_S=1 \
    "$RUNNER" --mode smoke --task2-count 2 --task3-frames 3 \
    --output "$build_timeout_output"
build_timeout_elapsed_ms=$(( ($(date +%s%N) - build_timeout_start_ns) / 1000000 ))
[[ "$build_timeout_elapsed_ms" -lt 4500 ]] ||
    fail "cargo build timeout did not stop the phase promptly"
[[ -s "$build_timeout_output/runner.log" ]] ||
    fail "cargo build timeout discarded its log"
grep -Fq 'cargo-xtask-axvisor-build timed out after 1s' \
    "$build_timeout_output/runner.log" ||
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
wait_for_file "$records/qemu.pid" || fail "TERM test did not start QEMU"
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

echo "PASS: Task 1/2/3 runner owns and reaps one AxVisor QEMU"
