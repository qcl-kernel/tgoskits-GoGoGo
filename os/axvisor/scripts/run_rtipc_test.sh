#!/bin/bash
# RT-IPC End-to-End QEMU Integration Test
# Builds RT-Thread (with SAL/RT-IPC server), Linux initramfs (with rtipc-client),
# Axvisor, then launches QEMU and collects results.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)

QEMU=${QEMU:-}
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
QEMU_REALTIME_CONTROL="$SCRIPT_DIR/apply_qemu_realtime_controls.sh"
RTTHREAD_VMCONFIG_GENERATOR="$SCRIPT_DIR/generate_rtthread_vmconfig.sh"
LINUX_VMCONFIG_GENERATOR="$SCRIPT_DIR/generate_linux_vmconfig.sh"
HOST_BENCHMARK_TIMING="$SCRIPT_DIR/host_benchmark_timing.sh"
AXVISOR_BIN="target/aarch64-unknown-linux-musl/release/axvisor.bin"
RTTHREAD_SRC="${RTTHREAD_SRC:-tmp/rt-thread-5.2.2-final}"
RTTHREAD_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"
LINUX_VMCONFIG_TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml"
LINUX_KERNEL_IMAGE="${LINUX_KERNEL_IMAGE:-tmp/vmconfigs/three-guest-net/current/linux-kernel}"
LINUX_INITRAMFS_SOURCE="${LINUX_INITRAMFS_SOURCE:-tmp/vmconfigs/two-guest-net/current/linux-1-initramfs.cpio}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-tmp/vmconfigs/two-guest-net/current/rootfs.img}"
LOG="${LOG:-tmp/rtipc-test.log}"
QEMU_LOG="${QEMU_LOG:-${LOG}.qemu}"
ARTIFACT_LOG="${ARTIFACT_LOG:-${LOG}.artifacts}"
RTIPC_COUNT="${RTIPC_COUNT:-1000}"
RTIPC_FAULT_PROFILE="${RTIPC_FAULT_PROFILE:-none}"
RTIPC_TIMEOUT_S="${RTIPC_TIMEOUT_S:-480}"
RTBENCH_STABILITY_SECONDS="${RTBENCH_STABILITY_SECONDS:-}"
RTBENCH_SUITE_SAMPLES="${RTBENCH_SUITE_SAMPLES:-}"
RTBENCH_START_MODE="${RTBENCH_START_MODE:-concurrent}"
CPU_LOAD_LOG="${CPU_LOAD_LOG:-}"
RTBENCH_TIMING_LOG="${RTBENCH_TIMING_LOG:-${LOG}.timing}"
QEMU_UCLAMP_MIN="${QEMU_UCLAMP_MIN:-1024}"
RTBENCH_MODE=none
RTBENCH_COMMAND=
RTBENCH_DONE_MARKER=
RTBENCH_REQUESTED_UNIT=
RTBENCH_REQUESTED_VALUE=
RTBENCH_TIMING_STATE=
RTTHREAD_RUNTIME_DIR=
LINUX_RUNTIME_DIR=
STAGING=
STRIP_TMP_DIR=

cleanup_build_artifacts() {
  if [ -n "$STAGING" ]; then
    rm -rf -- "$STAGING"
  fi
  if [ -n "$RTTHREAD_RUNTIME_DIR" ]; then
    rm -rf -- "$RTTHREAD_RUNTIME_DIR"
  fi
  if [ -n "$LINUX_RUNTIME_DIR" ]; then
    rm -rf -- "$LINUX_RUNTIME_DIR"
  fi
  if [ -n "$STRIP_TMP_DIR" ]; then
    rm -rf -- "$STRIP_TMP_DIR"
  fi
}

apply_qemu_realtime_control_or_fail() {
  local qemu_pid=$1
  local QEMU_UCLAMP_MIN=$2
  local qemu_realtime_control_status
  local qemu_realtime_control_rc

  qemu_realtime_control_status=$(
    "$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN"
  )
  qemu_realtime_control_rc=$?
  if [ -n "$qemu_realtime_control_status" ]; then
    printf '%s\n' "$qemu_realtime_control_status"
  fi
  if [ "$qemu_realtime_control_rc" -ne 0 ]; then
    echo "QEMU realtime control failed with code $qemu_realtime_control_rc" >> "$QEMU_LOG"
  fi
  return "$qemu_realtime_control_rc"
}

cleanup_serial_session() {
  local session_pid

  for session_pid in "${feeder_pid:-}" "${cpu_monitor_pid:-}" \
      "${socat_pid:-}" "${run_pid:-}"; do
    if [ -n "$session_pid" ] && kill -0 "$session_pid" 2>/dev/null; then
      kill "$session_pid" 2>/dev/null || true
      wait "$session_pid" 2>/dev/null || true
    fi
  done
  exec 3>&- 2>/dev/null || true
  if [ -n "${serial_tmp:-}" ]; then
    rm -rf -- "$serial_tmp"
  fi
}

handle_serial_signal() {
  local signal_status=$1

  trap - EXIT HUP INT TERM
  cleanup_serial_session
  exit "$signal_status"
}

install_serial_signal_handlers() {
  trap cleanup_serial_session EXIT
  trap 'handle_serial_signal 129' HUP
  trap 'handle_serial_signal 130' INT
  trap 'handle_serial_signal 143' TERM
}

run_nonbenchmark_until_markers() {
  local helper_rc

  run_pid=
  feeder_pid=
  cpu_monitor_pid=
  socat_pid=
  serial_tmp=
  install_serial_signal_handlers
  "$RUN_UNTIL" "$@" &
  run_pid=$!
  if wait "$run_pid"; then
    helper_rc=0
  else
    helper_rc=$?
  fi
  run_pid=
  cleanup_serial_session
  trap - EXIT HUP INT TERM
  return "$helper_rc"
}

wait_for_feeder() {
  local feeder_rc

  if [ -z "${feeder_pid:-}" ]; then
    return 0
  fi
  wait "$feeder_pid"
  feeder_rc=$?
  feeder_pid=
  return "$feeder_rc"
}

resolve_runtime_artifact() {
  local label=$1
  local candidate=$2
  local resolved

  if ! resolved=$(realpath -e -- "$candidate") || \
     [ ! -f "$resolved" ] || [ ! -r "$resolved" ]; then
    echo "runtime artifact is missing or unreadable: $label=$candidate" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

record_runtime_artifact() {
  local label=$1
  local candidate=$2
  local resolved
  local digest
  local digest_line

  resolved=$(resolve_runtime_artifact "$label" "$candidate") || return
  digest_line=$(sha256sum "$resolved") || return
  digest=${digest_line%% *}
  if [ -z "$digest" ]; then
    echo "failed to calculate runtime artifact digest: $label=$resolved" >&2
    return 1
  fi
  printf 'ARTIFACT name=%s path=%s sha256=%s\n' \
    "$label" "$resolved" "$digest" >> "$ARTIFACT_LOG"
}

create_serial_session() {
  local created_tmp

  created_tmp=$(mktemp -d) || return
  if [ -z "$created_tmp" ] || [ ! -d "$created_tmp" ]; then
    echo "mktemp did not create a serial session directory" >&2
    return 1
  fi

  serial_tmp=$created_tmp
  serial_socket="$serial_tmp/serial.sock"
  serial_input="$serial_tmp/serial.in"
  RTBENCH_TIMING_STATE="$serial_tmp/benchmark-timing.state"
}

build_axvisor_binary() {
  local input=$1
  local output=$2
  local tmp_parent=$3
  local stripped_axvisor
  local command_rc

  STRIP_TMP_DIR=$(mktemp -d "$tmp_parent/axvisor-strip.XXXXXX") || return
  if [ -z "$STRIP_TMP_DIR" ] || [ ! -d "$STRIP_TMP_DIR" ]; then
    echo "mktemp did not create an AxVisor strip directory" >&2
    STRIP_TMP_DIR=
    return 1
  fi
  stripped_axvisor="$STRIP_TMP_DIR/axvisor"

  if aarch64-linux-gnu-strip -o "$stripped_axvisor" "$input"; then
    :
  else
    command_rc=$?
    rm -rf -- "$STRIP_TMP_DIR"
    STRIP_TMP_DIR=
    return "$command_rc"
  fi
  if aarch64-linux-gnu-objcopy -O binary "$stripped_axvisor" "$output"; then
    :
  else
    command_rc=$?
    rm -rf -- "$STRIP_TMP_DIR"
    STRIP_TMP_DIR=
    return "$command_rc"
  fi

  rm -rf -- "$STRIP_TMP_DIR"
  STRIP_TMP_DIR=
}

canonicalize_output_path() {
  local label=$1
  local candidate=$2
  local resolved
  local parent

  if [ -z "$candidate" ] || ! resolved=$(realpath -m -- "$candidate"); then
    echo "invalid output path: $label=$candidate" >&2
    return 2
  fi
  parent=$(dirname -- "$resolved")
  if [ ! -d "$parent" ] || [ ! -w "$parent" ]; then
    echo "output parent is missing or unwritable: $label=$parent" >&2
    return 2
  fi
  if [ -e "$resolved" ] && { [ ! -f "$resolved" ] || [ ! -w "$resolved" ]; }; then
    echo "output is not a writable regular file: $label=$resolved" >&2
    return 2
  fi
  printf '%s\n' "$resolved"
}

validate_output_paths() {
  local labels=(LOG QEMU_LOG ARTIFACT_LOG RTBENCH_TIMING_LOG)
  local paths
  local i
  local j

  LOG=$(canonicalize_output_path LOG "$LOG") || return 2
  QEMU_LOG=$(canonicalize_output_path QEMU_LOG "$QEMU_LOG") || return 2
  ARTIFACT_LOG=$(canonicalize_output_path ARTIFACT_LOG "$ARTIFACT_LOG") || return 2
  RTBENCH_TIMING_LOG=$(
    canonicalize_output_path RTBENCH_TIMING_LOG "$RTBENCH_TIMING_LOG"
  ) || return 2
  paths=("$LOG" "$QEMU_LOG" "$ARTIFACT_LOG" "$RTBENCH_TIMING_LOG")

  if [ -n "$CPU_LOAD_LOG" ]; then
    CPU_LOAD_LOG=$(canonicalize_output_path CPU_LOAD_LOG "$CPU_LOAD_LOG") || return 2
    labels+=(CPU_LOAD_LOG)
    paths+=("$CPU_LOAD_LOG")
  fi

  for ((i = 0; i < ${#paths[@]}; i++)); do
    for ((j = i + 1; j < ${#paths[@]}; j++)); do
      if [ "${paths[$i]}" = "${paths[$j]}" ] || \
         { [ -e "${paths[$i]}" ] && [ -e "${paths[$j]}" ] && \
           [ "${paths[$i]}" -ef "${paths[$j]}" ]; }; then
        echo "output paths collide: ${labels[$i]}=${labels[$j]}=${paths[$i]}" >&2
        return 2
      fi
    done
  done
}

validate_output_input_collisions() {
  local input_label
  local input_path
  local output_label
  local output_path
  local output_labels=(LOG QEMU_LOG ARTIFACT_LOG RTBENCH_TIMING_LOG)
  local output_paths=("$LOG" "$QEMU_LOG" "$ARTIFACT_LOG" "$RTBENCH_TIMING_LOG")
  local i

  if [ -n "$CPU_LOAD_LOG" ]; then
    output_labels+=(CPU_LOAD_LOG)
    output_paths+=("$CPU_LOAD_LOG")
  fi
  if [ $(( $# % 2 )) -ne 0 ]; then
    echo "input collision validation requires label/path pairs" >&2
    return 2
  fi

  while [ "$#" -gt 0 ]; do
    input_label=$1
    input_path=$(realpath -m -- "$2") || return 2
    shift 2
    for ((i = 0; i < ${#output_paths[@]}; i++)); do
      output_label=${output_labels[$i]}
      output_path=${output_paths[$i]}
      if [ "$input_path" = "$output_path" ] || \
         { [ -e "$input_path" ] && [ -e "$output_path" ] && \
           [ "$input_path" -ef "$output_path" ]; }; then
        echo "input/output paths collide: $input_label=$output_label=$input_path" >&2
        return 2
      fi
    done
  done
}

validate_cli_arguments() {
if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  return 2
fi
}

validate_runtime_options() {
case "$RTIPC_FAULT_PROFILE" in
  none|reliability) ;;
  *)
    echo "RTIPC_FAULT_PROFILE must be none or reliability" >&2
    return 2
    ;;
esac

case "$RTIPC_COUNT" in
  ''|*[!0-9]*|0)
    echo "RTIPC_COUNT must be a positive integer" >&2
    return 2
    ;;
esac

case "$RTIPC_TIMEOUT_S" in
  ''|*[!0-9]*|0)
    echo "RTIPC_TIMEOUT_S must be a positive integer" >&2
    return 2
    ;;
esac

case "$QEMU_UCLAMP_MIN" in
  ''|*[!0-9]*)
    echo "QEMU_UCLAMP_MIN must be an integer from 0 to 1024" >&2
    return 2
    ;;
esac
if [ "${#QEMU_UCLAMP_MIN}" -gt 4 ] || [ "$QEMU_UCLAMP_MIN" -gt 1024 ]; then
  echo "QEMU_UCLAMP_MIN must be an integer from 0 to 1024" >&2
  return 2
fi

if [ -n "$RTBENCH_STABILITY_SECONDS" ] && [ -n "$RTBENCH_SUITE_SAMPLES" ]; then
  echo "RTBENCH_STABILITY_SECONDS and RTBENCH_SUITE_SAMPLES are mutually exclusive" >&2
  return 2
fi

if [ -n "$RTBENCH_STABILITY_SECONDS" ]; then
  case "$RTBENCH_STABILITY_SECONDS" in
    ''|*[!0-9]*|0)
      echo "RTBENCH_STABILITY_SECONDS must be an integer from 1 to 3600" >&2
      return 2
      ;;
  esac
  if [ "$RTBENCH_STABILITY_SECONDS" -gt 3600 ]; then
    echo "RTBENCH_STABILITY_SECONDS must be an integer from 1 to 3600" >&2
    return 2
  fi
  RTBENCH_MODE=stability
  RTBENCH_COMMAND="rtbench_stability $RTBENCH_STABILITY_SECONDS"
  RTBENCH_DONE_MARKER=RTBENCH_STABILITY_DONE
  RTBENCH_REQUESTED_UNIT=seconds
  RTBENCH_REQUESTED_VALUE="$RTBENCH_STABILITY_SECONDS"
elif [ -n "$RTBENCH_SUITE_SAMPLES" ]; then
  case "$RTBENCH_SUITE_SAMPLES" in
    ''|*[!0-9]*|0)
      echo "RTBENCH_SUITE_SAMPLES must be an integer from 1 to 100000" >&2
      return 2
      ;;
  esac
  if [ "$RTBENCH_SUITE_SAMPLES" -gt 100000 ]; then
    echo "RTBENCH_SUITE_SAMPLES must be an integer from 1 to 100000" >&2
    return 2
  fi
  RTBENCH_MODE=suite
  RTBENCH_COMMAND="benchmark $RTBENCH_SUITE_SAMPLES"
  RTBENCH_DONE_MARKER='RTBENCH_END status='
  RTBENCH_REQUESTED_UNIT=samples
  RTBENCH_REQUESTED_VALUE="$RTBENCH_SUITE_SAMPLES"
fi

if [ "$RTBENCH_MODE" != none ]; then
  case "$RTBENCH_START_MODE" in
    concurrent|after-rtipc) ;;
    *)
      echo "RTBENCH_START_MODE must be concurrent or after-rtipc" >&2
      return 2
      ;;
  esac
  if [ -n "$CPU_LOAD_LOG" ] && ! command -v pidstat >/dev/null; then
    echo "CPU_LOAD_LOG requires pidstat" >&2
    return 2
  fi
fi
}

feed_rtthread_benchmark_command() {
  if [ "$RTBENCH_START_MODE" = "after-rtipc" ]; then
    ready_marker='RT-IPC client exited with rc=0'
  else
    ready_marker='[VM 3] msh />'
  fi
  deadline_ns=$(( $(date +%s%N) + RTIPC_TIMEOUT_S * 1000000000 ))
  while ! grep -aFq -- "$ready_marker" "$LOG"; do
    if [ -z "${run_pid:-}" ] || ! kill -0 "$run_pid" 2>/dev/null; then
      echo "QEMU runner exited while waiting to start RT-Thread benchmark" >> "$QEMU_LOG"
      return 1
    fi
    if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
      echo "timed out waiting to start RT-Thread benchmark: $ready_marker" >> "$QEMU_LOG"
      return 1
    fi
    sleep 0.1
  done

  # The console mux attaches VM 1 by default; Ctrl-X ] selects VM 3.
  printf '\030]'
  sleep 0.2
  "$HOST_BENCHMARK_TIMING" start "$RTBENCH_TIMING_STATE"
  printf '%s\r' "$RTBENCH_COMMAND"

  deadline_ns=$(( $(date +%s%N) + RTIPC_TIMEOUT_S * 1000000000 ))
  while ! grep -aFq -- "$RTBENCH_DONE_MARKER" "$LOG"; do
    if [ -z "${run_pid:-}" ] || ! kill -0 "$run_pid" 2>/dev/null; then
      echo "QEMU runner exited while waiting for RT-Thread benchmark completion" >> "$QEMU_LOG"
      return 1
    fi
    if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
      echo "timed out waiting for RT-Thread benchmark completion" >> "$QEMU_LOG"
      return 1
    fi
    sleep 0.01
  done

  "$HOST_BENCHMARK_TIMING" finish "$RTBENCH_TIMING_STATE" \
    "$RTBENCH_TIMING_LOG" "$RTBENCH_MODE" "$RTBENCH_REQUESTED_UNIT" \
    "$RTBENCH_REQUESTED_VALUE"

  # Replay VM 1's buffered console so its final RT-IPC result is observable.
  printf '\030[' || true
}

main() {
set -e
cd "$ROOT"
validate_cli_arguments "$@"
validate_runtime_options
validate_output_paths
if [ -z "$QEMU" ]; then
  if ! QEMU=$(command -v qemu-system-aarch64); then
    echo "qemu-system-aarch64 not found; set QEMU to its executable path" >&2
    return 127
  fi
fi

QEMU=$(resolve_runtime_artifact qemu "$QEMU")
ROOTFS_IMAGE=$(resolve_runtime_artifact rootfs "$ROOTFS_IMAGE")
LINUX_KERNEL_IMAGE=$(resolve_runtime_artifact linux-kernel "$LINUX_KERNEL_IMAGE")
LINUX_INITRAMFS_SOURCE=$(
  resolve_runtime_artifact linux-initramfs-source "$LINUX_INITRAMFS_SOURCE"
)
validate_output_input_collisions \
  qemu "$QEMU" \
  rootfs "$ROOTFS_IMAGE" \
  linux-kernel "$LINUX_KERNEL_IMAGE" \
  linux-initramfs-source "$LINUX_INITRAMFS_SOURCE" \
  rtthread-vmconfig-template "$RTTHREAD_VMCONFIG_TEMPLATE" \
  linux-vmconfig-template "$LINUX_VMCONFIG_TEMPLATE"
: > "$ARTIFACT_LOG"
record_runtime_artifact qemu "$QEMU"
record_runtime_artifact rootfs "$ROOTFS_IMAGE"
record_runtime_artifact linux-kernel "$LINUX_KERNEL_IMAGE"
record_runtime_artifact linux-initramfs-source "$LINUX_INITRAMFS_SOURCE"

echo "=== RT-IPC Integration Test ==="

# 1. Fetch the pinned RT-Thread source on first use, then patch and build it.
echo "[1/5] Building RT-Thread with SAL/socket and RT-IPC server..."
bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh "$RTTHREAD_SRC"
bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh "$RTTHREAD_SRC"
bash os/axvisor/patches/rtthread/test-rtthread-patches.sh "$RTTHREAD_SRC"
uv run --with scons scons -C "$RTTHREAD_SRC/bsp/qemu-virt64-aarch64" -c
uv run --with scons scons -C "$RTTHREAD_SRC/bsp/qemu-virt64-aarch64" -j4
RTTHREAD_KERNEL="$(realpath "$RTTHREAD_SRC/bsp/qemu-virt64-aarch64/rtthread.bin")"
record_runtime_artifact rtthread-kernel "$RTTHREAD_KERNEL"
RTTHREAD_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtthread-runtime.XXXXXX")"
trap 'cleanup_build_artifacts' EXIT
RTTHREAD_VMCONFIG="$(
  "$RTTHREAD_VMCONFIG_GENERATOR" "$ROOT" "$RTTHREAD_VMCONFIG_TEMPLATE" \
    "$RTTHREAD_KERNEL" "$RTTHREAD_RUNTIME_DIR"
)"

# 2. Cross-compile Linux client
echo "[2/5] Building rtipc-client..."
make -C os/axvisor/guests/rt-ipc/linux

# 3. Rebuild initramfs with client binary
echo "[3/5] Rebuilding Linux initramfs..."
LINUX_RUNTIME_DIR="$(mktemp -d "$ROOT/tmp/rtipc-runtime.XXXXXX")"
LINUX_INITRAMFS="$LINUX_RUNTIME_DIR/linux-initramfs-built.cpio"
STAGING=$(mktemp -d "$ROOT/tmp/rtipc-initramfs.XXXXXX")
trap 'cleanup_build_artifacts' EXIT
if gzip -t "$LINUX_INITRAMFS_SOURCE" 2>/dev/null; then
  gzip -dc "$LINUX_INITRAMFS_SOURCE" |
    (cd "$STAGING" && cpio --quiet -id)
else
  (cd "$STAGING" &&
   cpio --quiet -id < "$LINUX_INITRAMFS_SOURCE")
fi
test -f "$STAGING/init"
cp os/axvisor/guests/rt-ipc/linux/target/rtipic-client "$STAGING/bin/rtipic-client"
chmod +x "$STAGING/bin/rtipic-client"
# Update init script
cp os/axvisor/guests/linux-net/init-linux-1 "$STAGING/init"
chmod +x "$STAGING/init"
sed -i "s/--count [0-9][0-9]*/--count $RTIPC_COUNT --fault-profile $RTIPC_FAULT_PROFILE/" \
  "$STAGING/init"
(cd "$STAGING" && find . -print0 | \
  cpio --null -o --format=newc --owner=0:0 > "$LINUX_INITRAMFS")
rm -rf "$STAGING"
STAGING=
LINUX_VMCONFIG="$(
  "$LINUX_VMCONFIG_GENERATOR" "$ROOT" "$LINUX_VMCONFIG_TEMPLATE" \
    "$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS" "$LINUX_RUNTIME_DIR"
)"
record_runtime_artifact linux-initramfs "$LINUX_INITRAMFS"
record_runtime_artifact linux-vmconfig "$LINUX_VMCONFIG"
record_runtime_artifact rtthread-vmconfig "$RTTHREAD_VMCONFIG"
echo "  initramfs rebuilt: $(ls -la "$LINUX_INITRAMFS")"

# 4. Build Axvisor
echo "[4/5] Building Axvisor..."
cargo xtask axvisor build --config qemu-aarch64-two-guest-net \
  --vmconfigs "$LINUX_VMCONFIG" \
  --vmconfigs "$RTTHREAD_VMCONFIG"
rm -rf -- "$RTTHREAD_RUNTIME_DIR"
RTTHREAD_RUNTIME_DIR=
rm -rf -- "$LINUX_RUNTIME_DIR"
LINUX_RUNTIME_DIR=
build_axvisor_binary \
  target/aarch64-unknown-linux-musl/release/axvisor "$AXVISOR_BIN" "$ROOT/tmp"
trap - EXIT
record_runtime_artifact axvisor-bin "$AXVISOR_BIN"

# 5. Launch QEMU
echo "[5/5] Launching QEMU..."

: > "$LOG"
: > "$QEMU_LOG"
completion_markers=('RT-IPC client exited with rc=0')
qemu_args=(
  -display none
  -monitor none
  -snapshot
  -cpu cortex-a72
  -machine virt,virtualization=on,gic-version=3
  -global virtio-mmio.force-legacy=false
  -smp 4
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65
  -drive "id=disk0,if=none,format=raw,file=$ROOTFS_IMAGE"
  -append "root=/dev/nvme0n1 rw init=/bin/sh"
  -m 8g
  -netdev hubport,id=net0,hubid=77
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01
  -netdev hubport,id=net2,hubid=77
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03
  -kernel "$AXVISOR_BIN"
)
if [ "$RTBENCH_MODE" != none ]; then
  completion_markers+=("$RTBENCH_DONE_MARKER")
  if create_serial_session; then
    :
  else
    serial_session_rc=$?
    return "$serial_session_rc"
  fi
  rm -f -- "$RTBENCH_TIMING_LOG"
  mkfifo "$serial_input"
  exec 3<> "$serial_input"
  run_pid=
  socat_pid=
  feeder_pid=
  cpu_monitor_pid=
  qemu_pid_file="$serial_tmp/qemu.pid"
  install_serial_signal_handlers

  RUN_UNTIL_CHILD_PID_FILE="$qemu_pid_file" \
  "$RUN_UNTIL" "$RTIPC_TIMEOUT_S" "$LOG" "${completion_markers[@]}" -- \
    "$QEMU" -serial "unix:$serial_socket,server=on,wait=on" "${qemu_args[@]}" \
    > "$QEMU_LOG" 2>&1 &
  run_pid=$!

  qemu_pid=
  qemu_pid_deadline_ns=$(( $(date +%s%N) + 5000000000 ))
  while [ ! -s "$qemu_pid_file" ]; do
    if ! kill -0 "$run_pid" 2>/dev/null || \
       [ "$(date +%s%N)" -ge "$qemu_pid_deadline_ns" ]; then
      echo "QEMU PID did not become available" >> "$QEMU_LOG"
      break
    fi
    sleep 0.01
  done
  if [ -s "$qemu_pid_file" ]; then
    qemu_pid=$(cat "$qemu_pid_file")
    if apply_qemu_realtime_control_or_fail "$qemu_pid" "$QEMU_UCLAMP_MIN"; then
      qemu_realtime_control_rc=0
    else
      qemu_realtime_control_rc=$?
      return "$qemu_realtime_control_rc"
    fi
  fi

  socket_deadline_ns=$(( $(date +%s%N) + 5000000000 ))
  while [ ! -S "$serial_socket" ]; do
    if ! kill -0 "$run_pid" 2>/dev/null || \
       [ "$(date +%s%N)" -ge "$socket_deadline_ns" ]; then
      echo "QEMU serial socket did not become ready" >> "$QEMU_LOG"
      break
    fi
    sleep 0.05
  done
  if [ -S "$serial_socket" ]; then
    if [ -n "$CPU_LOAD_LOG" ]; then
      : > "$CPU_LOAD_LOG"
      if [ -z "$qemu_pid" ]; then
        echo "QEMU PID unavailable for CPU load sampler" >> "$QEMU_LOG"
        exit 1
      fi
      pidstat -h -t -p "$qemu_pid" 1 > "$CPU_LOAD_LOG" &
      cpu_monitor_pid=$!
    fi
    socat - "UNIX-CONNECT:$serial_socket" <&3 > "$LOG" &
    socat_pid=$!
    feed_rtthread_benchmark_command >&3 &
    feeder_pid=$!
  fi

  if wait "$run_pid"; then
    qemu_rc=0
  else
    qemu_rc=$?
  fi
  run_pid=
  if wait_for_feeder; then
    feeder_rc=0
  else
    feeder_rc=$?
  fi
  cleanup_serial_session
  trap - EXIT HUP INT TERM
  if [ "$feeder_rc" -ne 0 ]; then
    echo "RT-Thread benchmark feeder exited with code $feeder_rc" >> "$QEMU_LOG"
    qemu_rc=$feeder_rc
  fi
else
  if run_nonbenchmark_until_markers \
      "$RTIPC_TIMEOUT_S" "$LOG" "${completion_markers[@]}" -- \
      "$QEMU" -serial "file:$LOG" "${qemu_args[@]}" \
      < /dev/null > "$QEMU_LOG" 2>&1; then
    qemu_rc=0
  else
    qemu_rc=$?
  fi
fi
if [ "$RTBENCH_MODE" != none ] && [ -n "$CPU_LOAD_LOG" ] && [ ! -s "$CPU_LOAD_LOG" ]; then
  echo "CPU load sampler did not produce output: $CPU_LOAD_LOG" >&2
  exit 1
fi
if [ "$RTBENCH_MODE" != none ] && [ ! -s "$RTBENCH_TIMING_LOG" ]; then
  echo "Host benchmark timing log was not produced: $RTBENCH_TIMING_LOG" >&2
  exit 1
fi
echo "QEMU exited with code $qemu_rc"

echo ""
echo "--- RT-IPC Statistics ---"
grep -aE "RT-IPC|Payload|RTT|throughput|loss|sent=|recv=|ALL TESTS|connected|reconnect" "$LOG" || echo "No RT-IPC output found"
if [ "$RTBENCH_MODE" = stability ]; then
  echo ""
  echo "--- RT benchmark stability ---"
  grep -aE 'RTBENCH_STABILITY|RTBENCH metric=stability_jitter|RTBENCH metric=callback_exec' "$LOG" || true
elif [ "$RTBENCH_MODE" = suite ]; then
  echo ""
  echo "--- RT benchmark suite ---"
  grep -aE 'RTBENCH_BEGIN|RTBENCH metric=|RTBENCH_END' "$LOG" || true
fi
if [ "$RTBENCH_MODE" != none ]; then
  echo ""
  echo "--- Host benchmark timing ---"
  cat "$RTBENCH_TIMING_LOG"
fi

echo ""
echo "Full log: $LOG"
echo "Artifact manifest: $ARTIFACT_LOG"

echo ""
echo "=== Result Gate ==="
if os/axvisor/scripts/verify_rtipc_results.sh "$LOG" "$RTIPC_COUNT" "$qemu_rc" "$RTIPC_FAULT_PROFILE"; then
  echo "RT-IPC result gate: PASS"
else
  echo "FAILURE: RT-IPC integration test did not meet its postconditions" >&2
  exit 1
fi
if [ "$RTBENCH_MODE" = stability ]; then
  os/axvisor/scripts/verify_rtbench_stability.sh \
    "$LOG" "$RTBENCH_STABILITY_SECONDS" "$qemu_rc"
elif [ "$RTBENCH_MODE" = suite ]; then
  os/axvisor/scripts/verify_rtbench_suite.sh \
    "$LOG" "$RTBENCH_SUITE_SAMPLES" "$qemu_rc"
fi
echo "SUCCESS: all requested RT-IPC and benchmark gates passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
