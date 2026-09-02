#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_rtipc_test.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "$RUNNER" || \
    fail "runner must be sourceable for behavior tests"

if ! RTIPC_FAULT_PROFILE=invalid bash -c 'source "$1"' _ "$RUNNER" \
    >/dev/null 2>&1; then
    fail "sourcing must not execute runtime option validation"
fi

source_path="$tmp/source-path"
mkdir -p "$source_path"
ln -s "$(command -v dirname)" "$source_path/dirname"
if ! PATH="$source_path" /bin/bash -e -c 'source "$1"' _ "$RUNNER" \
    >/dev/null 2>&1; then
    fail "sourcing must not require QEMU to be installed"
fi

# shellcheck source=/dev/null
source "$RUNNER"
set +e

artifact="$tmp/artifact.bin"
printf '%s\n' 'runtime artifact' > "$artifact"
resolved_artifact="$(resolve_runtime_artifact test-artifact "$artifact" 2>/dev/null)"
resolve_rc=$?
[[ "$resolve_rc" -eq 0 ]] || \
    fail "existing runtime artifact must resolve (got $resolve_rc)"
[[ "$resolved_artifact" == "$(realpath -e -- "$artifact")" ]] || \
    fail "runtime artifact resolution must return its canonical path"

resolve_runtime_artifact missing-artifact "$tmp/missing.bin" >/dev/null 2>&1
missing_artifact_rc=$?
[[ "$missing_artifact_rc" -ne 0 ]] || \
    fail "missing runtime artifact must be rejected"

ARTIFACT_LOG="$tmp/artifacts.log"
: > "$ARTIFACT_LOG"
record_runtime_artifact test-artifact "$artifact" >/dev/null 2>&1
record_rc=$?
[[ "$record_rc" -eq 0 ]] || \
    fail "runtime artifact manifest recording failed (got $record_rc)"
artifact_sha="$(sha256sum "$artifact" | awk '{print $1}')"
grep -Fxq \
    "ARTIFACT name=test-artifact path=$(realpath -e -- "$artifact") sha256=$artifact_sha" \
    "$ARTIFACT_LOG" || fail "runtime artifact manifest is incomplete"

sha_mock_dir="$tmp/sha-mock"
mkdir -p "$sha_mock_dir"
cat > "$sha_mock_dir/sha256sum" <<'EOF'
#!/usr/bin/env bash
exit 41
EOF
chmod +x "$sha_mock_dir/sha256sum"
artifact_manifest_before="$(sha256sum "$ARTIFACT_LOG")"
PATH="$sha_mock_dir:$PATH" \
record_runtime_artifact digest-failure "$artifact" >/dev/null 2>&1
digest_failure_rc=$?
[[ "$digest_failure_rc" -ne 0 ]] || \
    fail "sha256sum failure must propagate from artifact recording"
[[ "$(sha256sum "$ARTIFACT_LOG")" == "$artifact_manifest_before" ]] || \
    fail "failed digest calculation must not append an artifact record"

validate_cli_arguments unexpected >/dev/null 2>&1
cli_rc=$?
[[ "$cli_rc" -eq 2 ]] || \
    fail "unexpected positional arguments must return 2 (got $cli_rc)"

(
    RTIPC_COUNT=0
    validate_runtime_options
) >/dev/null 2>&1
count_rc=$?
[[ "$count_rc" -eq 2 ]] || \
    fail "invalid RTIPC_COUNT must return 2 (got $count_rc)"

(
    RTIPC_TIMEOUT_S=invalid
    validate_runtime_options
) >/dev/null 2>&1
timeout_rc=$?
[[ "$timeout_rc" -eq 2 ]] || \
    fail "invalid RTIPC_TIMEOUT_S must return 2 (got $timeout_rc)"

(
    LOG="$tmp/shared.log"
    QEMU_LOG="$tmp/shared.log"
    ARTIFACT_LOG="$tmp/artifacts.log"
    CPU_LOAD_LOG=
    RTBENCH_TIMING_LOG="$tmp/timing.log"
    validate_output_paths
) >/dev/null 2>&1
output_collision_rc=$?
[[ "$output_collision_rc" -eq 2 ]] || \
    fail "colliding output paths must return 2 (got $output_collision_rc)"

(
    LOG="$tmp/missing-parent/guest.log"
    QEMU_LOG="$tmp/qemu-output.log"
    ARTIFACT_LOG="$tmp/artifacts.log"
    CPU_LOAD_LOG=
    RTBENCH_TIMING_LOG="$tmp/timing.log"
    validate_output_paths
) >/dev/null 2>&1
missing_output_parent_rc=$?
[[ "$missing_output_parent_rc" -eq 2 ]] || \
    fail "missing output parent must return 2 (got $missing_output_parent_rc)"

(
    LOG="$artifact"
    QEMU_LOG="$tmp/qemu-output.log"
    ARTIFACT_LOG="$tmp/artifacts.log"
    CPU_LOAD_LOG=
    RTBENCH_TIMING_LOG="$tmp/timing.log"
    validate_output_paths
    validate_output_input_collisions test-artifact "$artifact"
) >/dev/null 2>&1
input_output_collision_rc=$?
[[ "$input_output_collision_rc" -eq 2 ]] || \
    fail "input/output path collision must return 2 (got $input_output_collision_rc)"

output_hardlink="$tmp/output-hardlink.log"
ln "$artifact" "$output_hardlink"
(
    LOG="$artifact"
    QEMU_LOG="$output_hardlink"
    ARTIFACT_LOG="$tmp/artifacts.log"
    CPU_LOAD_LOG=
    RTBENCH_TIMING_LOG="$tmp/timing.log"
    validate_output_paths
) >/dev/null 2>&1
output_hardlink_rc=$?
[[ "$output_hardlink_rc" -eq 2 ]] || \
    fail "hard-linked output paths must return 2 (got $output_hardlink_rc)"

input_hardlink="$tmp/input-hardlink.log"
ln "$artifact" "$input_hardlink"
(
    LOG="$input_hardlink"
    QEMU_LOG="$tmp/qemu-output.log"
    ARTIFACT_LOG="$tmp/artifacts.log"
    CPU_LOAD_LOG=
    RTBENCH_TIMING_LOG="$tmp/timing.log"
    validate_output_paths
    validate_output_input_collisions test-artifact "$artifact"
) >/dev/null 2>&1
input_hardlink_rc=$?
[[ "$input_hardlink_rc" -eq 2 ]] || \
    fail "hard-linked input/output paths must return 2 (got $input_hardlink_rc)"

(
    QEMU_UCLAMP_MIN=1025
    validate_runtime_options
) >/dev/null 2>&1
uclamp_rc=$?
[[ "$uclamp_rc" -eq 2 ]] || \
    fail "out-of-range QEMU_UCLAMP_MIN must return 2 (got $uclamp_rc)"

QEMU=/definitely/missing \
RTIPC_FAULT_PROFILE=invalid \
bash "$RUNNER" >"$tmp/invalid-before-qemu.out" 2>&1
invalid_before_qemu_rc=$?
[[ "$invalid_before_qemu_rc" -eq 2 ]] || \
    fail "invalid options must return 2 before QEMU resolution (got $invalid_before_qemu_rc)"
if grep -Fq 'Building RT-Thread' "$tmp/invalid-before-qemu.out"; then
    fail "invalid options must not start a build"
fi

QEMU=/definitely/missing \
QEMU_UCLAMP_MIN=1025 \
bash "$RUNNER" >"$tmp/invalid-uclamp-before-qemu.out" 2>&1
invalid_uclamp_before_qemu_rc=$?
[[ "$invalid_uclamp_before_qemu_rc" -eq 2 ]] || \
    fail "invalid uclamp must return 2 before QEMU resolution (got $invalid_uclamp_before_qemu_rc)"
if grep -Fq 'Building RT-Thread' "$tmp/invalid-uclamp-before-qemu.out"; then
    fail "invalid uclamp must not start a build"
fi

QEMU=/definitely/missing \
LOG="$tmp/missing-main-parent/guest.log" \
bash "$RUNNER" >"$tmp/invalid-output-before-qemu.out" 2>&1
invalid_output_before_qemu_rc=$?
[[ "$invalid_output_before_qemu_rc" -eq 2 ]] || \
    fail "invalid output must return 2 before QEMU resolution (got $invalid_output_before_qemu_rc)"
if grep -Fq 'Building RT-Thread' "$tmp/invalid-output-before-qemu.out"; then
    fail "invalid output must not start a build"
fi

if grep -Fq '/tmp/axvisor-rtipc-strip' "$RUNNER"; then
    fail "runner must not use a shared fixed strip path"
fi
grep -Fq 'axvisor-strip.XXXXXX' "$RUNNER" || \
    fail "runner must create a private strip directory"

mktemp_mock_dir="$tmp/mktemp-mock"
mkdir -p "$mktemp_mock_dir"
cat > "$mktemp_mock_dir/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
chmod +x "$mktemp_mock_dir/mktemp"
(
    serial_tmp=
    serial_socket=
    serial_input=
    RTBENCH_TIMING_STATE=
    PATH="$mktemp_mock_dir:$PATH"
    create_serial_session
) >/dev/null 2>&1
serial_mktemp_rc=$?
[[ "$serial_mktemp_rc" -ne 0 ]] || \
    fail "serial-session mktemp failure must propagate"

strip_root="$tmp/strip-root"
strip_mock_dir="$tmp/strip-mock"
mkdir -p "$strip_root" "$strip_mock_dir"
printf '%s\n' 'axvisor elf fixture' > "$strip_root/axvisor"
cat > "$strip_mock_dir/aarch64-linux-gnu-strip" <<'EOF'
#!/usr/bin/env bash
exit 37
EOF
cat > "$strip_mock_dir/aarch64-linux-gnu-objcopy" <<'EOF'
#!/usr/bin/env bash
exit 38
EOF
chmod +x "$strip_mock_dir/aarch64-linux-gnu-strip" \
    "$strip_mock_dir/aarch64-linux-gnu-objcopy"
(
    STAGING=
    RTTHREAD_RUNTIME_DIR=
    LINUX_RUNTIME_DIR=
    STRIP_TMP_DIR=
    trap cleanup_build_artifacts EXIT
    PATH="$strip_mock_dir:$PATH"
    build_axvisor_binary "$strip_root/axvisor" "$strip_root/axvisor.bin" \
        "$strip_root"
) >/dev/null 2>&1
strip_failure_rc=$?
[[ "$strip_failure_rc" -eq 37 ]] || \
    fail "strip failure status must propagate (got $strip_failure_rc)"
if find "$strip_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'axvisor-strip.*' | grep -q .; then
    fail "strip failure left its private temporary directory"
fi

control="$tmp/control"
cat > "$control" <<'EOF'
#!/usr/bin/env bash
echo "mock realtime control failed" >&2
exit 37
EOF
chmod +x "$control"
QEMU_REALTIME_CONTROL="$control"
QEMU_LOG="$tmp/qemu.log"
apply_qemu_realtime_control_or_fail 4321 1024 >/dev/null 2>&1
control_rc=$?
[[ "$control_rc" -eq 37 ]] || \
    fail "realtime-control failure must preserve its exit status (got $control_rc)"

run_until_mock="$tmp/run-until-mock"
cat > "$run_until_mock" <<'EOF'
#!/usr/bin/env bash
exit 37
EOF
chmod +x "$run_until_mock"
RUN_UNTIL="$run_until_mock"
run_nonbenchmark_until_markers 5 "$tmp/mock.log" MARKER -- ignored-command \
    >/dev/null 2>&1
nonbenchmark_rc=$?
[[ "$nonbenchmark_rc" -eq 37 ]] || \
    fail "non-benchmark runner must preserve helper status 37 (got $nonbenchmark_rc)"

long_helper_pid_file="$tmp/long-helper.pid"
cat > "$run_until_mock" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$MOCK_HELPER_PID_FILE"
trap 'exit 143' TERM
while :; do
    sleep 1
done
EOF
(
    RUN_UNTIL="$run_until_mock"
    MOCK_HELPER_PID_FILE="$long_helper_pid_file"
    export MOCK_HELPER_PID_FILE
    run_nonbenchmark_until_markers 30 "$tmp/mock.log" MARKER -- ignored-command
) >/dev/null 2>&1 &
nonbenchmark_runner_pid=$!
helper_deadline_ns=$(( $(date +%s%N) + 2000000000 ))
while [[ ! -s "$long_helper_pid_file" ]]; do
    if ! kill -0 "$nonbenchmark_runner_pid" 2>/dev/null ||
       [[ "$(date +%s%N)" -ge "$helper_deadline_ns" ]]; then
        fail "non-benchmark helper did not start"
    fi
    sleep 0.01
done
long_helper_pid="$(cat "$long_helper_pid_file")"
kill -TERM "$nonbenchmark_runner_pid"
wait "$nonbenchmark_runner_pid"
nonbenchmark_signal_rc=$?
[[ "$nonbenchmark_signal_rc" -eq 143 ]] || \
    fail "non-benchmark TERM must return 143 (got $nonbenchmark_signal_rc)"
sleep 0.05
if kill -0 "$long_helper_pid" 2>/dev/null; then
    kill "$long_helper_pid" 2>/dev/null || true
    fail "non-benchmark TERM left its helper running"
fi

LOG="$tmp/guest.log"
: > "$LOG"
RTBENCH_START_MODE=concurrent
RTIPC_TIMEOUT_S=5
run_pid=99999999
start_ns="$(date +%s%N)"
feed_rtthread_benchmark_command >/dev/null 2>&1
feeder_rc=$?
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
[[ "$feeder_rc" -ne 0 ]] || fail "feeder must fail when the QEMU runner exits"
[[ "$elapsed_ms" -lt 1000 ]] || \
    fail "feeder must not wait for the full timeout after QEMU exits (${elapsed_ms}ms)"

printf '%s\n' '[VM 3] msh />' > "$LOG"
HOST_BENCHMARK_TIMING=:
RTBENCH_TIMING_STATE="$tmp/timing.state"
RTBENCH_COMMAND='benchmark 1'
RTBENCH_DONE_MARKER='RTBENCH_END status='
run_pid=99999999
start_ns="$(date +%s%N)"
feed_rtthread_benchmark_command >/dev/null 2>&1
completion_rc=$?
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
[[ "$completion_rc" -ne 0 ]] || \
    fail "feeder must fail if QEMU exits while waiting for benchmark completion"
[[ "$elapsed_ms" -lt 1000 ]] || \
    fail "completion wait must stop when QEMU exits (${elapsed_ms}ms)"

feeder_pid=
wait_for_feeder >/dev/null 2>&1
absent_feeder_rc=$?
[[ "$absent_feeder_rc" -eq 0 ]] || \
    fail "waiting without a started feeder must be a no-op (got $absent_feeder_rc)"

(
    serial_tmp="$tmp/serial"
    mkdir -p "$serial_tmp"
    feeder_pid=
    cpu_monitor_pid=
    socat_pid=
    run_pid=
    handle_serial_signal 143
    echo "continued after signal"
) >/dev/null 2>&1
signal_rc=$?
[[ "$signal_rc" -eq 143 ]] || \
    fail "signal cleanup must preserve the interrupted exit status (got $signal_rc)"

actual_signal_dir="$tmp/actual-signal"
continued_marker="$tmp/continued-after-term"
mkdir -p "$actual_signal_dir"
(
    serial_tmp="$actual_signal_dir"
    feeder_pid=
    cpu_monitor_pid=
    socat_pid=
    run_pid=
    install_serial_signal_handlers
    kill -TERM "$BASHPID"
    : > "$continued_marker"
) >/dev/null 2>&1
actual_signal_rc=$?
[[ "$actual_signal_rc" -eq 143 ]] || \
    fail "TERM trap must exit with status 143 (got $actual_signal_rc)"
[[ ! -e "$actual_signal_dir" ]] || \
    fail "TERM trap must clean the serial session"
[[ ! -e "$continued_marker" ]] || \
    fail "runner must not continue after TERM"

set -e
echo "RT-IPC runner lifecycle contract: PASS"
