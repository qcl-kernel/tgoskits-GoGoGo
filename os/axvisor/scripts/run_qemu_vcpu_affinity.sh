#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <console-log> [duration-seconds]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LOG_FILE="$1"
DURATION_SECONDS="${2:-30}"
DEFAULT_AXVISOR_ELF="${REPO_ROOT}/target/aarch64-unknown-linux-musl/release/axvisor"
DEFAULT_AXVISOR_BIN="${REPO_ROOT}/target/aarch64-unknown-linux-musl/release/axvisor.bin"
AXVISOR_ELF="${AXVISOR_QEMU_ELF:-${DEFAULT_AXVISOR_ELF}}"
AXVISOR_BIN="${AXVISOR_QEMU_KERNEL:-${DEFAULT_AXVISOR_BIN}}"
ROOTFS="${AXVISOR_QEMU_ROOTFS:-${REPO_ROOT}/tmp/rootfs.img}"
VM_CONFIG_ROOT="${REPO_ROOT}/tmp/vmconfigs/three-guest-net"
VM_CONFIGS="${AXVISOR_VM_CONFIGS:-${VM_CONFIG_ROOT}/linux-net-1.toml:${VM_CONFIG_ROOT}/linux-net-2.toml:${VM_CONFIG_ROOT}/zephyr-net.toml}"
MANIFEST_FILE="${LOG_FILE}.build-manifest.tsv"
PCAP_NET0="${LOG_FILE}.net0.pcap"
PCAP_NET1="${LOG_FILE}.net1.pcap"
PCAP_NET2="${LOG_FILE}.net2.pcap"
QEMU_SMP="${AXVISOR_QEMU_SMP:-4}"
VCPU_HOST_CPUS_CSV="${AXVISOR_QEMU_VCPU_CPUS:-4,5,6,7}"
OTHER_CPUS="${AXVISOR_QEMU_OTHER_CPUS:-8-15}"
IDLE_VCPUS_CSV="${AXVISOR_QEMU_IDLE_VCPUS:-}"
PIN_VCPUS="${AXVISOR_QEMU_PIN_VCPUS:-1}"
TRACE_DIR="${AXVISOR_QEMU_TRACE_DIR:-}"
RUN_DIR=""
QMP_SOCKET=""
QMP_OUTPUT="${LOG_FILE}.qmp.jsonl"
THREAD_MAP="${LOG_FILE}.affinity.tsv"
KERNEL_SNAPSHOT=""
QEMU_PID=""
TRACE_COLLECTOR_PID=""
CONSOLE_FILTER_PID=""
CONSOLE_FIFO=""

die() {
  echo "[qemu-vcpu-affinity] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TRACE_COLLECTOR_PID" ] && kill -0 "$TRACE_COLLECTOR_PID" 2>/dev/null; then
    kill "$TRACE_COLLECTOR_PID" 2>/dev/null || true
    wait "$TRACE_COLLECTOR_PID" 2>/dev/null || true
  fi
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [ -n "$CONSOLE_FILTER_PID" ]; then
    wait "$CONSOLE_FILTER_PID" 2>/dev/null || true
  fi
  [ -z "$QMP_SOCKET" ] || rm -f "$QMP_SOCKET"
  rm -f "${THREAD_MAP}.raw"
  [ -z "$KERNEL_SNAPSHOT" ] || rm -f "$KERNEL_SNAPSHOT"
  [ -z "$RUN_DIR" ] || rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[[ "$DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "duration must be a positive integer"
[[ "$QEMU_SMP" =~ ^[1-9][0-9]*$ ]] || die "AXVISOR_QEMU_SMP must be a positive integer"
[[ "$PIN_VCPUS" =~ ^[01]$ ]] || die "AXVISOR_QEMU_PIN_VCPUS must be 0 or 1"
if [ -n "${AXVISOR_QEMU_KERNEL:-}" ] \
  && [ "$(realpath -m -- "$AXVISOR_BIN")" != "$(realpath -m -- "$DEFAULT_AXVISOR_BIN")" ] \
  && [ -z "${AXVISOR_QEMU_ELF:-}" ]; then
  die "custom AXVISOR_QEMU_KERNEL requires a corresponding AXVISOR_QEMU_ELF override"
fi

IFS=':' read -r -a VM_CONFIG_FILES <<<"$VM_CONFIGS"
mkdir -p "$(dirname "$LOG_FILE")"
"${SCRIPT_DIR}/validate_qemu_artifact.sh" \
  "$MANIFEST_FILE" "$AXVISOR_ELF" "$AXVISOR_BIN" "${VM_CONFIG_FILES[@]}"

if [ -n "${AXVISOR_QEMU_VALIDATE_ONLY:-}" ]; then
  echo "[qemu-vcpu-affinity] manifest=${MANIFEST_FILE}"
  exit 0
fi

if [ -n "${AXVISOR_QEMU_AARCH64:-}" ]; then
  QEMU_BIN="$AXVISOR_QEMU_AARCH64"
else
  QEMU_BIN="$(command -v qemu-system-aarch64 || true)"
  [ -n "$QEMU_BIN" ] || die "qemu-system-aarch64 was not found; set AXVISOR_QEMU_AARCH64"
fi
[ -x "$QEMU_BIN" ] || die "QEMU binary is not executable: ${QEMU_BIN}"
[ -f "$ROOTFS" ] || die "rootfs does not exist: ${ROOTFS}"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v socat >/dev/null 2>&1 || die "socat is required"
command -v cp >/dev/null 2>&1 || die "cp is required"

VCPU_HOST_CPUS=()
if [ "$PIN_VCPUS" -eq 1 ]; then
  command -v taskset >/dev/null 2>&1 || die "taskset is required when vCPU pinning is enabled"
  IFS=',' read -r -a VCPU_HOST_CPUS <<<"$VCPU_HOST_CPUS_CSV"
  [ "${#VCPU_HOST_CPUS[@]}" -eq "$QEMU_SMP" ] \
    || die "AXVISOR_QEMU_VCPU_CPUS must list ${QEMU_SMP} host CPUs"
fi
declare -A IDLE_VCPUS=()
if [ -n "$IDLE_VCPUS_CSV" ]; then
  command -v chrt >/dev/null 2>&1 || die "chrt is required for AXVISOR_QEMU_IDLE_VCPUS"
  IFS=',' read -r -a idle_vcpu_indexes <<<"$IDLE_VCPUS_CSV"
  for cpu_index in "${idle_vcpu_indexes[@]}"; do
    [[ "$cpu_index" =~ ^[0-9]+$ ]] && [ "$cpu_index" -lt "$QEMU_SMP" ] \
      || die "AXVISOR_QEMU_IDLE_VCPUS contains invalid index: ${cpu_index}"
    IDLE_VCPUS[$cpu_index]=1
  done
fi

RUN_DIR="$(mktemp -d /tmp/axvisor-qemu-affinity.XXXXXX)"
QMP_SOCKET="${RUN_DIR}/qmp.sock"
KERNEL_SNAPSHOT="${RUN_DIR}/axvisor.bin"
if [ -n "$TRACE_DIR" ]; then
  [ ! -e "$TRACE_DIR" ] || die "AXVISOR_QEMU_TRACE_DIR must not already exist: ${TRACE_DIR}"
  mkdir -p "$TRACE_DIR"
  command -v cc >/dev/null 2>&1 || die "cc is required for synchronized tracing"
  [ -f "${SCRIPT_DIR}/qemu_sched_probe.c" ] || die "missing qemu_sched_probe.c"
  [ -x "${SCRIPT_DIR}/collect_qemu_sched_trace.sh" ] || die "missing collect_qemu_sched_trace.sh"
  cc -std=c11 -O2 -Wall -Wextra -Werror \
    -o "${RUN_DIR}/qemu_sched_probe" "${SCRIPT_DIR}/qemu_sched_probe.c"
  CONSOLE_FIFO="${RUN_DIR}/console.fifo"
  mkfifo "$CONSOLE_FIFO"
fi
cp -- "$AXVISOR_BIN" "$KERNEL_SNAPSHOT" \
  || die "failed to create validated Axvisor kernel snapshot"

MANIFEST_RAW_HASH=""
MANIFEST_RAW_ROWS=0
while IFS=$'\t' read -r row_type _ row_hash; do
  if [ "$row_type" = "raw" ]; then
    MANIFEST_RAW_HASH="$row_hash"
    MANIFEST_RAW_ROWS=$((MANIFEST_RAW_ROWS + 1))
  fi
done <"$MANIFEST_FILE"
[ "$MANIFEST_RAW_ROWS" -eq 1 ] || die "manifest must contain exactly one raw row"
[[ "$MANIFEST_RAW_HASH" =~ ^[0-9a-f]{64}$ ]] || die "manifest raw SHA-256 is invalid"
snapshot_hash_output="$(sha256sum -- "$KERNEL_SNAPSHOT")"
SNAPSHOT_SHA256="${snapshot_hash_output%% *}"
[ "$SNAPSHOT_SHA256" = "$MANIFEST_RAW_HASH" ] \
  || die "validated Axvisor kernel snapshot does not match manifest raw SHA-256"

qemu_command=(
  env -u AXVISOR_VM_CONFIGS "$QEMU_BIN"
  -nographic
  -accel tcg,thread=multi
  -cpu cortex-a72
  -machine virt,virtualization=on,gic-version=3
  -global virtio-mmio.force-legacy=false
  -smp "$QEMU_SMP"
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65
  -drive "id=disk0,if=none,format=raw,file=${ROOTFS}"
  -append "root=/dev/nvme0n1 rw init=/bin/sh"
  -m 8g
  -netdev hubport,id=net0,hubid=77
  -object "filter-dump,id=dump0,netdev=net0,file=${PCAP_NET0}"
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01
  -netdev hubport,id=net1,hubid=77
  -object "filter-dump,id=dump1,netdev=net1,file=${PCAP_NET1}"
  -device virtio-net-device,netdev=net1,bus=virtio-mmio-bus.1,mac=52:54:00:77:00:02
  -netdev hubport,id=net2,hubid=77
  -object "filter-dump,id=dump2,netdev=net2,file=${PCAP_NET2}"
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03
  -qmp "unix:${QMP_SOCKET},server=on,wait=off"
  -kernel "$KERNEL_SNAPSHOT"
)
if [ -n "$TRACE_DIR" ]; then
  "${RUN_DIR}/qemu_sched_probe" timestamp-stream \
    "$LOG_FILE" "${TRACE_DIR}/console-monotonic.tsv" <"$CONSOLE_FIFO" &
  CONSOLE_FILTER_PID=$!
  "${qemu_command[@]}" >"$CONSOLE_FIFO" 2>&1 &
else
  : >"$LOG_FILE"
  "${qemu_command[@]}" >"$LOG_FILE" 2>&1 &
fi
QEMU_PID=$!

for _ in $(seq 1 200); do
  [ -S "$QMP_SOCKET" ] && break
  kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited before QMP became ready"
  sleep 0.05
done
[ -S "$QMP_SOCKET" ] || die "QMP socket did not become ready"

{
  printf '%s\n' '{"execute":"qmp_capabilities"}'
  printf '%s\n' '{"execute":"query-cpus-fast"}'
} | socat - "UNIX-CONNECT:${QMP_SOCKET}" >"$QMP_OUTPUT"

jq -r 'select(.return | type == "array") | .return[] | [(.["cpu-index"] // ""),(.["thread-id"] // ""),(.name // "")] | @tsv' \
  "$QMP_OUTPUT" >"${THREAD_MAP}.raw"
[ "$(wc -l <"${THREAD_MAP}.raw")" -eq "$QEMU_SMP" ] \
  || die "QMP did not return ${QEMU_SMP} vCPU threads"

printf 'cpu_index\ttid\tqemu_name\thost_cpu\tsched_policy\n' >"$THREAD_MAP"
if [ "$PIN_VCPUS" -eq 1 ]; then
for tid_dir in "/proc/${QEMU_PID}"/task/*; do
  tid="${tid_dir##*/}"
  taskset -pc "$OTHER_CPUS" "$tid" >/dev/null
done
fi

while IFS=$'\t' read -r cpu_index tid qemu_name; do
  [[ "$cpu_index" =~ ^[0-9]+$ ]] && [ "$cpu_index" -lt "$QEMU_SMP" ] \
    || die "invalid QEMU CPU index: ${cpu_index}"
  host_cpu="unbound"
  if [ "$PIN_VCPUS" -eq 1 ]; then
    host_cpu="${VCPU_HOST_CPUS[$cpu_index]}"
    taskset -pc "$host_cpu" "$tid" >/dev/null
  fi
  sched_policy="other"
  if [ -n "${IDLE_VCPUS[$cpu_index]-}" ]; then
    chrt --idle --pid 0 "$tid"
    sched_policy="idle"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cpu_index" "$tid" "$qemu_name" "$host_cpu" "$sched_policy" >>"$THREAD_MAP"
done <"${THREAD_MAP}.raw"
rm -f "${THREAD_MAP}.raw"

if [ -n "$TRACE_DIR" ]; then
  AXVISOR_QEMU_TRACE_QMP="$QMP_SOCKET" \
  AXVISOR_QEMU_TRACE_MANIFEST="$MANIFEST_FILE" \
  AXVISOR_QEMU_TRACE_KERNEL_SNAPSHOT="$KERNEL_SNAPSHOT" \
  AXVISOR_QEMU_TRACE_EXPECTED_SMP="$QEMU_SMP" \
    "${SCRIPT_DIR}/collect_qemu_sched_trace.sh" \
    "$QEMU_PID" "$TRACE_DIR" "$DURATION_SECONDS" &
  TRACE_COLLECTOR_PID=$!
  wait "$TRACE_COLLECTOR_PID"
  TRACE_COLLECTOR_PID=""
else
  sleep "$DURATION_SECONDS"
fi
cleanup
trap - EXIT INT TERM
echo "[qemu-vcpu-affinity] console=${LOG_FILE} mapping=${THREAD_MAP}"
