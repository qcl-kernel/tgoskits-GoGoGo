#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXVISOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_ROOT="${AXVISOR_ROOT}/configs/vms/qemu/aarch64"
QEMU_CONFIG="${AXVISOR_ROOT}/configs/qemu/qemu-aarch64-three-guest-net.toml"

fail() {
  echo "[three-guest-net] ERROR: $*" >&2
  exit 1
}

require_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  rg -q --fixed-strings "$pattern" "$file" || fail "${description} (${file})"
}

validate_vm() {
  local file="$1"
  local id="$2"
  local ram_start="$3"
  local nic="$4"
  local pcpu="$5"

  [ -f "$file" ] || fail "missing VM config: ${file}"
  require_line "$file" "id = ${id}" "missing VM id ${id}"
  require_line "$file" "[${ram_start}, 0x1000_0000, 0x7, 2]" "VM ${id} must use identity-mapped guest RAM for passthrough DMA"
  require_line "$file" '["/intc@8000000"]' "VM ${id} must expose the QEMU GIC platform device"
  require_line "$file" "[\"/timer\"]" "VM ${id} must expose the virtual timer FDT node"
  require_line "$file" "[\"/psci\"]" "VM ${id} must expose the PSCI FDT node"
  require_line "$file" "[\"/pl011@9000000\"]" "VM ${id} must expose the QEMU console FDT node"
  require_line "$file" "[\"${nic}\"]" "VM ${id} must select its assigned virtio-mmio NIC"
  require_line "$file" '["gppt-gicd", 0x0800_0000, 0x1_0000, 0, 0x21, []]' "VM ${id} must use a GPPT GIC distributor"
  require_line "$file" "[\"gppt-gicr\", 0x080a_0000, 0x2_0000, 0, 0x20, [1, 0x2_0000, ${pcpu}]]" "VM ${id} must map its GIC redistributor to physical CPU ${pcpu}"

  local nic_count
  nic_count="$(rg -c 'virtio_mmio@' "$file")"
  [ "$nic_count" -eq 1 ] || fail "VM ${id} selects ${nic_count} virtio-mmio NICs; expected exactly one"
}

validate_vm "${VM_ROOT}/linux-net-1.toml" 1 0x8000_0000 /virtio_mmio@a000000 0
validate_vm "${VM_ROOT}/linux-net-2.toml" 2 0x9000_0000 /virtio_mmio@a000200 1
validate_vm "${VM_ROOT}/zephyr-net.toml" 3 0xa000_0000 /virtio_mmio@a000400 2
require_line "${VM_ROOT}/linux-net-1.toml" "ramdisk_load_addr = 0x8c00_0000" "Linux-1 must provide an initramfs load address"
require_line "${VM_ROOT}/linux-net-2.toml" "ramdisk_load_addr = 0x9c00_0000" "Linux-2 must provide an initramfs load address"

for linux_config in \
  "${VM_ROOT}/linux-net-1.toml" \
  "${VM_ROOT}/linux-net-2.toml"; do
  if rg -q --fixed-strings "host_vcpu_idle_policy" "$linux_config"; then
    fail "Linux VM config must not select a host vCPU idle policy (${linux_config})"
  fi
done

zephyr_idle_policy_count="$(rg -c '^host_vcpu_idle_policy = ' "${VM_ROOT}/zephyr-net.toml" || true)"
zephyr_idle_policy_count="${zephyr_idle_policy_count:-0}"
[ "$zephyr_idle_policy_count" -eq 1 ] \
  || fail "Zephyr VM config must contain exactly one host vCPU idle policy"
rg -q '^host_vcpu_idle_policy = "halt"$' "${VM_ROOT}/zephyr-net.toml" \
  || fail "Zephyr VM config must use exactly the safe halt host vCPU idle policy"

topology_inputs=(
  "${VM_ROOT}/linux-net-1.toml"
  "${VM_ROOT}/linux-net-2.toml"
  "${VM_ROOT}/zephyr-net.toml"
  "$QEMU_CONFIG"
)
forbidden_topology="$(
  rg -n -i \
    'ivc|shared[[:space:]_-]*mem(ory)?|shmem|virtio[[:space:]_-]*vsock|vhost[[:space:]_-]*vsock' \
    "${topology_inputs[@]}" || true
)"
[ -z "$forbidden_topology" ] || fail "topology must remain virtio-net only: ${forbidden_topology}"

ZEPHYR_APP="${AXVISOR_ROOT}/guests/zephyr-net"
require_line "${ZEPHYR_APP}/prj.conf" "CONFIG_NET_CONFIG_AUTO_INIT=n" "Zephyr must configure networking from main"
require_line "${ZEPHYR_APP}/prj.conf" "CONFIG_ETH_NET_IF_NO_AUTO_START=y" "Zephyr must defer Ethernet interface startup to main"
require_line "${ZEPHYR_APP}/prj.conf" "CONFIG_NET_IPV6=n" "Zephyr network guest only needs IPv4"
require_line "${ZEPHYR_APP}/prj.conf" "CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000" "Zephyr network guest benchmark requires 10 kHz system ticks"
require_line "${ZEPHYR_APP}/prj.conf" "CONFIG_ARMV8_A_NS=y" "Zephyr must configure GIC SGI/PPI for EL1 Non-secure"
require_line "${ZEPHYR_APP}/src/main.c" "net_addr_pton(NET_AF_INET, \"192.168.77.13\"" "Zephyr must parse its static IPv4 address"
require_line "${ZEPHYR_APP}/src/main.c" "net_if_ipv4_addr_add(iface" "Zephyr must add its static IPv4 address"
require_line "${ZEPHYR_APP}/src/main.c" "net_if_ipv4_set_netmask_by_addr(iface" "Zephyr must set its IPv4 netmask"
require_line "${ZEPHYR_APP}/src/main.c" "net_if_up(iface)" "Zephyr must bring its network interface up"
require_line "${ZEPHYR_APP}/src/main.c" "arm_gic_irq_set_priority" "Zephyr must override the virtio-mmio IRQ trigger type"
require_line "${ZEPHYR_APP}/src/main.c" "IRQ_TYPE_EDGE" "Zephyr must configure the QEMU virtio SPI as edge-triggered"
require_line "${ZEPHYR_APP}/src/main.c" "VIRTIO_MMIO_INTERRUPT_STATUS" "Zephyr polling fallback must read virtio interrupt status"
require_line "${ZEPHYR_APP}/src/main.c" "VIRTIO_MMIO_INTERRUPT_ACK" "Zephyr polling fallback must acknowledge virtio interrupts"
require_line "${ZEPHYR_APP}/src/main.c" "virtio_isr" "Zephyr polling fallback must use the virtio common ISR"
require_line "${ZEPHYR_APP}/src/main.c" "RTBENCH network_start" "Zephyr network guest must start the timer benchmark"
require_line "${ZEPHYR_APP}/src/main.c" "RTBENCH network samples=" "Zephyr network guest must report timer samples"
require_line "${ZEPHYR_APP}/virtnet.overlay" "interrupts = <GIC_SPI 18 IRQ_TYPE_EDGE IRQ_DEFAULT_PRIORITY>;" "Zephyr virtio-net IRQ must match QEMU's edge-triggered SPI"
require_line "${AXVISOR_ROOT}/guests/linux-net/init-linux-1" "ping -c 1 -W 2 192.168.77.13" "Linux-1 must verify IPv4 connectivity to Zephyr"
require_line "${AXVISOR_ROOT}/guests/linux-net/init-linux-2" "ping -c 1 -W 2 192.168.77.13" "Linux-2 must verify IPv4 connectivity to Zephyr"
require_line "${AXVISOR_ROOT}/guests/linux-net/init-linux-1" "wget -q -O - http://192.168.77.12:8080/" "Linux-1 must verify TCP connectivity to Linux-2"

[ -f "$QEMU_CONFIG" ] || fail "missing QEMU config: ${QEMU_CONFIG}"
for net in \
  'hubport,id=net0,hubid=77' \
  'hubport,id=net1,hubid=77' \
  'hubport,id=net2,hubid=77' \
  'virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01' \
  'virtio-net-device,netdev=net1,bus=virtio-mmio-bus.1,mac=52:54:00:77:00:02' \
  'virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03'; do
  require_line "$QEMU_CONFIG" "$net" "QEMU network topology is missing ${net}"
done

if [ "$#" -gt 1 ]; then
  fail "usage: $0 [qemu-host.dtb]"
fi

if [ "$#" -eq 1 ]; then
  command -v dtc >/dev/null 2>&1 || fail "dtc is required for DTB validation"
  dtb="$1"
  [ -f "$dtb" ] || fail "DTB does not exist: ${dtb}"
  dts="$(mktemp /tmp/axvisor-three-guest-net.XXXXXX.dts)"
  trap 'rm -f "$dts"' EXIT
  dtc -I dtb -O dts "$dtb" -o "$dts"

  check_node() {
    local node="$1"
    local reg="$2"
    local irq="$3"
    local block
    block="$(awk -v node="$node" '
      $0 ~ "^[[:space:]]*" node " \\{" { found = 1 }
      found { print }
      found && /^[[:space:]]*};/ { exit }
    ' "$dts")"
    [ -n "$block" ] || fail "DTB is missing ${node}"
    printf '%s\n' "$block" | rg -q --fixed-strings "reg = <0x00 ${reg} 0x00 0x200>;" \
      || fail "${node} has an unexpected MMIO range"
    printf '%s\n' "$block" | rg -q --fixed-strings "interrupts = <0x00 ${irq} 0x01>;" \
      || fail "${node} has an unexpected IRQ"
  }

  check_node virtio_mmio@a000000 0xa000000 0x10
  check_node virtio_mmio@a000200 0xa000200 0x11
  check_node virtio_mmio@a000400 0xa000400 0x12
fi

echo "[three-guest-net] static configuration checks passed"
