#!/usr/bin/env bash
set -euo pipefail

# Prepare two Linux guests and one Zephyr guest for the QEMU three-NIC Axvisor
# experiment. The generated VM configs intentionally live under tmp/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXVISOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${AXVISOR_ROOT}/../.." && pwd)"
IMAGE_ROOT="${AXVISOR_THREE_GUEST_IMAGE_ROOT:-/tmp/.axvisor-images}"
GUEST_REGISTRY="${AXVISOR_THREE_GUEST_REGISTRY:-https://raw.githubusercontent.com/arceos-hypervisor/axvisor-guest/refs/heads/main/registry/v0.0.26.toml}"
LINUX_IMAGE_NAME="qemu_aarch64_linux"
GENERATED_ROOT="${REPO_ROOT}/tmp/vmconfigs/three-guest-net"
ROOTFS_TARGET="${REPO_ROOT}/tmp/rootfs.img"
RTOS_ENTRY_POINT="${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-}"
RTOS_PCPU="${AXVISOR_THREE_GUEST_RTOS_PCPU:-2}"
HOST_TIMER_POLICY="${AXVISOR_THREE_GUEST_HOST_TIMER_POLICY:-periodic}"
HOST_VCPU_YIELD="${AXVISOR_THREE_GUEST_HOST_VCPU_YIELD:-false}"
HOST_VCPU_IDLE_POLICY="${AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY:-halt}"
PREPARED_RTOS_KERNEL=""

die() {
  echo "[three-guest-net] ERROR: $*" >&2
  exit 1
}

case "$HOST_TIMER_POLICY" in
  periodic|tickless) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_TIMER_POLICY must be periodic or tickless" ;;
esac

case "$HOST_VCPU_YIELD" in
  true|false) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_VCPU_YIELD must be true or false" ;;
esac

case "$HOST_VCPU_IDLE_POLICY" in
  halt|busy) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY must be halt or busy" ;;
esac

find_kernel() {
  local image_dir="$1"
  local candidate
  for candidate in \
    "${image_dir}/qemu-aarch64" \
    "${image_dir}/qemu-aarch64.bin" \
    "${image_dir}/linux-qemu" \
    "${image_dir}/zephyr-qemu" \
    "${image_dir}/zephyr-qemu.bin"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  find "$image_dir" -maxdepth 2 -type f \( -name 'qemu-aarch64*' -o -name 'linux-qemu*' -o -name 'zephyr-qemu*' \) -print -quit
}

pull_guest_image() {
  local image_name="$1"
  local image_dir="${IMAGE_ROOT}/${image_name}"
  if [ -d "$image_dir" ]; then
    printf '%s\n' "$image_dir"
    return 0
  fi

  command -v cargo >/dev/null 2>&1 || die "cargo is required to pull ${image_name}"
  mkdir -p "$IMAGE_ROOT"
  echo "[three-guest-net] pulling ${image_name} from ${GUEST_REGISTRY}" >&2
  if ! (cd "$REPO_ROOT" && \
    TGOS_IMAGE_LOCAL_STORAGE="${IMAGE_ROOT}/managed" \
    cargo xtask image pull \
      --registry "$GUEST_REGISTRY" \
      --output-dir "$IMAGE_ROOT" \
      "$image_name" >&2); then
    die "unable to pull ${image_name}; provide a local kernel with AXVISOR_THREE_GUEST_LINUX_IMAGE or AXVISOR_THREE_GUEST_RTOS_IMAGE"
  fi
  [ -d "$image_dir" ] || die "image pull did not create ${image_dir}"
  printf '%s\n' "$image_dir"
}

prepare_linux_kernel() {
  if [ -n "${AXVISOR_THREE_GUEST_LINUX_IMAGE:-}" ]; then
    [ -f "$AXVISOR_THREE_GUEST_LINUX_IMAGE" ] || die "Linux image does not exist: ${AXVISOR_THREE_GUEST_LINUX_IMAGE}"
    printf '%s\n' "$AXVISOR_THREE_GUEST_LINUX_IMAGE"
    return 0
  fi

  local image_dir
  image_dir="$(pull_guest_image "$LINUX_IMAGE_NAME")"
  local kernel
  kernel="$(find_kernel "$image_dir")"
  [ -n "$kernel" ] && [ -f "$kernel" ] || die "no QEMU AArch64 Linux kernel found under ${image_dir}"
  printf '%s\n' "$kernel"
}

prepare_rtos_kernel() {
  if [ -n "${AXVISOR_THREE_GUEST_RTOS_IMAGE:-}" ]; then
    [ -n "$RTOS_ENTRY_POINT" ] || die "AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT is required with a prebuilt RTOS .bin image"
    if [ -f "$AXVISOR_THREE_GUEST_RTOS_IMAGE" ]; then
      PREPARED_RTOS_KERNEL="$AXVISOR_THREE_GUEST_RTOS_IMAGE"
      return 0
    fi
    if [ -d "$AXVISOR_THREE_GUEST_RTOS_IMAGE" ]; then
      local explicit_kernel
      explicit_kernel="$(find_kernel "$AXVISOR_THREE_GUEST_RTOS_IMAGE")"
      [ -n "$explicit_kernel" ] && [ -f "$explicit_kernel" ] || die "no Zephyr QEMU kernel found under ${AXVISOR_THREE_GUEST_RTOS_IMAGE}"
      PREPARED_RTOS_KERNEL="$explicit_kernel"
      return 0
    fi
    die "RTOS image does not exist: ${AXVISOR_THREE_GUEST_RTOS_IMAGE}"
  fi

  local zephyr_base="${ZEPHYR_BASE:-}"
  local cross_compile="${CROSS_COMPILE:-}"
  local zephyr_build="${IMAGE_ROOT}/zephyr-net-build"
  local zephyr_app="${AXVISOR_ROOT}/guests/zephyr-net"
  local zephyr_overlay="${zephyr_app}/virtnet.overlay"
  local extra_cflags="${AXVISOR_THREE_GUEST_ZEPHYR_EXTRA_CFLAGS:--Did_aa64isar2_el1=S3_0_C0_C6_2}"

  [ -d "$zephyr_base" ] || die "ZEPHYR_BASE is required to build the checked-in network guest; set ZEPHYR_BASE or provide AXVISOR_THREE_GUEST_RTOS_IMAGE"
  command -v cmake >/dev/null 2>&1 || die "cmake is required to build the checked-in Zephyr network guest"
  [ -f "${zephyr_app}/CMakeLists.txt" ] || die "missing checked-in Zephyr guest at ${zephyr_app}"

  local -a cmake_args=(
    -S "$zephyr_app"
    -B "$zephyr_build"
    -GNinja
    -DBOARD=qemu_cortex_a53
    -DDTC_OVERLAY_FILE="$zephyr_overlay"
    -DEXTRA_CFLAGS="$extra_cflags"
  )
  if [ -n "$cross_compile" ]; then
    cmake_args+=("-DCROSS_COMPILE=${cross_compile}")
    if [ -x "${cross_compile}gcc" ]; then
      cmake_args+=("-DCMAKE_C_COMPILER=${cross_compile}gcc")
    fi
  fi
  if [ "${AXVISOR_THREE_GUEST_RT_IRQ_TRACE:-0}" = "1" ]; then
    cmake_args+=("-DAXVISOR_RT_IRQ_TRACE=ON")
  fi

  echo "[three-guest-net] building the checked-in Zephyr virtio-net guest" >&2
  ZEPHYR_BASE="$zephyr_base" \
    ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-cross-compile}" \
    cmake "${cmake_args[@]}" >&2
  cmake --build "$zephyr_build" >&2

  local kernel="${zephyr_build}/zephyr/zephyr.bin"
  local elf="${zephyr_build}/zephyr/zephyr.elf"
  [ -f "$kernel" ] && [ -f "$elf" ] || die "Zephyr build did not produce ${kernel}"
  RTOS_ENTRY_POINT="$(readelf -h "$elf" | awk '/Entry point address:/ { print $NF }')"
  [ -n "$RTOS_ENTRY_POINT" ] || die "unable to read Zephyr entry point from ${elf}"
  PREPARED_RTOS_KERNEL="$kernel"
}

prepare_rootfs() {
  local source="${AXVISOR_THREE_GUEST_ROOTFS:-}"
  if [ -z "$source" ] && [ -f "$ROOTFS_TARGET" ]; then
    source="$ROOTFS_TARGET"
  fi
  if [ -z "$source" ] && [ -f "${REPO_ROOT}/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img" ]; then
    source="${REPO_ROOT}/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img"
  fi

  if [ -z "$source" ]; then
    command -v cargo >/dev/null 2>&1 || die "cargo is required to prepare the QEMU rootfs"
    local rootfs_store="${IMAGE_ROOT}/rootfs-managed"
    echo "[three-guest-net] pulling the AArch64 QEMU rootfs"
    (cd "$REPO_ROOT" && \
      TGOS_IMAGE_LOCAL_STORAGE="$rootfs_store" \
      cargo xtask image pull --arch aarch64)
    source="$(find "$rootfs_store" -type f -name 'rootfs-aarch64-alpine.img' -print -quit)"
  fi

  [ -f "$source" ] || die "QEMU rootfs image does not exist: ${source}"
  mkdir -p "$(dirname "$ROOTFS_TARGET")"
  if [ "$(readlink -f "$source")" != "$(readlink -f "$ROOTFS_TARGET")" ]; then
    cp "$source" "$ROOTFS_TARGET"
  fi
  printf '%s\n' "$ROOTFS_TARGET"
}

prepare_linux_initramfs() {
  local busybox="${IMAGE_ROOT}/linux-net-busybox"
  local staging_root="${IMAGE_ROOT}/linux-net-initramfs"

  command -v debugfs >/dev/null 2>&1 || die "debugfs is required to extract busybox from the Linux rootfs"
  command -v cpio >/dev/null 2>&1 || die "cpio is required to build the Linux guest initramfs"
  command -v file >/dev/null 2>&1 || die "file is required to validate the Linux initramfs busybox"
  mkdir -p "$IMAGE_ROOT" "$staging_root/bin"
  if [ -n "${AXVISOR_THREE_GUEST_BUSYBOX:-}" ]; then
    busybox="${AXVISOR_THREE_GUEST_BUSYBOX}"
    [ -f "$busybox" ] || die "static BusyBox does not exist: ${busybox}"
  else
    local debugfs_log="${IMAGE_ROOT}/debugfs-busybox.log"
    if ! debugfs -R "dump /bin/busybox ${busybox}" "$ROOTFS_TARGET" >"$debugfs_log" 2>&1; then
      die "unable to extract /bin/busybox from ${ROOTFS_TARGET}; see ${debugfs_log}"
    fi
  fi
  [ -s "$busybox" ] || die "Linux BusyBox is empty: ${busybox}"

  # The rootfs BusyBox is commonly dynamic, while the tiny initramfs has no
  # loader. Prefer the static binary shipped in the downloaded guest image.
  if ! file -L "$busybox" | rg -q "statically linked"; then
    local guest_initramfs="${IMAGE_ROOT}/${LINUX_IMAGE_NAME}/initramfs.cpio.gz"
    local static_root="${IMAGE_ROOT}/linux-net-static-busybox"
    [ -f "$guest_initramfs" ] || die "dynamic BusyBox requires a static guest initramfs: ${guest_initramfs}"
    mkdir -p "${static_root}/bin"
    if [ ! -s "${static_root}/bin/busybox" ]; then
      gzip -dc "$guest_initramfs" | (cd "$static_root" && cpio --quiet -id bin/busybox) \
        || die "unable to extract static BusyBox from ${guest_initramfs}"
    fi
    busybox="${static_root}/bin/busybox"
  fi
  file -L "$busybox" | rg -q "statically linked" \
    || die "Linux initramfs BusyBox must be statically linked: ${busybox}"

  cp "$busybox" "$staging_root/bin/busybox"
  ln -sfn busybox "$staging_root/bin/sh"

  local init_name init_src output
  for init_name in 1 2; do
    init_src="${AXVISOR_ROOT}/guests/linux-net/init-linux-${init_name}"
    output="${IMAGE_ROOT}/linux-net-${init_name}-initramfs.cpio"
    [ -f "$init_src" ] || die "missing Linux guest init script: ${init_src}"
    cp "$init_src" "$staging_root/init"
    chmod 0755 "$staging_root/init" "$staging_root/bin/busybox"
    (cd "$staging_root" && find . -print0 | cpio --null --quiet -o -H newc > "$output") \
      || die "unable to build Linux guest initramfs: ${output}"
    printf '%s\n' "$output"
  done
}

patch_vm_config() {
  local template="$1"
  local output="$2"
  local kernel="$3"
  local entry_point="${4:-}"
  local ramdisk="${5:-}"
  local ramdisk_load_addr="${6:-}"
  local phys_cpu="${7:-}"
  local host_timer_policy="${8:-}"
  local host_vcpu_yield="${9:-}"
  local host_vcpu_idle_policy="${10:-}"
  mkdir -p "$(dirname "$output")"
  local -a sed_args=(
    -e 's|^image_location =.*|image_location = "memory"|' \
    -e "s|^kernel_path =.*|kernel_path = \"${kernel}\"|"
  )
  if [ -n "$entry_point" ]; then
    sed_args+=("-e" "s|^entry_point =.*|entry_point = ${entry_point}|")
  fi
  if [ -n "$ramdisk" ]; then
    sed_args+=("-e" "s|^ramdisk_path =.*|ramdisk_path = \"${ramdisk}\"|")
  fi
  if [ -n "$ramdisk_load_addr" ]; then
    sed_args+=("-e" "s|^ramdisk_load_addr =.*|ramdisk_load_addr = ${ramdisk_load_addr}|")
  fi
  if [ -n "$phys_cpu" ]; then
    sed_args+=(
      "-e" "s|^phys_cpu_ids =.*|phys_cpu_ids = [${phys_cpu}]|"
      "-e" "s|^  \[\"gppt-gicr\", 0x080a_0000, 0x2_0000, 0, 0x20, \[1, 0x2_0000, [0-9][0-9]*\]\]|  [\"gppt-gicr\", 0x080a_0000, 0x2_0000, 0, 0x20, [1, 0x2_0000, ${phys_cpu}]]|"
    )
  fi
  if [ -n "$host_timer_policy" ]; then
    sed_args+=("-e" "s|^host_timer_policy =.*|host_timer_policy = \"${host_timer_policy}\"|")
  fi
  if [ -n "$host_vcpu_yield" ]; then
    sed_args+=("-e" "s|^host_vcpu_yield =.*|host_vcpu_yield = ${host_vcpu_yield}|")
  fi
  if [ -n "$host_vcpu_idle_policy" ]; then
    sed_args+=("-e" "s|^host_vcpu_idle_policy =.*|host_vcpu_idle_policy = \"${host_vcpu_idle_policy}\"|")
  fi
  sed "${sed_args[@]}" "$template" > "$output"
}

linux_kernel="$(prepare_linux_kernel)"
prepare_rtos_kernel
rtos_kernel="$PREPARED_RTOS_KERNEL"
prepare_rootfs >/dev/null
mapfile -t linux_initramfs < <(prepare_linux_initramfs)
[ "${#linux_initramfs[@]}" -eq 2 ] || die "expected two Linux initramfs images"

patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/linux-net-1.toml" \
  "${GENERATED_ROOT}/linux-net-1.toml" \
  "$linux_kernel" \
  "" \
  "${linux_initramfs[0]}" \
  "0x8c00_0000"
patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/linux-net-2.toml" \
  "${GENERATED_ROOT}/linux-net-2.toml" \
  "$linux_kernel" \
  "" \
  "${linux_initramfs[1]}" \
  "0x9c00_0000"
patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/zephyr-net.toml" \
  "${GENERATED_ROOT}/zephyr-net.toml" \
  "$rtos_kernel" \
  "${RTOS_ENTRY_POINT:-${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-}}" \
  "" \
  "" \
  "$RTOS_PCPU" \
  "$HOST_TIMER_POLICY" \
  "$HOST_VCPU_YIELD" \
  "$HOST_VCPU_IDLE_POLICY"

bash "${SCRIPT_DIR}/verify_three_guest_net.sh"

cat <<EOF

[three-guest-net] prepared successfully
  Linux kernel: ${linux_kernel}
  RTOS kernel:  ${rtos_kernel}
  RTOS entry:   ${RTOS_ENTRY_POINT:-${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-template}}
  RTOS pCPU:    ${RTOS_PCPU}
  Host timer:  ${HOST_TIMER_POLICY}
  vCPU yield:  ${HOST_VCPU_YIELD}
  vCPU idle:   ${HOST_VCPU_IDLE_POLICY}
  Rootfs:       ${ROOTFS_TARGET}
  VM configs:   ${GENERATED_ROOT}

Run:
  cd ${REPO_ROOT}
  cargo xtask axvisor qemu \\
    --config os/axvisor/configs/board/qemu-aarch64.toml \\
    --qemu-config os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml \\
    --rootfs ${ROOTFS_TARGET} \\
    --vmconfigs ${GENERATED_ROOT}/linux-net-1.toml \\
    --vmconfigs ${GENERATED_ROOT}/linux-net-2.toml \\
    --vmconfigs ${GENERATED_ROOT}/zephyr-net.toml

Guest network:
  Linux-1: 192.168.77.11/24, MAC 52:54:00:77:00:01
  Linux-2: 192.168.77.12/24, MAC 52:54:00:77:00:02
  Zephyr:  192.168.77.13/24, MAC 52:54:00:77:00:03
EOF
