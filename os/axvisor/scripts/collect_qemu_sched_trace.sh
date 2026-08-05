#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <qemu-pid> <output-dir> [duration-seconds]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_PID="$1"
OUTPUT_DIR="$2"
DURATION_SECONDS="${3:-20}"
QMP_SOCKET="${AXVISOR_QEMU_TRACE_QMP:-}"
MANIFEST_FILE="${AXVISOR_QEMU_TRACE_MANIFEST:-}"
KERNEL_SNAPSHOT="${AXVISOR_QEMU_TRACE_KERNEL_SNAPSHOT:-}"
EXPECTED_SMP="${AXVISOR_QEMU_TRACE_EXPECTED_SMP:-}"
SAMPLE_INTERVAL_US="${AXVISOR_QEMU_TRACE_INTERVAL_US:-500}"
TRACE_FILE="${AXVISOR_QEMU_TRACE_FILE:-}"
PROBE_SOURCE="${SCRIPT_DIR}/qemu_sched_probe.c"
PROBE_BIN="${OUTPUT_DIR}/qemu_sched_probe"
QMP_OUTPUT="${OUTPUT_DIR}/qmp-query.jsonl"
THREAD_MAP="${OUTPUT_DIR}/qemu-vcpu-thread-map.tsv"
SAMPLED_THREAD_MAP="${OUTPUT_DIR}/qemu-sampled-thread-map.tsv"
RAW_SAMPLES="${OUTPUT_DIR}/qemu-schedstat.raw.tsv"
THREAD_MAP_HELPER="${SCRIPT_DIR}/qemu_sched_thread_map.sh"
SAMPLES="${OUTPUT_DIR}/qemu-schedstat.tsv"
SUMMARY="${OUTPUT_DIR}/qemu-schedstat-summary.tsv"
METADATA="${OUTPUT_DIR}/metadata.txt"
TRACE_REPORT="${OUTPUT_DIR}/qemu_trace_report.txt"

die() {
  echo "[qemu-sched-trace] ERROR: $*" >&2
  exit 1
}

sha256() {
  local output
  output="$(sha256sum -- "$1")"
  printf '%s' "${output%% *}"
}

proc_stat_starttime() {
  local stat_path="$1"
  local starttime

  [ -r "$stat_path" ] || return 1
  starttime="$(awk '
    {
      closep=0
      for (position=length($0)-1; position > 0; position--) {
        if (substr($0, position, 2) == ") ") {
          closep=position
          break
        }
      }
      if (closep == 0) exit 1
      rest=substr($0, closep+2)
      field_count=split(rest, fields, " ")
      if (field_count < 20 || fields[20] !~ /^[0-9]+$/) exit 1
      print fields[20]
    }
  ' "$stat_path")" || return 1
  [[ "$starttime" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$starttime"
}

verify_sampled_task_identities() {
  local index
  local tid
  local observed_starttime

  for index in "${!sampled_tids[@]}"; do
    tid="${sampled_tids[$index]}"
    [ -d "/proc/${QEMU_PID}/task/${tid}" ] \
      || die "sampled QEMU thread exited before evidence was finalized: tid=${tid}"
    observed_starttime="$(proc_stat_starttime "/proc/${QEMU_PID}/task/${tid}/stat")" \
      || die "cannot read sampled QEMU thread identity: tid=${tid}"
    [ "$observed_starttime" = "${sampled_task_starttimes[$index]}" ] \
      || die "sampled QEMU thread identity changed: tid=${tid}"
  done
}

[[ "$QEMU_PID" =~ ^[0-9]+$ ]] || die "QEMU PID must be numeric"
[[ "$DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "duration must be a positive integer"
[[ "$SAMPLE_INTERVAL_US" =~ ^[1-9][0-9]*$ ]] || die "sample interval must be positive"
[[ "$EXPECTED_SMP" =~ ^[1-9][0-9]*$ ]] || die "AXVISOR_QEMU_TRACE_EXPECTED_SMP is required"
[ -d "/proc/${QEMU_PID}" ] || die "QEMU process does not exist: ${QEMU_PID}"
[ -S "$QMP_SOCKET" ] || die "AXVISOR_QEMU_TRACE_QMP must name a live QMP socket"
[ -f "$MANIFEST_FILE" ] || die "AXVISOR_QEMU_TRACE_MANIFEST is required"
[ -f "$KERNEL_SNAPSHOT" ] || die "AXVISOR_QEMU_TRACE_KERNEL_SNAPSHOT is required"
[ -f "$PROBE_SOURCE" ] || die "missing high-resolution probe source: ${PROBE_SOURCE}"
[ -x "$THREAD_MAP_HELPER" ] || die "missing QEMU thread map helper: ${THREAD_MAP_HELPER}"
for tool in cc jq realpath sha256sum socat; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: ${tool}"
done

mkdir -p "$OUTPUT_DIR"
comm="$(cat "/proc/${QEMU_PID}/comm")"
mapfile -d '' -t qemu_argv <"/proc/${QEMU_PID}/cmdline"
[ "${#qemu_argv[@]}" -gt 0 ] || die "QEMU command line is empty"
[[ "${qemu_argv[0]}" == *qemu-system-aarch64* ]] \
  || die "PID is not qemu-system-aarch64: ${qemu_argv[0]}"
qemu_exe="$(realpath -- "/proc/${QEMU_PID}/exe")"
qemu_starttime="$(proc_stat_starttime "/proc/${QEMU_PID}/stat")" \
  || die "cannot read QEMU process identity"

actual_smp=""
for index in "${!qemu_argv[@]}"; do
  if [ "${qemu_argv[$index]}" = "-smp" ]; then
    smp_arg="${qemu_argv[$((index + 1))]-}"
    actual_smp="${smp_arg%%,*}"
    actual_smp="${actual_smp#cpus=}"
    break
  fi
done
[ "$actual_smp" = "$EXPECTED_SMP" ] \
  || die "QEMU -smp mismatch: expected ${EXPECTED_SMP}, observed ${actual_smp:-missing}"

manifest_hash_before="$(sha256 "$MANIFEST_FILE")"
manifest_raw_hash=""
manifest_rows=0
while IFS=$'\t' read -r role path expected_hash extra; do
  [ -z "${extra:-}" ] || die "manifest row has extra fields: ${role}"
  if [ "$role" = "version" ]; then
    [ "$path" = "1" ] || die "unsupported manifest version: ${path}"
    continue
  fi
  case "$role" in
    elf|raw|vm-config) ;;
    *) die "unknown manifest role: ${role}" ;;
  esac
  [ -f "$path" ] || die "manifest input is missing: ${role}: ${path}"
  [ "$(sha256 "$path")" = "$expected_hash" ] \
    || die "manifest input hash mismatch: ${role}: ${path}"
  [ "$role" != "raw" ] || manifest_raw_hash="$expected_hash"
  manifest_rows=$((manifest_rows + 1))
done <"$MANIFEST_FILE"
[ "$manifest_rows" -ge 3 ] || die "manifest has too few artifact rows"
[[ "$manifest_raw_hash" =~ ^[0-9a-f]{64}$ ]] || die "manifest has no valid raw hash"
[ "$(sha256 "$KERNEL_SNAPSHOT")" = "$manifest_raw_hash" ] \
  || die "running kernel snapshot does not match manifest raw hash"

cc -std=c11 -O2 -Wall -Wextra -Werror -o "$PROBE_BIN" "$PROBE_SOURCE"

{
  printf '%s\n' '{"execute":"qmp_capabilities"}'
  printf '%s\n' '{"execute":"query-cpus-fast"}'
} | socat - "UNIX-CONNECT:${QMP_SOCKET}" >"$QMP_OUTPUT"
jq -e 'select(.return | type == "array")' "$QMP_OUTPUT" >/dev/null \
  || die "QMP query-cpus-fast did not return an array"
jq -r 'select(.return | type == "array") | .return[] | [(."cpu-index" // ""),(."thread-id" // ""),(.name // "")] | @tsv' \
  "$QMP_OUTPUT" >"$THREAD_MAP"
[ "$(wc -l <"$THREAD_MAP")" -eq "$EXPECTED_SMP" ] \
  || die "QMP did not return ${EXPECTED_SMP} vCPU threads"
awk -F '\t' -v expected="$EXPECTED_SMP" '
  $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || seen[$1]++ || seen_tid[$2]++ { exit 1 }
  { count++ }
  END {
    if (count != expected) exit 1
    for (cpu_index = 0; cpu_index < expected; cpu_index++)
      if (!(cpu_index in seen)) exit 1
  }
' "$THREAD_MAP" || die "QMP vCPU indexes or TIDs are invalid"

"$THREAD_MAP_HELPER" build "$QEMU_PID" "$THREAD_MAP" "$SAMPLED_THREAD_MAP"
[ "$(($(wc -l <"$SAMPLED_THREAD_MAP") - 1))" -eq "$((EXPECTED_SMP + 1))" ] \
  || die "sampled thread map does not contain the main loop and ${EXPECTED_SMP} vCPUs"

sampled_tids=()
sampled_task_starttimes=()
while IFS=$'\t' read -r role cpu_index tid qemu_name; do
  [ "$role" != "role" ] || continue
  sampled_tids+=("$tid")
  task_starttime="$(proc_stat_starttime "/proc/${QEMU_PID}/task/${tid}/stat")" \
    || die "cannot capture sampled QEMU thread identity: tid=${tid}"
  sampled_task_starttimes+=("$task_starttime")
done <"$SAMPLED_THREAD_MAP"

duration_ms=$((DURATION_SECONDS * 1000))
collection_start_ns="$(date +%s%N)"
verify_sampled_task_identities
AXVISOR_PROC_ROOT="/proc/${QEMU_PID}/task" \
  "$PROBE_BIN" schedstat "$RAW_SAMPLES" "$duration_ms" "$SAMPLE_INTERVAL_US" "${sampled_tids[@]}"
verify_sampled_task_identities
collection_end_ns="$(date +%s%N)"
"$THREAD_MAP_HELPER" annotate "$SAMPLED_THREAD_MAP" "$RAW_SAMPLES" "$SAMPLES"

{
  printf 'role\tcpu_index\ttid\tsamples\ttotal_exec_ns\ttotal_run_delay_ns\tmax_delta_exec_ns\tmax_delta_run_delay_ns\tmax_sample_gap_ns\n'
  awk -F '\t' '
    NR == FNR {
      if (FNR == 1) next
      thread_order[++thread_count]=$3
      role[$3]=$1
      cpu[$3]=$2
      next
    }
    FNR == 1 { next }
    {
      tid=$4
      samples[tid]++
      total_exec[tid]+=$11
      total_delay[tid]+=$12
      if ($11 > max_exec[tid]) max_exec[tid]=$11
      if ($12 > max_delay[tid]) max_delay[tid]=$12
      if (tid in previous_ts && $1 - previous_ts[tid] > max_gap[tid]) max_gap[tid]=$1-previous_ts[tid]
      previous_ts[tid]=$1
    }
    END {
      for (position = 1; position <= thread_count; position++) {
        tid=thread_order[position]
        printf "%s\t%s\t%s\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n", role[tid],cpu[tid],tid,samples[tid],total_exec[tid],total_delay[tid],max_exec[tid],max_delay[tid],max_gap[tid]
      }
    }
  ' "$SAMPLED_THREAD_MAP" "$SAMPLES"
} >"$SUMMARY"

if [ -n "$TRACE_FILE" ] && [ -f "$TRACE_FILE" ]; then
  {
    printf 'trace_status=unusable_for_timeline\n'
    printf 'trace_reason=QEMU_log_backend_has_no_host_timestamp_or_tid\n'
    awk '/^cpu_exec_(start|end) cpu=[0-9]+$/ { count[$1" "$2]++ } END { for (key in count) print key, count[key] }' "$TRACE_FILE" | sort
  } >"$TRACE_REPORT"
else
  printf 'trace_status=unavailable\ntrace_reason=no_trace_file\n' >"$TRACE_REPORT"
fi

[ "$(sha256 "$MANIFEST_FILE")" = "$manifest_hash_before" ] \
  || die "manifest changed during collection"
[ "$(sha256 "$KERNEL_SNAPSHOT")" = "$manifest_raw_hash" ] \
  || die "running kernel snapshot changed during collection"
[ -d "/proc/${QEMU_PID}" ] || die "QEMU exited during collection"
[ "$(proc_stat_starttime "/proc/${QEMU_PID}/stat")" = "$qemu_starttime" ] \
  || die "QEMU PID was reused during collection"

{
  printf 'qemu_pid=%s\n' "$QEMU_PID"
  printf 'qemu_starttime_ticks=%s\n' "$qemu_starttime"
  printf 'qemu_comm=%s\n' "$comm"
  printf 'qemu_exe=%s\n' "$qemu_exe"
  printf 'qemu_exe_sha256=%s\n' "$(sha256 "$qemu_exe")"
  printf 'qemu_cmdline='
  printf '%q ' "${qemu_argv[@]}"
  printf '\n'
  printf 'expected_smp=%s\nactual_smp=%s\n' "$EXPECTED_SMP" "$actual_smp"
  printf 'duration_seconds=%s\n' "$DURATION_SECONDS"
  printf 'sample_interval_us=%s\n' "$SAMPLE_INTERVAL_US"
  printf 'sample_clock=CLOCK_MONOTONIC_RAW\n'
  printf 'collection_wall_start_ns=%s\ncollection_wall_end_ns=%s\n' "$collection_start_ns" "$collection_end_ns"
  printf 'qmp_socket=%s\nqmp_status=verified\n' "$QMP_SOCKET"
  printf 'manifest=%s\nmanifest_sha256=%s\nmanifest_status=verified\n' \
    "$(realpath -- "$MANIFEST_FILE")" "$manifest_hash_before"
  printf 'kernel_snapshot=%s\nkernel_snapshot_sha256=%s\n' \
    "$(realpath -- "$KERNEL_SNAPSHOT")" "$manifest_raw_hash"
  printf 'host_cpu=%s\nhost_kernel=%s\n' "$(uname -m)" "$(uname -r)"
  printf 'sample_rows=%s\nvcpu_thread_map_rows=%s\nsample_thread_rows=%s\n' \
    "$(($(wc -l <"$SAMPLES") - 1))" \
    "$(wc -l <"$THREAD_MAP")" \
    "$(($(wc -l <"$SAMPLED_THREAD_MAP") - 1))"
} >"$METADATA"

echo "[qemu-sched-trace] wrote ${OUTPUT_DIR}"
