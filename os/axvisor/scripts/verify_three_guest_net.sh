#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXVISOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_ROOT="${AXVISOR_THREE_GUEST_VERIFY_VM_ROOT:-${AXVISOR_ROOT}/configs/vms/qemu/aarch64}"
QEMU_CONFIG="${AXVISOR_THREE_GUEST_VERIFY_QEMU_CONFIG:-${AXVISOR_ROOT}/configs/qemu/qemu-aarch64-three-guest-net.toml}"
BOARD_CONFIG="${AXVISOR_THREE_GUEST_VERIFY_BOARD_CONFIG:-${AXVISOR_ROOT}/configs/board/qemu-aarch64-three-guest-net.toml}"
EXPECTED_IDLE_POLICY="${AXVISOR_THREE_GUEST_VERIFY_EXPECTED_IDLE_POLICY:-halt}"
TOPOLOGY_ONLY="${AXVISOR_THREE_GUEST_VERIFY_TOPOLOGY_ONLY:-0}"

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

case "$EXPECTED_IDLE_POLICY" in
  halt|busy) ;;
  *) fail "expected Zephyr host vCPU idle policy must be halt or busy" ;;
esac
case "$TOPOLOGY_ONLY" in
  0|1) ;;
  *) fail "AXVISOR_THREE_GUEST_VERIFY_TOPOLOGY_ONLY must be 0 or 1" ;;
esac

command -v python3 >/dev/null 2>&1 \
  || fail "python3 with tomllib is required for structured topology validation"
python3 -c 'import tomllib' >/dev/null 2>&1 \
  || fail "python3 tomllib is required for structured topology validation"

python3 - "$BOARD_CONFIG" "$VM_ROOT" "$QEMU_CONFIG" "$EXPECTED_IDLE_POLICY" <<'PY'
import pathlib
import re
import sys
import tomllib


class ConfigError(Exception):
    pass


def report_exception(exception_type, exception, traceback):
    if issubclass(exception_type, (ConfigError, OSError)):
        print(f"[three-guest-net] ERROR: {exception}", file=sys.stderr)
        return
    sys.__excepthook__(exception_type, exception, traceback)


sys.excepthook = report_exception


def load(path):
    if not path.is_file():
        raise ConfigError(f"missing topology config: {path}")
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML in {path}: {exc}") from exc


def table(document, name, path):
    value = document.get(name)
    if not isinstance(value, dict):
        raise ConfigError(f"missing [{name}] table in {path}")
    return value


def walk_live(value, path=""):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else str(key)
            yield child_path, str(key)
            yield from walk_live(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_live(child, f"{path}[{index}]")
    elif isinstance(value, str):
        yield path, value


def count_key(value, expected):
    if isinstance(value, dict):
        return sum(key == expected for key in value) + sum(
            count_key(child, expected) for child in value.values()
        )
    if isinstance(value, list):
        return sum(count_key(child, expected) for child in value)
    return 0


def require(condition, message):
    if not condition:
        raise ConfigError(message)


reservation_feature = "qemu-aarch64-three-guest-net"
board_path = pathlib.Path(sys.argv[1])
vm_root = pathlib.Path(sys.argv[2])
qemu_path = pathlib.Path(sys.argv[3])
expected_idle_policy = sys.argv[4]
specifications = (
    ("linux-net-1.toml", 1, 0x80000000, "/virtio_mmio@a000000", 0),
    ("linux-net-2.toml", 2, 0x90000000, "/virtio_mmio@a000200", 1),
    ("zephyr-net.toml", 3, 0xA0000000, "/virtio_mmio@a000400", 2),
)
documents = {}

board = load(board_path)
board_features = board.get("features")
require(
    isinstance(board_features, list)
    and all(isinstance(feature, str) for feature in board_features),
    f"board features must be an array of strings ({board_path})",
)
qualified_reservation_features = [
    feature
    for feature in board_features
    if feature != reservation_feature
    and feature.rsplit("/", 1)[-1] == reservation_feature
]
require(
    not qualified_reservation_features,
    f"board must not use dependency-qualified {reservation_feature} features: "
    f"{qualified_reservation_features} ({board_path})",
)
require(
    board_features.count(reservation_feature) == 1,
    f"board must contain the bare {reservation_feature} feature exactly once ({board_path})",
)

for filename, vm_id, ram_start, nic, pcpu in specifications:
    path = vm_root / filename
    document = load(path)
    documents[filename] = document
    base = table(document, "base", path)
    kernel = table(document, "kernel", path)
    devices = table(document, "devices", path)
    require(base.get("id") == vm_id, f"VM {vm_id} has an unexpected or missing live id ({path})")
    require(base.get("phys_cpu_ids") == [pcpu], f"VM {vm_id} must run on physical CPU {pcpu} ({path})")
    required_ram = [ram_start, 0x10000000, 0x7, 2]
    require(required_ram in kernel.get("memory_regions", []), f"VM {vm_id} must use identity-mapped guest RAM for passthrough DMA ({path})")

    passthrough = devices.get("passthrough_devices")
    require(isinstance(passthrough, list), f"VM {vm_id} has no passthrough device list ({path})")
    live_devices = [row[0] for row in passthrough if isinstance(row, list) and len(row) == 1 and isinstance(row[0], str)]
    for required_device in ("/intc@8000000", "/timer", "/psci", "/pl011@9000000", nic):
        require(live_devices.count(required_device) == 1, f"VM {vm_id} must expose exactly one {required_device} ({path})")
    nic_devices = [device for device in live_devices if device.startswith("/virtio_mmio@")]
    require(nic_devices == [nic], f"VM {vm_id} must select exactly its assigned virtio-net MMIO device ({path})")

    emulated = devices.get("emu_devices")
    require(isinstance(emulated, list), f"VM {vm_id} has no emulated device list ({path})")
    gicd = ["gppt-gicd", 0x08000000, 0x10000, 0, 0x21, []]
    gicr = ["gppt-gicr", 0x080A0000, 0x20000, 0, 0x20, [1, 0x20000, pcpu]]
    require(emulated.count(gicd) == 1, f"VM {vm_id} must use exactly one GPPT GIC distributor ({path})")
    require(emulated.count(gicr) == 1, f"VM {vm_id} must map its GIC redistributor to physical CPU {pcpu} ({path})")

linux_1 = documents["linux-net-1.toml"]
linux_2 = documents["linux-net-2.toml"]
for filename, document, load_address in (
    ("linux-net-1.toml", linux_1, 0x8C000000),
    ("linux-net-2.toml", linux_2, 0x9C000000),
):
    require(document["kernel"].get("ramdisk_load_addr") == load_address, f"{filename} has an unexpected initramfs load address")
    require(count_key(document, "host_vcpu_idle_policy") == 0, f"Linux VM config must not select a host vCPU idle policy ({vm_root / filename})")

zephyr = documents["zephyr-net.toml"]
require(count_key(zephyr, "host_vcpu_idle_policy") == 1, "Zephyr VM config must contain exactly one host vCPU idle policy")
require(zephyr["base"].get("host_vcpu_idle_policy") == expected_idle_policy, f"Zephyr VM config must use exactly host vCPU idle policy {expected_idle_policy!r}")

qemu = load(qemu_path)
qemu_args = qemu.get("args")
require(isinstance(qemu_args, list) and all(isinstance(arg, str) for arg in qemu_args), f"QEMU args must be an array of strings ({qemu_path})")
required_network = (
    "hubport,id=net0,hubid=77",
    "hubport,id=net1,hubid=77",
    "hubport,id=net2,hubid=77",
    "virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01",
    "virtio-net-device,netdev=net1,bus=virtio-mmio-bus.1,mac=52:54:00:77:00:02",
    "virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03",
)
for network_arg in required_network:
    require(qemu_args.count(network_arg) == 1, f"QEMU network topology must contain exactly one live {network_arg} ({qemu_path})")

def reject_forbidden(source_path, value, root_path):
    for value_path, live_value in walk_live(value, root_path):
        compact = re.sub(r"[^a-z0-9]+", "", live_value.lower())
        if "ivc" in compact or "sharedmem" in compact or "shmem" in compact or "vsock" in compact:
            raise ConfigError(f"topology must remain virtio-net only; forbidden live value at {source_path}:{value_path}: {live_value!r}")


for filename, document in documents.items():
    reject_forbidden(vm_root / filename, document["devices"], "devices")

qemu_topology_options = {"-device", "-object", "-chardev", "-netdev"}
for index, argument in enumerate(qemu_args):
    if argument in qemu_topology_options and index + 1 < len(qemu_args):
        reject_forbidden(qemu_path, qemu_args[index + 1], f"args[{index + 1}]")
    for option in qemu_topology_options:
        if argument.startswith(f"{option}="):
            reject_forbidden(qemu_path, argument, f"args[{index}]")

for field in ("device", "object", "chardev", "netdev"):
    if field in qemu:
        reject_forbidden(qemu_path, qemu[field], field)
PY

if [ "$TOPOLOGY_ONLY" = 1 ]; then
  echo "[three-guest-net] structured topology checks passed"
  exit 0
fi

command -v rg >/dev/null 2>&1 || fail "rg is required for source topology validation"

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
