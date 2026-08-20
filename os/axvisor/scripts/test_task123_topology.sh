#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
LINUX_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml"
STARRYOS_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"
RTTHREAD_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"

cargo run -q -p axvmconfig -- check --config-path "$LINUX_CONFIG"
cargo run -q -p axvmconfig -- check --config-path "$STARRYOS_CONFIG"
cargo run -q -p axvmconfig -- check --config-path "$RTTHREAD_CONFIG"

python3 - "$LINUX_CONFIG" "$STARRYOS_CONFIG" "$RTTHREAD_CONFIG" <<'PY'
import sys
import tomllib
from pathlib import Path


def load(path: str) -> dict:
    with Path(path).open("rb") as config_file:
        return tomllib.load(config_file)


def require(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        raise SystemExit(f"FAIL: {label}: expected {expected!r}, got {actual!r}")


def virtual_net_mac(config: dict, label: str) -> list[int]:
    devices = config.get("devices", {}).get("virtual", [])
    net_devices = [device for device in devices if device.get("model") == "virtio-net"]
    require(len(net_devices), 1, f"{label} virtio-net device count")
    return net_devices[0].get("guest_mac")


linux = load(sys.argv[1])
starryos = load(sys.argv[2])
rtthread = load(sys.argv[3])

linux_base = linux["base"]
starryos_base = starryos["base"]
rtthread_base = rtthread["base"]

require(linux_base.get("cpu_num"), 2, "Linux vCPU count")
require(linux_base.get("phys_cpu_ids"), [0, 1], "Linux initial pCPU placement")
require(linux_base.get("phys_cpu_sets"), [0b1011, 0b1011], "Linux allowed pCPU masks")
require(linux_base.get("host_vcpu_idle_policy", "halt"), "halt", "Linux idle policy")
require(linux["kernel"].get("memory_regions"), [[0x80000000, 0x20000000, 0x7, 2]], "Linux RAM")
require(virtual_net_mac(linux, "Linux"), [0x52, 0x54, 0x00, 0x77, 0x00, 0x01], "Linux MAC")

require(starryos_base.get("cpu_num"), 2, "StarryOS vCPU count")
require(starryos_base.get("phys_cpu_ids"), [0, 1], "StarryOS initial pCPU placement")
require(starryos_base.get("phys_cpu_sets"), [0b1011, 0b1011], "StarryOS allowed pCPU masks")
require(starryos_base.get("host_vcpu_idle_policy", "halt"), "halt", "StarryOS idle policy")
require(
    starryos["kernel"].get("memory_regions"),
    [[0x80000000, 0x20000000, 0x7, 2]],
    "StarryOS RAM",
)
require(
    virtual_net_mac(starryos, "StarryOS"),
    [0x52, 0x54, 0x00, 0x77, 0x00, 0x01],
    "StarryOS MAC",
)

require(rtthread_base.get("cpu_num"), 1, "RT-Thread vCPU count")
require(rtthread_base.get("phys_cpu_ids"), [2], "RT-Thread initial pCPU placement")
require(rtthread_base.get("phys_cpu_sets"), [0b0100], "RT-Thread allowed pCPU mask")
require(rtthread_base.get("host_vcpu_idle_policy"), "busy", "RT-Thread idle policy")
require(
    rtthread["kernel"].get("memory_regions"),
    [[0x40000000, 0x40000000, 0x7, 0]],
    "RT-Thread RAM",
)
require(
    rtthread["kernel"].get("load_policy"),
    "keep_configured",
    "RT-Thread kernel load policy",
)
require(
    virtual_net_mac(rtthread, "RT-Thread"),
    [0x52, 0x54, 0x00, 0x77, 0x00, 0x03],
    "RT-Thread MAC",
)

rtthread_mask = rtthread_base["phys_cpu_sets"][0]
for index, linux_mask in enumerate(linux_base["phys_cpu_sets"]):
    if linux_mask & rtthread_mask:
        raise SystemExit(
            f"FAIL: Linux vCPU{index} mask {linux_mask:#06b} overlaps "
            f"RT-Thread mask {rtthread_mask:#06b}"
        )
PY

echo "PASS: Task 1/2/3 CPU, memory, and network topology"
