#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "[qemu-thread-map] ERROR: $*" >&2
  exit 1
}

[ "$#" -eq 4 ] \
  || die "usage: $0 build <qemu-pid> <qmp-vcpu-map.tsv> <output.tsv> | annotate <sampled-map.tsv> <raw-samples.tsv> <output.tsv>"

COMMAND="$1"
INPUT_ONE="$2"
INPUT_TWO="$3"
OUTPUT="$4"
OUTPUT_DIR="$(dirname -- "$OUTPUT")"
[ -d "$OUTPUT_DIR" ] || die "output directory does not exist: ${OUTPUT_DIR}"
[ ! -d "$OUTPUT" ] || die "output path must not be a directory: ${OUTPUT}"

TEMP_OUTPUT="$(mktemp "${OUTPUT_DIR}/.$(basename -- "$OUTPUT").tmp.XXXXXX")"
cleanup() {
  if [ -n "$TEMP_OUTPUT" ]; then
    rm -f -- "$TEMP_OUTPUT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build_map() {
  local qemu_pid="$INPUT_ONE"
  local qmp_vcpu_map="$INPUT_TWO"

  [[ "$qemu_pid" =~ ^[0-9]+$ ]] || die "QEMU PID must be numeric"
  qemu_pid="$((10#$qemu_pid))"
  [ -d "/proc/${qemu_pid}/task" ] || die "QEMU task directory does not exist: /proc/${qemu_pid}/task"
  [ -s "$qmp_vcpu_map" ] || die "QMP vCPU map is empty: ${qmp_vcpu_map}"

  awk -F '\t' -v OFS='\t' -v qemu_pid="$qemu_pid" '
    function fail(message) {
      print "[qemu-thread-map] ERROR: " message > "/dev/stderr"
      exit 1
    }
    BEGIN {
      print "role", "cpu_index", "tid", "qemu_name"
      print "main-loop", "NA", qemu_pid, "main-loop"
      seen_tid[qemu_pid] = 1
    }
    {
      if (NF < 2 || NF > 3)
        fail("QMP vCPU row must contain two or three fields at line " NR)
      if ($1 !~ /^[0-9]+$/)
        fail("QMP CPU index must be numeric at line " NR)
      if ($2 !~ /^[0-9]+$/)
        fail("QMP TID must be numeric at line " NR)

      cpu_index = sprintf("%.0f", $1 + 0)
      tid = sprintf("%.0f", $2 + 0)
      if (seen_cpu_index[cpu_index]++)
        fail("duplicate vCPU CPU index: " cpu_index)
      if (seen_tid[tid]++)
        fail("duplicate sampled TID: " tid)

      qemu_name = NF == 3 ? $3 : ""
      if (qemu_name == "")
        qemu_name = "unnamed"
      print "vcpu", cpu_index, tid, qemu_name
    }
  ' "$qmp_vcpu_map" >"$TEMP_OUTPUT"

  while IFS=$'\t' read -r role cpu_index tid qemu_name; do
    [ "$role" != "role" ] || continue
    [ -d "/proc/${qemu_pid}/task/${tid}" ] \
      || die "sampled TID does not belong to QEMU PID: tid=${tid} pid=${qemu_pid}"
  done <"$TEMP_OUTPUT"
}

annotate_samples() {
  local sampled_map="$INPUT_ONE"
  local raw_samples="$INPUT_TWO"
  local sampled_header=$'role\tcpu_index\ttid\tqemu_name'
  local raw_header=$'host_monotonic_raw_ns\ttid\tstate\tprocessor\twchan\texec_ns\trun_delay_ns\ttimeslices\tdelta_exec_ns\tdelta_run_delay_ns'

  [ -s "$sampled_map" ] || die "sampled thread map is empty: ${sampled_map}"
  [ -s "$raw_samples" ] || die "raw samples are empty: ${raw_samples}"

  awk -F '\t' -v OFS='\t' -v sampled_header="$sampled_header" -v raw_header="$raw_header" '
    function fail(message) {
      print "[qemu-thread-map] ERROR: " message > "/dev/stderr"
      exit 1
    }
    NR == FNR {
      if (FNR == 1) {
        if ($0 != sampled_header)
          fail("invalid sampled thread map header")
        next
      }
      if (NF != 4)
        fail("sampled thread map row must contain four fields at line " FNR)
      if ($1 == "" || $2 == "" || $3 == "" || $4 == "")
        fail("sampled thread map fields must be non-empty at line " FNR)
      if ($3 !~ /^[0-9]+$/)
        fail("sampled thread map TID must be numeric at line " FNR)

      if (FNR == 2) {
        if ($1 != "main-loop" || $2 != "NA")
          fail("first sampled thread must be main-loop with CPU index NA")
      } else {
        if ($1 != "vcpu" || $2 !~ /^[0-9]+$/)
          fail("sampled threads after main-loop must be vCPUs with numeric CPU indexes at line " FNR)
        normalized_cpu_index = sprintf("%.0f", $2 + 0)
        if (seen_cpu_index[normalized_cpu_index]++)
          fail("duplicate sampled-map vCPU CPU index: " normalized_cpu_index)
      }

      tid = sprintf("%.0f", $3 + 0)
      if (seen_tid[tid]++)
        fail("duplicate sampled-map TID: " tid)
      role[tid] = $1
      cpu_index[tid] = $2
      sampled_rows++
      next
    }
    FNR == 1 {
      if (sampled_rows == 0)
        fail("sampled thread map has no data rows")
      if ($0 != raw_header)
        fail("invalid raw sample header")
      print "host_monotonic_raw_ns", "role", "cpu_index", "tid", "state", "processor", "wchan", "exec_ns", "run_delay_ns", "timeslices", "delta_exec_ns", "delta_run_delay_ns"
      next
    }
    {
      if (NF != 10)
        fail("raw sample row must contain ten fields at line " FNR)
      if ($2 !~ /^[0-9]+$/)
        fail("raw sample TID must be numeric at line " FNR)

      tid = sprintf("%.0f", $2 + 0)
      if (!(tid in role))
        fail("raw sample TID is absent from sampled map: " tid)
      print $1, role[tid], cpu_index[tid], $2, $3, $4, $5, $6, $7, $8, $9, $10
    }
  ' "$sampled_map" "$raw_samples" >"$TEMP_OUTPUT"
}

case "$COMMAND" in
  build) build_map ;;
  annotate) annotate_samples ;;
  *) die "unknown subcommand: ${COMMAND}" ;;
esac

mv -fT -- "$TEMP_OUTPUT" "$OUTPUT"
TEMP_OUTPUT=""
