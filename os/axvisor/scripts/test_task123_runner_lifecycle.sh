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
    ! kill -0 "$pid" 2>/dev/null || fail "owned fake PID was not reaped: $pid"
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
[[ "${FAKE_BUILD_FAIL:-0}" != 1 ]] || exit 41
mkdir -p "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release"
printf 'fake axvisor elf\n' > "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/axvisor"
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

cat > "$tools/pass-gate" <<'EOF'
#!/usr/bin/env bash
exit 0
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
cat <<'LOG'
[VM 1] LINUX_SMP_READY configured=2 online=0-1 nproc=2
[VM 1] TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
[VM 3] RTIPC_SERVER_READY ip=192.168.77.30 port=9876
[VM 3] TASK3_RTOS_READY ip=192.168.77.30 port=9877
[VM 1] [client] fault injection: force disconnect at request=1
[VM 1] [client] reconnect complete recovery_ms=1 attempts=1
[VM 1] --- Payload 64B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=1
[VM 1] transport: retrans=1 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 256B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 1024B ---
[VM 1] sent=2 recv=2
[VM 1] request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1] transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] RT-IPC client exited with rc=0
[VM 1] ALL TESTS COMPLETE
[VM 1] TASK2_LINUX_END status=PASS
[VM 1] TASK3_FRAME_CSV=FIXED,0,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_FRAME_CSV=FIXED,1,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_FRAME_CSV=FIXED,2,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_FRAME_CSV=AI,0,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_FRAME_CSV=AI,1,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_FRAME_CSV=AI,2,100,1,1,30000,10,0,0,0,100,2,3,0,0,0
[VM 1] TASK3_SUMMARY_JSON={"schema":1,"frames_per_mode":3,"records":6,"requests":6,"successes":6,"success_rate":1.0,"application_errors":0,"application_timeouts":0,"reconnects":0,"injected_drops":0,"elapsed_us":1000,"settling":{"fixed":{},"ai":{}}}
[VM 3] TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 applied_steps=6 retries=0
[VM 1] TASK3_LINUX_END status=PASS
[VM 1] TASK123_LINUX_END status=PASS
LOG
if [[ "${FAKE_QEMU_BEHAVIOR:-pass}" == duplicate ]]; then
    echo '[VM 1] TASK2_LINUX_END status=PASS'
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
    FAKE_CARGO_VMCONFIG_DIR="$records"
    FAKE_QEMU_LOG="$records/qemu.log"
    FAKE_QEMU_PID_FILE="$records/qemu.pid"
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
    env "${common_env[@]}" RESULT_GATE="$tools/pass-gate" \
        "$RUNNER" --mode task3-fault --task3-fault "$profile" \
        --task3-frames 3 --output "$output"
}

expect_failure() {
    local description=$1
    shift
    if "$@" >"$tmp/failure.out" 2>&1; then
        fail "$description"
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

: > "$records/qemu.log"
run_fault_runner "$tmp/drop-status-output" drop-status >/dev/null ||
    fail "drop-status selection run failed"
[[ "$(cat "$records/2.image")" == "$(realpath -e "$fixtures/rtthread-drop-status.bin")" ]] ||
    fail "drop-status mode did not select its RT-Thread image"
grep -Fq 'task3.fault=drop-status' "$records/1.toml" ||
    fail "drop-status was not written into the guest command line"
assert_reaped "$(cat "$records/qemu.pid")"

: > "$records/qemu.log"
run_fault_runner "$tmp/delayed-server-output" delayed-server >/dev/null ||
    fail "delayed-server selection run failed"
[[ "$(cat "$records/2.image")" == "$(realpath -e "$fixtures/rtthread-delayed-server.bin")" ]] ||
    fail "delayed-server mode did not select its RT-Thread image"
grep -Fq 'task3.fault=delayed-server' "$records/1.toml" ||
    fail "delayed-server was not written into the guest command line"
assert_reaped "$(cat "$records/qemu.pid")"

for label in qemu axvisor linux-kernel linux-initramfs rtthread \
    linux-vmconfig rtthread-vmconfig model protocol-source protocol-header; do
    grep -Eq "^ARTIFACT name=$label path=/.* sha256=[0-9a-f]{64}$" \
        "$normal_output/manifest.txt" || fail "manifest is missing $label hash"
done
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

echo "PASS: Task 1/2/3 runner owns and reaps one AxVisor QEMU"
