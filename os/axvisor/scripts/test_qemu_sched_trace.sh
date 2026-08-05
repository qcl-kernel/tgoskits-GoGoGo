#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXVISOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${AXVISOR_ROOT}/configs/qemu/qemu-aarch64-three-guest-net-trace.toml"
COLLECTOR="${SCRIPT_DIR}/collect_qemu_sched_trace.sh"
PROBE_SOURCE="${SCRIPT_DIR}/qemu_sched_probe.c"
THREAD_MAP_HELPER="${SCRIPT_DIR}/qemu_sched_thread_map.sh"
TEST_ROOT=""
THREAD_FIXTURE_PID=""
COLLECTOR_FIXTURE_PID=""

fail() {
  echo "[qemu-sched-trace] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$THREAD_FIXTURE_PID" ]; then
    kill "$THREAD_FIXTURE_PID" 2>/dev/null || true
    wait "$THREAD_FIXTURE_PID" 2>/dev/null || true
    THREAD_FIXTURE_PID=""
  fi
  if [ -n "$COLLECTOR_FIXTURE_PID" ]; then
    kill "$COLLECTOR_FIXTURE_PID" 2>/dev/null || true
    wait "$COLLECTOR_FIXTURE_PID" 2>/dev/null || true
    COLLECTOR_FIXTURE_PID=""
  fi
  if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "$CONFIG" ] || fail "missing diagnostic QEMU config"
[ -x "$COLLECTOR" ] || fail "collector must be executable"
[ -f "$PROBE_SOURCE" ] || fail "missing high-resolution schedstat probe"
command -v cc >/dev/null 2>&1 || fail "cc is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

for pattern in \
  '"-pidfile"' \
  '"-qmp"' \
  '"-trace"' \
  'cpu_exec_start' \
  'cpu_exec_end'; do
  rg -q --fixed-strings "$pattern" "$CONFIG" || fail "config is missing ${pattern}"
done

rg -q --fixed-strings 'for (cpu_index = 0; cpu_index < expected; cpu_index++)' "$COLLECTOR" \
  || fail "QMP map validator must not shadow awk's index() builtin"

for pattern in \
  'query-cpus-fast' \
  '/proc/${QEMU_PID}/cmdline' \
  '."thread-id"' \
  'cpu_exec_(start|end)' \
  'qemu_trace_report'; do
  rg -q --fixed-strings "$pattern" "$COLLECTOR" || fail "collector is missing ${pattern}"
done

for pattern in \
  '/schedstat' \
  'run_delay_ns' \
  'delta_run_delay_ns' \
  'delta_exec_ns'; do
  rg -q --fixed-strings "$pattern" "$PROBE_SOURCE" \
    || fail "high-resolution probe is missing ${pattern}"
done

for pattern in \
  'AXVISOR_QEMU_TRACE_MANIFEST' \
  'AXVISOR_QEMU_TRACE_KERNEL_SNAPSHOT' \
  'AXVISOR_QEMU_TRACE_EXPECTED_SMP' \
  'CLOCK_MONOTONIC_RAW' \
  'qemu_sched_probe' \
  'manifest_status=verified' \
  'qmp_status=verified'; do
  rg -q --fixed-strings "$pattern" "$COLLECTOR" \
    || fail "collector is missing synchronized-evidence contract: ${pattern}"
done

for pattern in \
  'qemu-sampled-thread-map.tsv' \
  'qemu-schedstat.raw.tsv' \
  'qemu_sched_thread_map.sh' \
  'vcpu_thread_map_rows=' \
  'sample_thread_rows='; do
  rg -q --fixed-strings "$pattern" "$COLLECTOR" \
    || fail "collector is missing sampled-thread integration: ${pattern}"
done

rg -q --fixed-strings \
  'role\tcpu_index\ttid\tsamples\ttotal_exec_ns\ttotal_run_delay_ns\tmax_delta_exec_ns\tmax_delta_run_delay_ns\tmax_sample_gap_ns' \
  "$COLLECTOR" || fail "collector summary header is missing sampled thread roles"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/axvisor-qemu-sched-probe-test.XXXXXX")"

THREAD_FIXTURE="${TEST_ROOT}/thread-fixture.tsv"
EXITED_WORKER_TRIGGER="${TEST_ROOT}/exit-worker"
python3 - "$THREAD_FIXTURE" "$EXITED_WORKER_TRIGGER" <<'PY' &
import os
import sys
import threading
import time

output_path = sys.argv[1]
exit_worker_path = sys.argv[2]
worker_tids = [None, None]
ready = threading.Barrier(3)


def worker(index):
    worker_tids[index] = threading.get_native_id()
    ready.wait()
    if index == 1:
        while not os.path.exists(exit_worker_path):
            time.sleep(0.01)
        return
    time.sleep(300)


for worker_index in range(2):
    threading.Thread(target=worker, args=(worker_index,)).start()

ready.wait()
with open(output_path, "w", encoding="ascii") as output:
    output.write(f"{os.getpid()}\t{worker_tids[0]}\t{worker_tids[1]}\n")

time.sleep(300)
PY
THREAD_FIXTURE_PID=$!

for ((attempt = 0; attempt < 500; attempt++)); do
  [ -s "$THREAD_FIXTURE" ] && break
  kill -0 "$THREAD_FIXTURE_PID" 2>/dev/null || fail "thread fixture exited before startup"
  sleep 0.01
done
[ -s "$THREAD_FIXTURE" ] || fail "thread fixture did not become ready"
IFS=$'\t' read -r fixture_pid vcpu0_tid vcpu1_tid <"$THREAD_FIXTURE"
[ "$fixture_pid" = "$THREAD_FIXTURE_PID" ] || fail "thread fixture PID is inconsistent"

QMP_VCPU_MAP="${TEST_ROOT}/qemu-vcpu-thread-map.tsv"
SAMPLED_THREAD_MAP="${TEST_ROOT}/qemu-sampled-thread-map.tsv"
printf '0\t%s\tcpu0\n1\t%s\tcpu1\n' "$vcpu0_tid" "$vcpu1_tid" >"$QMP_VCPU_MAP"
"$THREAD_MAP_HELPER" build "$fixture_pid" "$QMP_VCPU_MAP" "$SAMPLED_THREAD_MAP"
EXPECTED_SAMPLED_THREAD_MAP="${TEST_ROOT}/expected-sampled-thread-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nvcpu\t0\t%s\tcpu0\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$EXPECTED_SAMPLED_THREAD_MAP"
cmp -s "$EXPECTED_SAMPLED_THREAD_MAP" "$SAMPLED_THREAD_MAP" \
  || fail "sampled thread map does not contain exactly the main loop and two vCPUs"
[ "$(($(wc -l <"$SAMPLED_THREAD_MAP") - 1))" -eq 3 ] \
  || fail "sampled thread map must contain exactly three data rows"

RAW_SAMPLES="${TEST_ROOT}/qemu-schedstat.raw.tsv"
ANNOTATED_SAMPLES="${TEST_ROOT}/qemu-schedstat.tsv"
printf 'host_monotonic_raw_ns\ttid\tstate\tprocessor\twchan\texec_ns\trun_delay_ns\ttimeslices\tdelta_exec_ns\tdelta_run_delay_ns\n' >"$RAW_SAMPLES"
printf '100\t0%s\tR\t2\t0\t11\t12\t13\t14\t15\n' "$vcpu1_tid" >>"$RAW_SAMPLES"
printf '101\t%s\tS\t3\tfutex_wait\t21\t22\t23\t24\t25\n' "$fixture_pid" >>"$RAW_SAMPLES"
printf '102\t%s\tR\t4\t0\t31\t32\t33\t34\t35\n' "$vcpu0_tid" >>"$RAW_SAMPLES"
"$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$RAW_SAMPLES" "$ANNOTATED_SAMPLES"
EXPECTED_ANNOTATED_SAMPLES="${TEST_ROOT}/expected-qemu-schedstat.tsv"
printf 'host_monotonic_raw_ns\trole\tcpu_index\ttid\tstate\tprocessor\twchan\texec_ns\trun_delay_ns\ttimeslices\tdelta_exec_ns\tdelta_run_delay_ns\n' >"$EXPECTED_ANNOTATED_SAMPLES"
printf '100\tvcpu\t1\t0%s\tR\t2\t0\t11\t12\t13\t14\t15\n' "$vcpu1_tid" >>"$EXPECTED_ANNOTATED_SAMPLES"
printf '101\tmain-loop\tNA\t%s\tS\t3\tfutex_wait\t21\t22\t23\t24\t25\n' "$fixture_pid" >>"$EXPECTED_ANNOTATED_SAMPLES"
printf '102\tvcpu\t0\t%s\tR\t4\t0\t31\t32\t33\t34\t35\n' "$vcpu0_tid" >>"$EXPECTED_ANNOTATED_SAMPLES"
cmp -s "$EXPECTED_ANNOTATED_SAMPLES" "$ANNOTATED_SAMPLES" \
  || fail "annotated samples do not preserve fields or add the expected roles"

REGULAR_OUTPUT="${TEST_ROOT}/regular-existing-output.tsv"
printf 'replace-this-output\n' >"$REGULAR_OUTPUT"
"$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$RAW_SAMPLES" "$REGULAR_OUTPUT"
cmp -s "$EXPECTED_ANNOTATED_SAMPLES" "$REGULAR_OUTPUT" \
  || fail "annotation did not atomically replace a regular existing output"

directory_destination_failures=0
DIRECTORY_OUTPUT="${TEST_ROOT}/directory-output.tsv"
mkdir "$DIRECTORY_OUTPUT"
printf 'preserve-directory-content\n' >"${DIRECTORY_OUTPUT}/sentinel"
if "$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$RAW_SAMPLES" "$DIRECTORY_OUTPUT" 2>/dev/null; then
  directory_destination_failures=$((directory_destination_failures + 1))
fi
[ -f "${DIRECTORY_OUTPUT}/sentinel" ] \
  && [ "$(find "$DIRECTORY_OUTPUT" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] \
  || directory_destination_failures=$((directory_destination_failures + 1))

SYMLINK_TARGET="${TEST_ROOT}/symlink-target"
SYMLINK_OUTPUT="${TEST_ROOT}/symlink-output.tsv"
mkdir "$SYMLINK_TARGET"
printf 'preserve-symlink-target-content\n' >"${SYMLINK_TARGET}/sentinel"
ln -s "$SYMLINK_TARGET" "$SYMLINK_OUTPUT"
if "$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$RAW_SAMPLES" "$SYMLINK_OUTPUT" 2>/dev/null; then
  directory_destination_failures=$((directory_destination_failures + 1))
fi
[ -L "$SYMLINK_OUTPUT" ] \
  && [ -f "${SYMLINK_TARGET}/sentinel" ] \
  && [ "$(find "$SYMLINK_TARGET" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] \
  || directory_destination_failures=$((directory_destination_failures + 1))

[ "$directory_destination_failures" -eq 0 ] \
  || fail "helper accepted or modified a directory destination"

UNKNOWN_RAW_SAMPLES="${TEST_ROOT}/unknown-qemu-schedstat.raw.tsv"
head -n 1 "$RAW_SAMPLES" >"$UNKNOWN_RAW_SAMPLES"
printf '200\t999999999\tR\t0\t0\t1\t2\t3\t4\t5\n' >>"$UNKNOWN_RAW_SAMPLES"
ATOMIC_OUTPUT="${TEST_ROOT}/atomic-output.tsv"
printf 'keep-existing-output\n' >"$ATOMIC_OUTPUT"
if "$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$UNKNOWN_RAW_SAMPLES" "$ATOMIC_OUTPUT" 2>/dev/null; then
  fail "annotate accepted a raw-sample TID absent from the sampled map"
fi
cmp -s "$ATOMIC_OUTPUT" <(printf 'keep-existing-output\n') \
  || fail "failed annotation replaced or partially wrote the final output"

DUPLICATE_QMP_MAP="${TEST_ROOT}/duplicate-qemu-vcpu-thread-map.tsv"
printf '0\t%s\tcpu0\n1\t%s\tcpu1\n' "$vcpu0_tid" "$vcpu0_tid" >"$DUPLICATE_QMP_MAP"
DUPLICATE_OUTPUT="${TEST_ROOT}/duplicate-output.tsv"
if "$THREAD_MAP_HELPER" build "$fixture_pid" "$DUPLICATE_QMP_MAP" "$DUPLICATE_OUTPUT" 2>/dev/null; then
  fail "build accepted duplicate sampled TIDs"
fi
[ ! -e "$DUPLICATE_OUTPUT" ] || fail "failed duplicate build left a partial output"

semantic_validation_failures=0
DUPLICATE_CPU_QMP_MAP="${TEST_ROOT}/duplicate-cpu-qemu-vcpu-thread-map.tsv"
DUPLICATE_CPU_OUTPUT="${TEST_ROOT}/duplicate-cpu-output.tsv"
printf '0\t%s\tcpu0\n0\t%s\tcpu1\n' "$vcpu0_tid" "$vcpu1_tid" >"$DUPLICATE_CPU_QMP_MAP"
printf 'preserve-duplicate-cpu-output\n' >"$DUPLICATE_CPU_OUTPUT"
if "$THREAD_MAP_HELPER" build "$fixture_pid" "$DUPLICATE_CPU_QMP_MAP" "$DUPLICATE_CPU_OUTPUT" 2>/dev/null; then
  semantic_validation_failures=$((semantic_validation_failures + 1))
fi
cmp -s "$DUPLICATE_CPU_OUTPUT" <(printf 'preserve-duplicate-cpu-output\n') \
  || semantic_validation_failures=$((semantic_validation_failures + 1))

expect_annotate_rejection() {
  local sampled_map="$1"
  local label="$2"
  local output="${TEST_ROOT}/${label}-output.tsv"

  printf 'preserve-malformed-map-output\n' >"$output"
  if "$THREAD_MAP_HELPER" annotate "$sampled_map" "$RAW_SAMPLES" "$output" 2>/dev/null; then
    semantic_validation_failures=$((semantic_validation_failures + 1))
  fi
  cmp -s "$output" <(printf 'preserve-malformed-map-output\n') \
    || semantic_validation_failures=$((semantic_validation_failures + 1))
}

MISSING_MAIN_MAP="${TEST_ROOT}/missing-main-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nvcpu\t2\t%s\tmain-as-vcpu\nvcpu\t0\t%s\tcpu0\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$MISSING_MAIN_MAP"
expect_annotate_rejection "$MISSING_MAIN_MAP" "missing-main"

INVALID_MAIN_CPU_MAP="${TEST_ROOT}/invalid-main-cpu-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\t0\t%s\tmain-loop\nvcpu\t1\t%s\tcpu0\nvcpu\t2\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$INVALID_MAIN_CPU_MAP"
expect_annotate_rejection "$INVALID_MAIN_CPU_MAP" "invalid-main-cpu"

EXTRA_MAIN_MAP="${TEST_ROOT}/extra-main-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nmain-loop\tNA\t%s\tcpu0\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$EXTRA_MAIN_MAP"
expect_annotate_rejection "$EXTRA_MAIN_MAP" "extra-main"

INVALID_VCPU_CPU_MAP="${TEST_ROOT}/invalid-vcpu-cpu-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nvcpu\tNA\t%s\tcpu0\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$INVALID_VCPU_CPU_MAP"
expect_annotate_rejection "$INVALID_VCPU_CPU_MAP" "invalid-vcpu-cpu"

UNKNOWN_ROLE_MAP="${TEST_ROOT}/unknown-role-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nio-thread\t0\t%s\tcpu0\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$UNKNOWN_ROLE_MAP"
expect_annotate_rejection "$UNKNOWN_ROLE_MAP" "unknown-role"

DUPLICATE_CPU_SAMPLED_MAP="${TEST_ROOT}/duplicate-cpu-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nvcpu\t0\t%s\tcpu0\nvcpu\t0\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$DUPLICATE_CPU_SAMPLED_MAP"
expect_annotate_rejection "$DUPLICATE_CPU_SAMPLED_MAP" "duplicate-cpu"

EMPTY_NAME_MAP="${TEST_ROOT}/empty-name-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nvcpu\t0\t%s\t\nvcpu\t1\t%s\tcpu1\n' \
  "$fixture_pid" "$vcpu0_tid" "$vcpu1_tid" >"$EMPTY_NAME_MAP"
expect_annotate_rejection "$EMPTY_NAME_MAP" "empty-name"

[ "$semantic_validation_failures" -eq 0 ] \
  || fail "helper accepted malformed sampled-map semantics or replaced sentinel output"

FOREIGN_QMP_MAP="${TEST_ROOT}/foreign-qemu-vcpu-thread-map.tsv"
printf '0\t%s\tcpu0\n1\t%s\tforeign\n' "$vcpu0_tid" "$$" >"$FOREIGN_QMP_MAP"
FOREIGN_OUTPUT="${TEST_ROOT}/foreign-output.tsv"
if "$THREAD_MAP_HELPER" build "$fixture_pid" "$FOREIGN_QMP_MAP" "$FOREIGN_OUTPUT" 2>/dev/null; then
  fail "build accepted a TID outside the fixture process"
fi
[ ! -e "$FOREIGN_OUTPUT" ] || fail "failed foreign-TID build left a partial output"

PROBE="${TEST_ROOT}/qemu_sched_probe"
cc -std=c11 -O2 -Wall -Wextra -Werror -o "$PROBE" "$PROBE_SOURCE"

RAW_CONSOLE="${TEST_ROOT}/console.log"
TIMESTAMPED_CONSOLE="${TEST_ROOT}/console-monotonic.tsv"
printf 'first line\nsecond line\n' \
  | "$PROBE" timestamp-stream "$RAW_CONSOLE" "$TIMESTAMPED_CONSOLE"
cmp -s "$RAW_CONSOLE" <(printf 'first line\nsecond line\n') \
  || fail "timestamp-stream changed the raw console"
awk -F '\t' '
  NR == 1 {
    if ($0 != "host_monotonic_raw_ns\tline_no\tconsole") exit 1
    next
  }
  $1 !~ /^[0-9]+$/ || $2 != NR - 1 || $1 < previous { exit 1 }
  NR == 2 && $3 != "first line" { exit 1 }
  NR == 3 && $3 != "second line" { exit 1 }
  { previous = $1 }
  END { exit NR == 3 ? 0 : 1 }
' "$TIMESTAMPED_CONSOLE" || fail "timestamp-stream output is not monotonic or complete"

SCHEDSTAT="${TEST_ROOT}/schedstat.tsv"
"$PROBE" schedstat "$SCHEDSTAT" 40 500 "$$"
awk -F '\t' '
  NR == 1 {
    if ($0 != "host_monotonic_raw_ns\ttid\tstate\tprocessor\twchan\texec_ns\trun_delay_ns\ttimeslices\tdelta_exec_ns\tdelta_run_delay_ns") exit 1
    next
  }
  $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[RSDITtXZP]$/ ||
    $4 !~ /^[0-9]+$/ || $5 == "" || $9 < 0 || $10 < 0 || $1 <= previous { exit 1 }
  { previous = $1 }
  END { exit NR >= 20 ? 0 : 1 }
' "$SCHEDSTAT" || fail "high-resolution schedstat probe output is invalid"

RESTRICTED_PROC_OUTPUT="${TEST_ROOT}/restricted-proc-schedstat.tsv"
if AXVISOR_PROC_ROOT="/proc/${fixture_pid}/task" \
  "$PROBE" schedstat "$RESTRICTED_PROC_OUTPUT" 10 500 "$$" 2>/dev/null; then
  fail "probe resolved a global TID outside the fixture task directory"
fi
[ ! -e "$RESTRICTED_PROC_OUTPUT" ] \
  || fail "failed restricted-root probe created an output file"

touch "$EXITED_WORKER_TRIGGER"
for ((attempt = 0; attempt < 500; attempt++)); do
  [ ! -d "/proc/${fixture_pid}/task/${vcpu1_tid}" ] && break
  sleep 0.01
done
[ ! -d "/proc/${fixture_pid}/task/${vcpu1_tid}" ] \
  || fail "fixture worker did not exit"
EXITED_WORKER_MAP="${TEST_ROOT}/exited-worker-qemu-vcpu-thread-map.tsv"
EXITED_WORKER_OUTPUT="${TEST_ROOT}/exited-worker-output.tsv"
printf '1\t%s\texited-worker\n' "$vcpu1_tid" >"$EXITED_WORKER_MAP"
printf 'preserve-exited-worker-output\n' >"$EXITED_WORKER_OUTPUT"
if "$THREAD_MAP_HELPER" build "$fixture_pid" "$EXITED_WORKER_MAP" "$EXITED_WORKER_OUTPUT" 2>/dev/null; then
  fail "helper accepted an exited mapped worker"
fi
cmp -s "$EXITED_WORKER_OUTPUT" <(printf 'preserve-exited-worker-output\n') \
  || fail "failed exited-worker build replaced the final output"

for tool in jq realpath sha256sum socat; do
  command -v "$tool" >/dev/null 2>&1 || fail "${tool} is required for collector fixture"
done

FAKE_QEMU="${TEST_ROOT}/qemu-system-aarch64"
COLLECTOR_FIXTURE_INFO="${TEST_ROOT}/collector-fixture.tsv"
COLLECTOR_QMP_SOCKET="${TEST_ROOT}/collector-qmp.sock"
ln -s "$(command -v python3)" "$FAKE_QEMU"
"$FAKE_QEMU" - "$COLLECTOR_FIXTURE_INFO" "$COLLECTOR_QMP_SOCKET" -smp 2 <<'PY' &
import json
import ctypes
import os
import socket
import sys
import threading
import time

output_path = sys.argv[1]
qmp_path = sys.argv[2]
worker_tids = [None, None]
ready = threading.Barrier(3)
libc = ctypes.CDLL(None)


def worker(index):
    thread_name = ctypes.c_char_p(f"cpu ) {index}".encode("ascii"))
    if libc.prctl(15, thread_name, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_NAME) failed")
    worker_tids[index] = threading.get_native_id()
    ready.wait()
    time.sleep(300)


for worker_index in range(2):
    threading.Thread(target=worker, args=(worker_index,)).start()

ready.wait()
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(qmp_path)
server.listen(1)
with open(output_path, "w", encoding="ascii") as output:
    output.write(f"{os.getpid()}\t{worker_tids[0]}\t{worker_tids[1]}\n")

connection, _ = server.accept()
with connection:
    request = b""
    while b"query-cpus-fast" not in request:
        chunk = connection.recv(4096)
        if not chunk:
            break
        request += chunk
    responses = [
        {"return": {}},
        {
            "return": [
                {"cpu-index": 1, "thread-id": worker_tids[1], "name": "cpu1"},
                {"cpu-index": 0, "thread-id": worker_tids[0], "name": "cpu0"},
            ]
        },
    ]
    connection.sendall(b"".join((json.dumps(item) + "\n").encode("ascii") for item in responses))

server.close()
time.sleep(300)
PY
COLLECTOR_FIXTURE_PID=$!

for ((attempt = 0; attempt < 500; attempt++)); do
  [ -s "$COLLECTOR_FIXTURE_INFO" ] && [ -S "$COLLECTOR_QMP_SOCKET" ] && break
  kill -0 "$COLLECTOR_FIXTURE_PID" 2>/dev/null || fail "collector fixture exited before startup"
  sleep 0.01
done
[ -s "$COLLECTOR_FIXTURE_INFO" ] && [ -S "$COLLECTOR_QMP_SOCKET" ] \
  || fail "collector fixture did not become ready"
IFS=$'\t' read -r collector_pid collector_vcpu0_tid collector_vcpu1_tid <"$COLLECTOR_FIXTURE_INFO"
[ "$collector_pid" = "$COLLECTOR_FIXTURE_PID" ] \
  || fail "collector fixture PID is inconsistent"

COLLECTOR_ARTIFACT_DIR="${TEST_ROOT}/collector-artifacts"
COLLECTOR_OUTPUT_DIR="${TEST_ROOT}/collector-output"
mkdir "$COLLECTOR_ARTIFACT_DIR"
printf 'elf-artifact\n' >"${COLLECTOR_ARTIFACT_DIR}/guest.elf"
printf 'raw-artifact\n' >"${COLLECTOR_ARTIFACT_DIR}/guest.raw"
printf 'vm-config-artifact\n' >"${COLLECTOR_ARTIFACT_DIR}/vm.toml"
COLLECTOR_MANIFEST="${COLLECTOR_ARTIFACT_DIR}/manifest.tsv"
printf 'version\t1\t\n' >"$COLLECTOR_MANIFEST"
for artifact_role in elf raw vm-config; do
  case "$artifact_role" in
    elf) artifact_path="${COLLECTOR_ARTIFACT_DIR}/guest.elf" ;;
    raw) artifact_path="${COLLECTOR_ARTIFACT_DIR}/guest.raw" ;;
    vm-config) artifact_path="${COLLECTOR_ARTIFACT_DIR}/vm.toml" ;;
  esac
  artifact_hash="$(sha256sum -- "$artifact_path")"
  printf '%s\t%s\t%s\n' "$artifact_role" "$artifact_path" "${artifact_hash%% *}" >>"$COLLECTOR_MANIFEST"
done

AXVISOR_QEMU_TRACE_QMP="$COLLECTOR_QMP_SOCKET" \
AXVISOR_QEMU_TRACE_MANIFEST="$COLLECTOR_MANIFEST" \
AXVISOR_QEMU_TRACE_KERNEL_SNAPSHOT="${COLLECTOR_ARTIFACT_DIR}/guest.raw" \
AXVISOR_QEMU_TRACE_EXPECTED_SMP=2 \
AXVISOR_QEMU_TRACE_INTERVAL_US=5000 \
  "$COLLECTOR" "$collector_pid" "$COLLECTOR_OUTPUT_DIR" 1

EXPECTED_COLLECTOR_MAP="${TEST_ROOT}/expected-collector-sampled-map.tsv"
printf 'role\tcpu_index\ttid\tqemu_name\nmain-loop\tNA\t%s\tmain-loop\nvcpu\t1\t%s\tcpu1\nvcpu\t0\t%s\tcpu0\n' \
  "$collector_pid" "$collector_vcpu1_tid" "$collector_vcpu0_tid" >"$EXPECTED_COLLECTOR_MAP"
cmp -s "$EXPECTED_COLLECTOR_MAP" "${COLLECTOR_OUTPUT_DIR}/qemu-sampled-thread-map.tsv" \
  || fail "collector sampled map did not preserve main-loop and QMP input order"
awk -F '\t' -v main_tid="$collector_pid" -v cpu1_tid="$collector_vcpu1_tid" -v cpu0_tid="$collector_vcpu0_tid" '
  NR == 1 {
    if ($0 != "role\tcpu_index\ttid\tsamples\ttotal_exec_ns\ttotal_run_delay_ns\tmax_delta_exec_ns\tmax_delta_run_delay_ns\tmax_sample_gap_ns") exit 1
    next
  }
  NR == 2 && ($1 != "main-loop" || $2 != "NA" || $3 != main_tid) { exit 1 }
  NR == 3 && ($1 != "vcpu" || $2 != 1 || $3 != cpu1_tid) { exit 1 }
  NR == 4 && ($1 != "vcpu" || $2 != 0 || $3 != cpu0_tid) { exit 1 }
  END { exit NR == 4 ? 0 : 1 }
' "${COLLECTOR_OUTPUT_DIR}/qemu-schedstat-summary.tsv" \
  || fail "collector summary did not preserve sampled-map order"
rg -q '^vcpu_thread_map_rows=2$' "${COLLECTOR_OUTPUT_DIR}/metadata.txt" \
  || fail "collector metadata has the wrong vCPU map count"
rg -q '^sample_thread_rows=3$' "${COLLECTOR_OUTPUT_DIR}/metadata.txt" \
  || fail "collector metadata has the wrong sampled thread count"
awk -F '=' '$1 == "sample_rows" && $2 > 0 { found=1 } END { exit found ? 0 : 1 }' \
  "${COLLECTOR_OUTPUT_DIR}/metadata.txt" \
  || fail "collector metadata has no annotated sample rows"

compiler_line="$(rg -n --fixed-strings 'cc -std=c11 -O2 -Wall -Wextra -Werror' "$COLLECTOR" | cut -d: -f1)"
qmp_snapshot_line="$(rg -n --fixed-strings "query-cpus-fast" "$COLLECTOR" | sed -n '1s/:.*//p')"
[ "$compiler_line" -lt "$qmp_snapshot_line" ] \
  || fail "collector must compile the probe before the QMP/thread snapshot"
rg -q --fixed-strings 'AXVISOR_PROC_ROOT="/proc/${QEMU_PID}/task"' "$COLLECTOR" \
  || fail "collector does not constrain probe reads to the QEMU task directory"
[ "$(rg -c --fixed-strings 'verify_sampled_task_identities' "$COLLECTOR")" -ge 3 ] \
  || fail "collector does not capture and recheck sampled task identities"

echo "[qemu-sched-trace] executable synchronized-evidence contract passed"
