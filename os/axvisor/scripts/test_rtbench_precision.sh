#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/../guests/zephyr-net/src/main.c"
CMAKE_SOURCE="${SCRIPT_DIR}/../guests/zephyr-net/CMakeLists.txt"
SETUP_SOURCE="${SCRIPT_DIR}/setup_qemu_three_guest_net.sh"
AXVISOR_CONFIG_SOURCE="${SCRIPT_DIR}/../src/config.rs"
ZEPHYR_VM_CONFIG="${SCRIPT_DIR}/../configs/vms/qemu/aarch64/zephyr-net.toml"

require_source() {
  local pattern="$1"
  local description="$2"
  rg -q --fixed-strings "$pattern" "$SOURCE" || {
    echo "[rtbench-precision] missing ${description}: ${pattern}" >&2
    exit 1
  }
}

require_source "rtbench_phase_error_cycles" "raw phase-error storage"
require_source "rtbench_interval_error_cycles" "raw interval-error storage"
require_source "rtbench_tick_gap" "timer tick-gap storage"
require_source "k_uptime_ticks()" "timer tick observation"
require_source "rtbench_cycles_to_ns" "nanosecond conversion"
require_source "phase_p99_9_ns" "nanosecond percentile reporting"
require_source "phase_p99_99_ns" "nanosecond p99.99 reporting"
require_source "interval_max_abs_ns" "interval-error reporting"
require_source "callback_duration_max_ns" "callback duration reporting"
require_source "tick_gap_max" "timer tick-gap reporting"
require_source "AXVISOR_RT_IRQ_TRACE" "optional timer IRQ trace switch"
require_source "__wrap_arm_gic_get_active" "GIC activity trace wrapper"
require_source "CNTVCT_EL0" "virtual counter trace"
require_source "CNTV_CVAL_EL0" "virtual compare trace"
require_source "CNTV_CTL_EL0" "virtual timer control trace"
require_source "rtbench_irq_entry_to_callback" "timer IRQ-to-callback trace"
require_source "rtbench_irq_trace_report" "timer IRQ trace report"
require_source "overdue_max_sample" "worst overdue sample index"
require_source "overdue_max_compare" "worst overdue compare anchor"
require_source "overdue_max_entry" "worst overdue IRQ-entry anchor"
require_source "trace_start_counter" "benchmark-start counter anchor"
require_source "report_counter" "benchmark-report counter anchor"
rg -q --fixed-strings -- "zephyr_link_libraries(-Wl,--wrap=arm_gic_get_active)" "$CMAKE_SOURCE" || {
	echo "[rtbench-precision] missing final-link GIC wrapper option" >&2
	exit 1
}
rg -q --fixed-strings "AXVISOR_THREE_GUEST_BUSYBOX" "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing static BusyBox override" >&2
	exit 1
}
rg -q --fixed-strings "statically linked" "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing static BusyBox validation" >&2
	exit 1
}
rg -q --fixed-strings "AXVISOR_THREE_GUEST_RTOS_PCPU" "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing RTOS vCPU placement override" >&2
	exit 1
}
rg -q --fixed-strings "AXVISOR_THREE_GUEST_HOST_TIMER_POLICY" "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing host timer policy override" >&2
	exit 1
}
rg -q --fixed-strings "AXVISOR_THREE_GUEST_HOST_VCPU_YIELD" "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing vCPU yield override" >&2
	exit 1
}
rg -q --fixed-strings \
  'HOST_VCPU_IDLE_POLICY="${AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY:-halt}"' \
  "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing safe-default host vCPU idle policy override" >&2
	exit 1
}
rg -q --fixed-strings 'local host_vcpu_idle_policy="${10:-}"' "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing optional host vCPU idle policy patch argument" >&2
	exit 1
}
rg -q --fixed-strings 'if [ -n "$host_vcpu_idle_policy" ]; then' "$SETUP_SOURCE" || {
	echo "[rtbench-precision] host vCPU idle policy patch must be optional" >&2
	exit 1
}
rg -q --fixed-strings 'host_vcpu_idle_policy = \"${host_vcpu_idle_policy}\"' "$SETUP_SOURCE" || {
	echo "[rtbench-precision] missing generated host vCPU idle policy field wiring" >&2
	exit 1
}
rg -q --fixed-strings '"$HOST_VCPU_IDLE_POLICY"' "$SETUP_SOURCE" || {
	echo "[rtbench-precision] Zephyr patch call must pass the selected host vCPU idle policy" >&2
	exit 1
}
rg -q -U --fixed-strings \
  $'host_vcpu_yield = false\nhost_vcpu_idle_policy = "halt"' \
  "$ZEPHYR_VM_CONFIG" || {
  echo "[rtbench-precision] checked-in Zephyr VM must default to halt immediately after vCPU yield" >&2
  exit 1
}
rg -q --fixed-strings "host_timer_policy" "$SETUP_SOURCE" || {
  echo "[rtbench-precision] missing per-VM host timer policy" >&2
  exit 1
}
rg -q --fixed-strings \
  'configured host policy: timer={:?}, vcpu_yield={}' \
  "$AXVISOR_CONFIG_SOURCE" || {
  echo "[rtbench-precision] missing configured VM host policy startup diagnostic" >&2
  exit 1
}
require_source "late_cycles * 1000000LL" "cycle-based deadline thresholds"
require_source "K_SEM_DEFINE(rtbench_done" "benchmark completion semaphore"
require_source "k_sem_give(&rtbench_done)" "benchmark completion signal"
require_source "k_sem_take(&rtbench_done, K_FOREVER)" "benchmark wait path"

callback_block="$(awk '/static void rtbench_expiry\(/,/^}/' "$SOURCE")"
for pattern in \
	"rtbench_cycles_to_us" \
	"rtbench_late_hist" \
	"rtbench_miss_100us" \
	"rtbench_miss_500us" \
	"rtbench_miss_1ms"; do
	if printf '%s\n' "$callback_block" | rg -q --fixed-strings "$pattern"; then
		echo "[rtbench-precision] callback must only record raw timing samples: ${pattern}" >&2
		exit 1
	fi
done

if rg -q --fixed-strings "k_sleep(K_MSEC(1))" "$SOURCE"; then
	echo "[rtbench-precision] benchmark main loop must not wake every millisecond" >&2
	exit 1
fi

# The interrupt-path experiment must be able to disable the polling fallback
# without changing the checked-in benchmark source between runs.
require_source "AXVISOR_DISABLE_VIRTIO_IRQ_POLL" "virtio polling diagnostic switch"
require_source "#if !defined(AXVISOR_DISABLE_VIRTIO_IRQ_POLL)" "polling fallback guard"

rg -q -U --fixed-strings \
  $'#if !defined(AXVISOR_DISABLE_VIRTIO_IRQ_POLL)\n\tconst struct device *vdev' \
  "$SOURCE" || {
  echo "[rtbench-precision] virtio device handle must be conditional with polling" >&2
  exit 1
}

rg -q --fixed-strings \
  "target_compile_definitions(app PRIVATE AXVISOR_DISABLE_VIRTIO_IRQ_POLL)" \
  "$CMAKE_SOURCE" || {
  echo "[rtbench-precision] checked-in Zephyr build must disable virtio polling" >&2
  exit 1
}

echo "[rtbench-precision] source contract passed"
