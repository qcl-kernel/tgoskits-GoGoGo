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

functional_root="$(mktemp -d "${TMPDIR:-/tmp}/rtbench-precision.XXXXXX")"
trap 'rm -rf -- "$functional_root"' EXIT INT TERM

fail_test() {
  echo "[rtbench-precision] functional test failed: $*" >&2
  exit 1
}

write_vm_fixture() {
  local output="$1"
  local include_idle_policy="$2"
  {
    printf '%s\n' \
      '[base]' \
      'id = 3' \
      'name = "fixture"' \
      'vm_type = 1' \
      'cpu_num = 1' \
      'phys_cpu_ids = [2]' \
      'host_timer_policy = "periodic"' \
      'host_vcpu_yield = false'
    if [ "$include_idle_policy" = true ]; then
      printf '%s\n' 'host_vcpu_idle_policy = "halt"'
    fi
    printf '%s\n' \
      '' \
      '[kernel]' \
      'entry_point = 0xa000_1000' \
      'image_location = "memory"' \
      'kernel_path = "/old/kernel"' \
      'kernel_load_addr = 0xa000_0000' \
      'dtb_load_addr = 0xaf00_0000' \
      'ramdisk_path = "/old/initramfs"' \
      'ramdisk_load_addr = 0xac00_0000' \
      'memory_regions = [[0xa000_0000, 0x1000_0000, 0x7, 2]]' \
      '' \
      '[devices]' \
      'interrupt_mode = "passthrough"' \
      'passthrough_devices = [["/virtio_mmio@a000400"]]' \
      'passthrough_addresses = []' \
      'excluded_devices = []' \
      'emu_devices = [[' \
      '  "gppt-gicr", 0x080a_0000, 0x2_0000, 0, 0x20, [1, 0x2_0000, 2]' \
      ']]'
  } >"$output"
}

run_patch_fixture() {
  local policy="$1"
  local template="$2"
  local output="$3"
  local kernel="$4"
  local idle_policy="${5:-}"
  AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY="$policy" \
  AXVISOR_THREE_GUEST_LINUX_IMAGE="${functional_root}/must-not-be-read" \
    bash -c '
      set -euo pipefail
      source "$1"
      patch_vm_config "$2" "$3" "$4" "" "" "" "" "" "" "$5"
    ' bash "$SETUP_SOURCE" "$template" "$output" "$kernel" "$idle_policy"
}

linux_template="${functional_root}/linux.toml"
zephyr_template="${functional_root}/zephyr.toml"
write_vm_fixture "$linux_template" false
write_vm_fixture "$zephyr_template" true
special_kernel="${functional_root}/kernel & back\\slash space \"quoted\""

for policy in halt busy; do
  policy_root="${functional_root}/${policy}"
  mkdir -p "$policy_root"
  run_patch_fixture "$policy" "$linux_template" "${policy_root}/linux-1.toml" "$special_kernel"
  run_patch_fixture "$policy" "$linux_template" "${policy_root}/linux-2.toml" "$special_kernel"
  run_patch_fixture "$policy" "$zephyr_template" "${policy_root}/zephyr.toml" "$special_kernel" "$policy"
  python3 - "$policy_root" "$policy" "$special_kernel" <<'PY' \
    || fail_test "generated ${policy} fixture contracts"
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
expected_policy = sys.argv[2]
expected_kernel = sys.argv[3]
linux_configs = [tomllib.loads((root / f"linux-{index}.toml").read_text()) for index in (1, 2)]
zephyr = tomllib.loads((root / "zephyr.toml").read_text())
assert all("host_vcpu_idle_policy" not in config["base"] for config in linux_configs)
assert zephyr["base"]["host_vcpu_idle_policy"] == expected_policy
assert sum(
    line.startswith("host_vcpu_idle_policy =")
    for line in (root / "zephyr.toml").read_text().splitlines()
) == 1
assert all(config["kernel"]["kernel_path"] == expected_kernel for config in linux_configs)
assert zephyr["kernel"]["kernel_path"] == expected_kernel
PY
done

missing_key_template="${functional_root}/missing-key.toml"
missing_key_output="${functional_root}/must-remain.toml"
cp "$zephyr_template" "$missing_key_template"
python3 - "$missing_key_template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("\n".join(
    line for line in path.read_text().splitlines() if not line.startswith("kernel_path =")
) + "\n")
PY
printf '%s\n' 'previous valid output' >"$missing_key_output"
missing_key_before="$(sha256sum -- "$missing_key_output")"
set +e
missing_key_error="$(
  run_patch_fixture halt "$missing_key_template" "$missing_key_output" "$special_kernel" halt 2>&1
)"
missing_key_status=$?
set -e
[ "$missing_key_status" -ne 0 ] || fail_test "missing requested TOML key was accepted"
printf '%s\n' "$missing_key_error" | rg -q 'requested TOML key.*kernel_path' \
  || fail_test "missing-key failure lacked a contextual diagnostic"
[ "$(sha256sum -- "$missing_key_output")" = "$missing_key_before" ] \
  || fail_test "failed patch replaced the previous output"

invalid_sentinel="${functional_root}/invalid-policy-external-action"
set +e
invalid_error="$(
  AXVISOR_THREE_GUEST_IMAGE_ROOT="$invalid_sentinel" \
  AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY=invalid \
    bash "$SETUP_SOURCE" 2>&1
)"
invalid_status=$?
set -e
[ "$invalid_status" -ne 0 ] || fail_test "invalid host vCPU idle policy was accepted"
printf '%s\n' "$invalid_error" \
  | rg -q --fixed-strings 'AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY must be halt or busy' \
  || fail_test "invalid policy failure lacked the expected diagnostic"
[ ! -e "$invalid_sentinel" ] || fail_test "invalid policy reached external setup work"

initramfs_root="${functional_root}/initramfs-fixture"
fixture_axvisor_root="${initramfs_root}/axvisor"
fixture_image_root="${initramfs_root}/images"
fixture_bin="${initramfs_root}/bin"
mkdir -p \
  "${fixture_axvisor_root}/guests/linux-net" \
  "${fixture_image_root}/linux-net-initramfs" \
  "$fixture_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' \
  >"${fixture_axvisor_root}/guests/linux-net/init-linux-1"
printf '%s\n' '#!/bin/sh' 'exit 0' \
  >"${fixture_axvisor_root}/guests/linux-net/init-linux-2"
printf '%s\n' 'fixture busybox' >"${initramfs_root}/busybox"
printf '%s\n' 'must never be packaged' \
  >"${fixture_image_root}/linux-net-initramfs/stale"
printf '%s\n' \
  '#!/bin/sh' \
  'for target do :; done' \
  'case "$target" in' \
  '  *dynamic-busybox) printf "%s: ELF fixture, dynamically linked\\n" "$target" ;;' \
  '  *) printf "%s: ELF fixture, statically linked\\n" "$target" ;;' \
  'esac' \
  >"${fixture_bin}/file"
chmod +x \
  "${fixture_axvisor_root}/guests/linux-net/init-linux-1" \
  "${fixture_axvisor_root}/guests/linux-net/init-linux-2" \
  "${initramfs_root}/busybox" \
  "${fixture_bin}/file"

mapfile -t prepared_initramfs < <(
  PATH="${fixture_bin}:${PATH}" \
  AXVISOR_THREE_GUEST_IMAGE_ROOT="$fixture_image_root" \
  AXVISOR_THREE_GUEST_BUSYBOX="${initramfs_root}/busybox" \
    bash -c '
      set -euo pipefail
      source "$1"
      AXVISOR_ROOT="$2"
      prepare_linux_initramfs
    ' bash "$SETUP_SOURCE" "$fixture_axvisor_root"
)
for archive in "${prepared_initramfs[@]}"; do
  case "$archive" in
    *-initramfs.cpio)
      if cpio --quiet -it <"$archive" | rg -q '(^|/)stale$'; then
        fail_test "persistent initramfs staging leaked a stale file into $(basename "$archive")"
      fi
      ;;
  esac
done
[ "${#prepared_initramfs[@]}" -eq 3 ] \
  || fail_test "initramfs preparation must report selected BusyBox and two archives"
[ "${prepared_initramfs[0]}" = "${fixture_image_root}/linux-net-busybox.selected" ] \
  || fail_test "initramfs preparation did not report its immutable BusyBox snapshot"
cmp -s -- "${prepared_initramfs[0]}" "${initramfs_root}/busybox" \
  || fail_test "selected BusyBox snapshot does not match the packaged bytes"
for archive in "${prepared_initramfs[@]:1}"; do
  archive_members="$(cpio --quiet -it <"$archive" | LC_ALL=C sort)"
  [ "$archive_members" = $'.\nbin\nbin/busybox\nbin/sh\ninit' ] \
    || fail_test "initramfs contains undeclared members: ${archive_members}"
done
if find "$fixture_image_root" -maxdepth 1 -type d -name 'linux-net-initramfs.*' | rg -q .; then
  fail_test "private initramfs staging directory was not cleaned"
fi

dynamic_source="${initramfs_root}/dynamic-busybox"
dynamic_archive_root="${initramfs_root}/dynamic-archive"
mkdir -p \
  "${dynamic_archive_root}/bin" \
  "${fixture_image_root}/qemu_aarch64_linux"
printf '%s\n' 'dynamic busybox fixture' >"$dynamic_source"
printf '%s\n' 'fallback static busybox fixture' >"${dynamic_archive_root}/bin/busybox"
chmod +x "$dynamic_source" "${dynamic_archive_root}/bin/busybox"
(cd "$dynamic_archive_root" && find . -print0 | cpio --null --quiet -o -H newc) \
  | gzip -n >"${fixture_image_root}/qemu_aarch64_linux/initramfs.cpio.gz"
mapfile -t dynamic_initramfs < <(
  PATH="${fixture_bin}:${PATH}" \
  AXVISOR_THREE_GUEST_IMAGE_ROOT="$fixture_image_root" \
  AXVISOR_THREE_GUEST_BUSYBOX="$dynamic_source" \
    bash -c '
      set -euo pipefail
      source "$1"
      AXVISOR_ROOT="$2"
      prepare_linux_initramfs
    ' bash "$SETUP_SOURCE" "$fixture_axvisor_root"
)
[ "${#dynamic_initramfs[@]}" -eq 3 ] \
  || fail_test "dynamic BusyBox fallback must report selected BusyBox and two archives"
for archive in "${dynamic_initramfs[@]:1}"; do
  archive_members="$(cpio --quiet -it <"$archive" | LC_ALL=C sort)"
  [ "$archive_members" = $'.\nbin\nbin/busybox\nbin/sh\ninit' ] \
    || fail_test "dynamic BusyBox scratch files leaked into initramfs: ${archive_members}"
done

manifest_root="${functional_root}/manifest-fixture"
mkdir -p "$manifest_root"
printf '%s\n' 'linux kernel bytes' >"${manifest_root}/linux-kernel"
printf '%s\n' 'rtos kernel bytes' >"${manifest_root}/rtos-kernel"
printf '%s\n' 'rootfs bytes' >"${manifest_root}/rootfs.img"
manifest_path="${manifest_root}/artifacts.tsv"
manifest_inputs=(
  linux-kernel "${manifest_root}/linux-kernel"
  rtos-kernel "${manifest_root}/rtos-kernel"
  rootfs "${manifest_root}/rootfs.img"
  busybox "${prepared_initramfs[0]}"
  linux-1-initramfs "${prepared_initramfs[1]}"
  linux-2-initramfs "${prepared_initramfs[2]}"
  linux-1-vm-config "${functional_root}/halt/linux-1.toml"
  linux-2-vm-config "${functional_root}/halt/linux-2.toml"
  zephyr-vm-config "${functional_root}/halt/zephyr.toml"
)

write_fixture_manifest() {
  bash -c '
    set -euo pipefail
    source "$1"
    shift
    write_artifact_manifest "$@"
  ' bash "$SETUP_SOURCE" "$manifest_path" "${manifest_inputs[@]}"
}

write_fixture_manifest
manifest_first_sha="$(sha256sum -- "$manifest_path")"
write_fixture_manifest
[ "$(sha256sum -- "$manifest_path")" = "$manifest_first_sha" ] \
  || fail_test "artifact manifest is not deterministic"
python3 - "$manifest_path" "${manifest_inputs[@]}" <<'PY' \
  || fail_test "artifact manifest hashes do not match selected bytes"
import hashlib
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
arguments = sys.argv[2:]
expected = []
for label, raw_path in zip(arguments[0::2], arguments[1::2]):
    path = pathlib.Path(raw_path).resolve()
    expected.append((label, str(path), hashlib.sha256(path.read_bytes()).hexdigest()))

lines = manifest.read_text().splitlines()
assert lines[0] == "version\t1"
actual = [tuple(line.split("\t")) for line in lines[1:]]
assert actual == expected
PY

manifest_before_missing="$(sha256sum -- "$manifest_path")"
missing_manifest_inputs=("${manifest_inputs[@]}")
missing_manifest_inputs[1]="${manifest_root}/missing-linux-kernel"
set +e
missing_manifest_error="$(
  bash -c '
    set -euo pipefail
    source "$1"
    shift
    write_artifact_manifest "$@"
  ' bash "$SETUP_SOURCE" "$manifest_path" "${missing_manifest_inputs[@]}" 2>&1
)"
missing_manifest_status=$?
set -e
[ "$missing_manifest_status" -ne 0 ] || fail_test "manifest accepted a missing artifact"
printf '%s\n' "$missing_manifest_error" | rg -q 'artifact does not exist.*missing-linux-kernel' \
  || fail_test "missing manifest artifact lacked a contextual diagnostic"
[ "$(sha256sum -- "$manifest_path")" = "$manifest_before_missing" ] \
  || fail_test "failed manifest generation replaced the previous manifest"

expected_guest_registry='https://raw.githubusercontent.com/arceos-hypervisor/axvisor-guest/504cabb5e07e506e2692b010e01204d20587f030/registry/v0.0.26.toml'
actual_guest_registry="$(
  env -u AXVISOR_THREE_GUEST_REGISTRY \
    bash -c 'source "$1"; printf "%s" "$GUEST_REGISTRY"' bash "$SETUP_SOURCE"
)"
[ "$actual_guest_registry" = "$expected_guest_registry" ] \
  || fail_test "default guest registry is not pinned to the resolved immutable commit"

provenance_root="${functional_root}/provenance-fixture"
provenance_bin="${provenance_root}/bin"
provenance_images="${provenance_root}/images"
provenance_repo="${provenance_root}/repo"
provenance_log="${provenance_root}/cargo.log"
mkdir -p \
  "$provenance_bin" \
  "${provenance_images}/qemu_aarch64_linux" \
  "$provenance_repo"
printf '%s\n' 'unverified cached kernel' \
  >"${provenance_images}/qemu_aarch64_linux/qemu-aarch64"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\\t%s\\n" "${TGOS_IMAGE_REGISTRY_FALLBACK_URL:-}" "$*" >>"$FAKE_CARGO_LOG"' \
  'output_dir=""' \
  'previous=""' \
  'for argument in "$@"; do' \
  '  if [ "$previous" = --output-dir ]; then output_dir="$argument"; fi' \
  '  previous="$argument"' \
  'done' \
  'if [ -n "$output_dir" ]; then' \
  '  image_name="${!#}"' \
  '  mkdir -p "${output_dir}/${image_name}"' \
  '  printf "%s\\n" "registry-verified kernel" >"${output_dir}/${image_name}/qemu-aarch64"' \
  'elif printf "%s\\n" "$*" | grep -q -- "--arch aarch64"; then' \
  '  mkdir -p "$TGOS_IMAGE_LOCAL_STORAGE"' \
  '  printf "%s\\n" "registry-verified rootfs" >"${TGOS_IMAGE_LOCAL_STORAGE}/rootfs-aarch64-alpine.img"' \
  'fi' \
  >"${provenance_bin}/cargo"
chmod +x "${provenance_bin}/cargo"

PATH="${provenance_bin}:${PATH}" \
FAKE_CARGO_LOG="$provenance_log" \
  bash -c '
    set -euo pipefail
    source "$1"
    IMAGE_ROOT="$2"
    REPO_ROOT="$3"
    pull_guest_image qemu_aarch64_linux >/dev/null
  ' bash "$SETUP_SOURCE" "$provenance_images" "$provenance_repo"
[ -s "$provenance_log" ] \
  || fail_test "seeded guest cache bypassed the image-tool checksum boundary"
IFS=$'\t' read -r observed_fallback observed_pull <"$provenance_log"
[ "$observed_fallback" = "$expected_guest_registry" ] \
  || fail_test "guest image pull did not pin its fallback registry"
printf '%s\n' "$observed_pull" \
  | rg -q --fixed-strings -- "--registry ${expected_guest_registry}" \
  || fail_test "guest image pull did not use the pinned registry"

rootfs_target="${provenance_root}/rootfs-target.img"
printf '%s\n' 'blind cached rootfs' >"$rootfs_target"
rootfs_log_lines_before="$(wc -l <"$provenance_log")"
PATH="${provenance_bin}:${PATH}" \
FAKE_CARGO_LOG="$provenance_log" \
  bash -c '
    set -euo pipefail
    source "$1"
    IMAGE_ROOT="$2"
    REPO_ROOT="$3"
    ROOTFS_TARGET="$4"
    unset AXVISOR_THREE_GUEST_ROOTFS
    prepare_rootfs >/dev/null
  ' bash "$SETUP_SOURCE" "$provenance_images" "$provenance_repo" "$rootfs_target"
[ "$(wc -l <"$provenance_log")" -eq "$((rootfs_log_lines_before + 1))" ] \
  || fail_test "non-explicit rootfs cache bypassed the image-tool checksum boundary"
rg -q --fixed-strings 'registry-verified rootfs' "$rootfs_target" \
  || fail_test "rootfs target was not refreshed from image-tool-validated bytes"

rootfs_atomic_root="${functional_root}/rootfs-atomic-fixture"
rootfs_atomic_bin="${rootfs_atomic_root}/bin"
mkdir -p "$rootfs_atomic_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'for destination do :; done' \
  'printf "%s\\n" "partial rootfs" >"$destination"' \
  'exit 1' \
  >"${rootfs_atomic_bin}/cp"
chmod +x "${rootfs_atomic_bin}/cp"
printf '%s\n' 'new rootfs bytes' >"${rootfs_atomic_root}/source.img"
printf '%s\n' 'old complete rootfs' >"${rootfs_atomic_root}/target.img"
rootfs_before_failure="$(sha256sum -- "${rootfs_atomic_root}/target.img")"
set +e
rootfs_atomic_error="$(
  PATH="${rootfs_atomic_bin}:${PATH}" \
  AXVISOR_THREE_GUEST_ROOTFS="${rootfs_atomic_root}/source.img" \
    bash -c '
      set -euo pipefail
      source "$1"
      ROOTFS_TARGET="$2/target.img"
      prepare_rootfs >/dev/null
    ' bash "$SETUP_SOURCE" "$rootfs_atomic_root" 2>&1
)"
rootfs_atomic_status=$?
set -e
[ "$rootfs_atomic_status" -ne 0 ] || fail_test "failed rootfs copy was accepted"
[ "$(sha256sum -- "${rootfs_atomic_root}/target.img")" = "$rootfs_before_failure" ] \
  || fail_test "failed rootfs copy exposed partial destination bytes"
if find "$rootfs_atomic_root" -maxdepth 1 -name '.target.img.tmp.*' | rg -q .; then
  fail_test "failed rootfs copy left a destination-side temporary file"
fi

topology_fixture_root="${functional_root}/topology-fixture"
topology_vm_root="${topology_fixture_root}/vms"
topology_qemu_config="${topology_fixture_root}/qemu.toml"
mkdir -p "$topology_vm_root"
cp "${SCRIPT_DIR}/../configs/vms/qemu/aarch64/linux-net-1.toml" "$topology_vm_root/"
cp "${SCRIPT_DIR}/../configs/vms/qemu/aarch64/linux-net-2.toml" "$topology_vm_root/"
cp "${SCRIPT_DIR}/../configs/vms/qemu/aarch64/zephyr-net.toml" "$topology_vm_root/"
cp "${SCRIPT_DIR}/../configs/qemu/qemu-aarch64-three-guest-net.toml" "$topology_qemu_config"

run_topology_fixture() {
  local vm_root="$1"
  local qemu_config="$2"
  AXVISOR_THREE_GUEST_VERIFY_VM_ROOT="$vm_root" \
  AXVISOR_THREE_GUEST_VERIFY_QEMU_CONFIG="$qemu_config" \
  AXVISOR_THREE_GUEST_VERIFY_EXPECTED_IDLE_POLICY=halt \
  AXVISOR_THREE_GUEST_VERIFY_TOPOLOGY_ONLY=1 \
    bash "${SCRIPT_DIR}/verify_three_guest_net.sh"
}

for topology_input in "$topology_vm_root"/*.toml "$topology_qemu_config"; do
  printf '%s\n' \
    '# comments mentioning ivc, shared_memory, virtio,vsock, and vhost-user-vsock-pci are inert' \
    >>"$topology_input"
done
run_topology_fixture "$topology_vm_root" "$topology_qemu_config" >/dev/null \
  || fail_test "topology comments triggered a forbidden-transport false positive"

comments_only_root="${functional_root}/topology-comments-only"
cp -a "$topology_fixture_root" "$comments_only_root"
python3 - "${comments_only_root}/vms/linux-net-1.toml" "${comments_only_root}/qemu.toml" <<'PY'
import pathlib
import sys

vm_path = pathlib.Path(sys.argv[1])
vm_text = vm_path.read_text().replace("id = 1\n", "id = 11\n", 1)
vm_path.write_text(vm_text + "# id = 1\n")

qemu_path = pathlib.Path(sys.argv[2])
required = "virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01"
qemu_text = qemu_path.read_text().replace(required, "disabled-net-device", 1)
qemu_path.write_text(qemu_text + f"# {required}\n")
PY
set +e
comments_only_error="$(
  run_topology_fixture "${comments_only_root}/vms" "${comments_only_root}/qemu.toml" 2>&1
)"
comments_only_status=$?
set -e
[ "$comments_only_status" -ne 0 ] \
  || fail_test "comments satisfied missing live VM/QEMU topology"
printf '%s\n' "$comments_only_error" | rg -q 'VM 1|QEMU network topology' \
  || fail_test "missing live topology lacked a contextual diagnostic"

artifact_paths_root="${functional_root}/topology-artifact-paths"
cp -a "$topology_fixture_root" "$artifact_paths_root"
python3 - \
  "${artifact_paths_root}/vms/linux-net-1.toml" \
  "${artifact_paths_root}/vms/linux-net-2.toml" \
  "${artifact_paths_root}/vms/zephyr-net.toml" \
  "${artifact_paths_root}/qemu.toml" <<'PY'
import pathlib
import re
import sys

linux_1, linux_2, zephyr, qemu = map(pathlib.Path, sys.argv[1:])
linux_1.write_text(re.sub(
    r'^kernel_path = .*$',
    'kernel_path = "/artifacts/shared_mem_backend/linux-kernel"',
    linux_1.read_text(),
    count=1,
    flags=re.MULTILINE,
))
linux_2.write_text(re.sub(
    r'^ramdisk_path = .*$',
    'ramdisk_path = "/artifacts/ivc/linux-initramfs"',
    linux_2.read_text(),
    count=1,
    flags=re.MULTILINE,
))
zephyr.write_text(re.sub(
    r'^kernel_path = .*$',
    'kernel_path = "/artifacts/vsock/zephyr-kernel"',
    zephyr.read_text(),
    count=1,
    flags=re.MULTILINE,
))
qemu.write_text(qemu.read_text().replace(
    'id=disk0,if=none,format=raw,file=${workspace}/tmp/rootfs.img',
    'id=disk0,if=none,format=raw,file=/artifacts/shared-mem/rootfs-vsock.img',
    1,
))
PY
run_topology_fixture "${artifact_paths_root}/vms" "${artifact_paths_root}/qemu.toml" >/dev/null \
  || fail_test "forbidden-looking artifact paths were treated as live transports"

for forbidden_live_value in \
  'virtio,vsock' \
  'vhost-user-vsock-pci' \
  'shared_mem_backend' \
  'shared-mem-backend' \
  'shared-memory-backend' \
  'shmem-device' \
  'ivc-channel'; do
  forbidden_fixture="${functional_root}/topology-forbidden-${forbidden_live_value//[^a-zA-Z0-9]/-}"
  cp -a "$topology_fixture_root" "$forbidden_fixture"
  python3 - "${forbidden_fixture}/qemu.toml" "$forbidden_live_value" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = sys.argv[2]
text = path.read_text()
marker = "]\nfail_regex"
path.write_text(text.replace(
    marker,
    f"  \"-device\",\n  {json.dumps(value)},\n]\nfail_regex",
    1,
))
PY
  set +e
  forbidden_error="$(
    run_topology_fixture "${forbidden_fixture}/vms" "${forbidden_fixture}/qemu.toml" 2>&1
  )"
  forbidden_status=$?
  set -e
  [ "$forbidden_status" -ne 0 ] \
    || fail_test "live forbidden topology value was accepted: ${forbidden_live_value}"
  printf '%s\n' "$forbidden_error" | rg -qi 'virtio-net only|forbidden' \
    || fail_test "forbidden topology lacked a contextual diagnostic: ${forbidden_live_value}"
done

full_verify_root="${functional_root}/setup-full-verify"
full_verify_bin="${full_verify_root}/bin"
full_verify_sentinel="${full_verify_root}/source-validation-requested"
real_rg="$(command -v rg)"
mkdir -p "$full_verify_bin" "${full_verify_root}/images"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'for argument in "$@"; do' \
  '  case "$argument" in' \
  '    */guests/zephyr-net/prj.conf)' \
  '      : >"$FULL_VERIFY_SENTINEL"' \
  '      exit 1' \
  '      ;;' \
  '  esac' \
  'done' \
  'exec "$REAL_RG" "$@"' \
  >"${full_verify_bin}/rg"
printf '%s\n' \
  '#!/bin/sh' \
  'for target do :; done' \
  'printf "%s: ELF fixture, statically linked\\n" "$target"' \
  >"${full_verify_bin}/file"
chmod +x "${full_verify_bin}/rg" "${full_verify_bin}/file"
printf '%s\n' 'local Linux kernel' >"${full_verify_root}/linux-kernel"
printf '%s\n' 'local RTOS kernel' >"${full_verify_root}/rtos-kernel"
printf '%s\n' 'local rootfs' >"${full_verify_root}/rootfs.img"
printf '%s\n' 'local static BusyBox' >"${full_verify_root}/busybox"
chmod +x "${full_verify_root}/busybox"

set +e
full_verify_error="$(
  PATH="${full_verify_bin}:${PATH}" \
  REAL_RG="$real_rg" \
  FULL_VERIFY_SENTINEL="$full_verify_sentinel" \
  AXVISOR_THREE_GUEST_VERIFY_TOPOLOGY_ONLY=1 \
  AXVISOR_THREE_GUEST_IMAGE_ROOT="${full_verify_root}/images" \
  AXVISOR_THREE_GUEST_LINUX_IMAGE="${full_verify_root}/linux-kernel" \
  AXVISOR_THREE_GUEST_RTOS_IMAGE="${full_verify_root}/rtos-kernel" \
  AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT=0xa0001114 \
  AXVISOR_THREE_GUEST_BUSYBOX="${full_verify_root}/busybox" \
  AXVISOR_THREE_GUEST_ROOTFS="${full_verify_root}/rootfs.img" \
    bash -c '
      set -euo pipefail
      source "$1"
      IMAGE_ROOT="$2/images"
      GENERATED_ROOT="$2/generated"
      ROOTFS_TARGET="$2/rootfs-target.img"
      main
    ' bash "$SETUP_SOURCE" "$full_verify_root" 2>&1
)"
full_verify_status=$?
set -e
[ "$full_verify_status" -ne 0 ] \
  || fail_test "setup inherited topology-only mode and skipped full verification"
[ -f "$full_verify_sentinel" ] \
  || fail_test "setup did not request mandatory source verification"
printf '%s\n' "$full_verify_error" | rg -q 'Zephyr must configure networking from main' \
  || fail_test "full setup verification failure lacked the expected source diagnostic"

canonical_qemu_root="${functional_root}/canonical-qemu-fixture"
canonical_qemu_bin="${canonical_qemu_root}/bin"
canonical_qemu_config="${canonical_qemu_root}/qemu-aarch64-three-guest-net.toml"
mkdir -p "$canonical_qemu_bin" "${canonical_qemu_root}/images"
cp "${full_verify_bin}/file" "${canonical_qemu_bin}/file"
cp "$topology_qemu_config" "$canonical_qemu_config"
python3 - "$canonical_qemu_config" <<'PY'
import pathlib

path = pathlib.Path(__import__("sys").argv[1])
text = path.read_text()
marker = "]\nfail_regex"
path.write_text(text.replace(
    marker,
    '  "-device",\n  "shared_mem_backend",\n]\nfail_regex',
    1,
))
PY
set +e
canonical_qemu_error="$(
  PATH="${canonical_qemu_bin}:${PATH}" \
  AXVISOR_THREE_GUEST_VERIFY_QEMU_CONFIG="$topology_qemu_config" \
  AXVISOR_THREE_GUEST_IMAGE_ROOT="${canonical_qemu_root}/images" \
  AXVISOR_THREE_GUEST_LINUX_IMAGE="${full_verify_root}/linux-kernel" \
  AXVISOR_THREE_GUEST_RTOS_IMAGE="${full_verify_root}/rtos-kernel" \
  AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT=0xa0001114 \
  AXVISOR_THREE_GUEST_BUSYBOX="${full_verify_root}/busybox" \
  AXVISOR_THREE_GUEST_ROOTFS="${full_verify_root}/rootfs.img" \
    bash -c '
      set -euo pipefail
      source "$1"
      IMAGE_ROOT="$2/images"
      GENERATED_ROOT="$2/generated"
      ROOTFS_TARGET="$2/rootfs-target.img"
      QEMU_CONFIG="$2/qemu-aarch64-three-guest-net.toml"
      main
    ' bash "$SETUP_SOURCE" "$canonical_qemu_root" 2>&1
)"
canonical_qemu_status=$?
set -e
[ "$canonical_qemu_status" -ne 0 ] \
  || fail_test "inherited verifier QEMU override hid forbidden canonical topology"
printf '%s\n' "$canonical_qemu_error" | rg -q 'virtio-net only.*shared_mem_backend' \
  || fail_test "canonical QEMU topology failure lacked the forbidden live value"

publication_root="${functional_root}/publication-fixture"
publication_bin="${publication_root}/bin"
mkdir -p "$publication_bin"
cp "${full_verify_bin}/file" "${publication_bin}/file"

published_set_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import sys

current = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
digest.update(os.readlink(current).encode())
for name in ("artifacts.tsv", "linux-net-1.toml", "linux-net-2.toml", "zephyr-net.toml"):
    digest.update(name.encode())
    digest.update((current / name).read_bytes())
print(digest.hexdigest())
PY
}

for failure_step in config verification manifest post-switch; do
  failure_root="${publication_root}/${failure_step}"
  published_root="${failure_root}/published"
  old_run="${published_root}/old-complete-set"
  mkdir -p "$old_run" "${failure_root}/images"
  for published_name in artifacts.tsv linux-net-1.toml linux-net-2.toml zephyr-net.toml; do
    printf 'old complete %s\n' "$published_name" >"${old_run}/${published_name}"
  done
  ln -s old-complete-set "${published_root}/current"
  published_before="$(published_set_snapshot "${published_root}/current")"

  set +e
  publication_error="$(
    PATH="${publication_bin}:${PATH}" \
    AXVISOR_THREE_GUEST_IMAGE_ROOT="${failure_root}/images" \
    AXVISOR_THREE_GUEST_LINUX_IMAGE="${full_verify_root}/linux-kernel" \
    AXVISOR_THREE_GUEST_RTOS_IMAGE="${full_verify_root}/rtos-kernel" \
    AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT=0xa0001114 \
    AXVISOR_THREE_GUEST_BUSYBOX="${full_verify_root}/busybox" \
    AXVISOR_THREE_GUEST_ROOTFS="${full_verify_root}/rootfs.img" \
      bash -c '
        set -euo pipefail
        source "$1"
        IMAGE_ROOT="$2/images"
        GENERATED_BASE="$2/published"
        GENERATED_ROOT="$GENERATED_BASE/current"
        ROOTFS_TARGET="$2/rootfs-target.img"
        QEMU_CONFIG="$3"
        case "$4" in
          config)
            patch_calls=0
            patch_vm_config() {
              patch_calls=$((patch_calls + 1))
              if [ "$patch_calls" -eq 3 ]; then
                return 1
              fi
              printf "new partial config %s\n" "$patch_calls" >"$2"
            }
            ;;
          verification)
            verify_generated_set() { return 1; }
            ;;
          manifest)
            write_artifact_manifest() { return 1; }
            ;;
          post-switch)
            publish_generated_set() {
              temporary_link="$GENERATED_BASE/.post-switch-current"
              ln -s "${1##*/}" "$temporary_link"
              mv -Tf -- "$temporary_link" "$GENERATED_ROOT"
              return 1
            }
            ;;
        esac
        main
      ' bash "$SETUP_SOURCE" "$failure_root" "$topology_qemu_config" "$failure_step" 2>&1
  )"
  publication_status=$?
  set -e
  [ "$publication_status" -ne 0 ] \
    || fail_test "injected ${failure_step} failure was accepted"
  if [ "$failure_step" = post-switch ]; then
    [ -d "${published_root}/current" ] \
      || fail_test "post-switch failure cleanup left the published link dangling"
  else
    [ "$(published_set_snapshot "${published_root}/current")" = "$published_before" ] \
      || fail_test "injected ${failure_step} failure changed the published set"
  fi
done

preflight_root="${functional_root}/preflight-fixture"
preflight_bin="${preflight_root}/bin"
mkdir -p "$preflight_bin"
for required_command in python3 cpio file mktemp sort touch; do
  required_path="$(command -v "$required_command")"
  ln -s "$required_path" "${preflight_bin}/${required_command}"
done
set +e
preflight_error="$(
  bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2"
    preflight_common
  ' bash "$SETUP_SOURCE" "$preflight_bin" 2>&1
)"
preflight_status=$?
set -e
[ "$preflight_status" -ne 0 ] || fail_test "common preflight accepted a missing rg"
printf '%s\n' "$preflight_error" | rg -q 'rg is required.*three-guest' \
  || fail_test "missing common command lacked a contextual preflight diagnostic"

readlink_preflight_bin="${preflight_root}/without-readlink"
mkdir -p "$readlink_preflight_bin"
for required_command in \
  python3 rg cpio file mktemp sort touch find cp chmod mv rm mkdir ln; do
  required_path="$(command -v "$required_command")"
  ln -s "$required_path" "${readlink_preflight_bin}/${required_command}"
done
set +e
readlink_preflight_error="$(
  bash -c '
    set -euo pipefail
    source "$1"
    PATH="$2"
    preflight_common
  ' bash "$SETUP_SOURCE" "$readlink_preflight_bin" 2>&1
)"
readlink_preflight_status=$?
set -e
[ "$readlink_preflight_status" -ne 0 ] \
  || fail_test "common preflight accepted a missing readlink"
printf '%s\n' "$readlink_preflight_error" | rg -q 'readlink is required.*rootfs' \
  || fail_test "missing readlink lacked a contextual preflight diagnostic"

rtos_preflight_bin="${preflight_root}/rtos-bin"
mkdir -p "$rtos_preflight_bin"
for build_command in cmake ninja readelf; do
  printf '%s\n' '#!/bin/sh' 'exit 0' >"${rtos_preflight_bin}/${build_command}"
  chmod +x "${rtos_preflight_bin}/${build_command}"
done
for missing_build_command in ninja readelf; do
  disabled_command="${rtos_preflight_bin}/${missing_build_command}"
  mv "$disabled_command" "${disabled_command}.disabled"
  set +e
  build_preflight_error="$(
    bash -c '
      set -euo pipefail
      source "$1"
      PATH="$2"
      preflight_rtos_build
    ' bash "$SETUP_SOURCE" "$rtos_preflight_bin" 2>&1
  )"
  build_preflight_status=$?
  set -e
  mv "${disabled_command}.disabled" "$disabled_command"
  [ "$build_preflight_status" -ne 0 ] \
    || fail_test "RTOS build preflight accepted missing ${missing_build_command}"
  printf '%s\n' "$build_preflight_error" | rg -q "${missing_build_command} is required.*Zephyr" \
    || fail_test "missing ${missing_build_command} lacked a contextual build preflight diagnostic"
done

echo "[rtbench-precision] source contract passed"
