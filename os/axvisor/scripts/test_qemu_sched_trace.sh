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

fail() {
  echo "[qemu-sched-trace] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$THREAD_FIXTURE_PID" ]; then
    kill "$THREAD_FIXTURE_PID" 2>/dev/null || true
    wait "$THREAD_FIXTURE_PID" 2>/dev/null || true
  fi
  if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT INT TERM

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
python3 - "$THREAD_FIXTURE" <<'PY' &
import os
import sys
import threading
import time

output_path = sys.argv[1]
worker_tids = [None, None]
ready = threading.Barrier(3)


def worker(index):
    worker_tids[index] = threading.get_native_id()
    ready.wait()
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

echo "[qemu-sched-trace] executable synchronized-evidence contract passed"
