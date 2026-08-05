#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
DOC="$SCRIPT_DIR/real-arm-board-run.md"
REPORT="$SCRIPT_DIR/rtos-realtime-report.md"

usage() {
    printf 'usage: %s [--realtime-preflight <board>]\n' "${0##*/}" >&2
}

realtime_preflight=false
realtime_board=""
case "$#" in
    0)
        ;;
    2)
        if [[ "$1" != "--realtime-preflight" ]]; then
            usage
            exit 2
        fi
        realtime_preflight=true
        realtime_board="$2"
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ "$realtime_preflight" == true ]]; then
    case "$realtime_board" in
        orangepi-5-plus | phytiumpi | evm3588)
            ;;
        *)
            printf 'FAIL unsupported realtime preflight board: %s\n' "$realtime_board" >&2
            exit 1
            ;;
    esac
fi

cd "$REPO_ROOT"

require_file() {
    if [[ ! -f "$1" ]]; then
        printf 'FAIL missing file: %s\n' "$1" >&2
        exit 1
    fi
}

require_text() {
    local needle="$1"
    local file="$2"
    if ! rg -qF -- "$needle" "$file"; then
        printf 'FAIL missing text %s in %s\n' "$needle" "$file" >&2
        exit 1
    fi
}

require_file "$DOC"
require_file "$REPORT"
require_file os/axvisor/configs/board/orangepi-5-plus.toml
require_file os/axvisor/configs/board/orangepi-5-plus.dtb
require_file os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.toml
require_file os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.dts
require_file os/axvisor/configs/vms/orangepi-5-plus/zephyr.toml
require_file os/axvisor/configs/vms/orangepi-5-plus/freertos-smp1.toml
require_file os/axvisor/configs/board/phytiumpi.toml
require_file os/axvisor/configs/vms/phytiumpi/linux-smp1.toml
require_file os/axvisor/configs/vms/phytiumpi/linux-smp1.dts
require_file os/axvisor/configs/vms/phytiumpi/zephyr-smp1.toml
require_file os/axvisor/configs/vms/phytiumpi/zephyr-smp1.dts
require_file os/axvisor/configs/vms/rk3588/linux-smp8.toml
require_file os/axvisor/configs/vms/rk3588/linux-smp8.dts
require_file os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml

require_text 'vm_configs = ["os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.toml"]' \
    test-suit/axvisor/normal/board-orangepi-5-plus/build-aarch64-unknown-none-softfloat.toml
require_text 'vm_configs = ["os/axvisor/configs/vms/phytiumpi/linux-smp1.toml"]' \
    test-suit/axvisor/normal/board-phytiumpi/build-aarch64-unknown-none-softfloat.toml

for vm in \
    os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.toml \
    os/axvisor/configs/vms/orangepi-5-plus/zephyr.toml \
    os/axvisor/configs/vms/orangepi-5-plus/freertos-smp1.toml \
    os/axvisor/configs/vms/phytiumpi/linux-smp1.toml \
    os/axvisor/configs/vms/phytiumpi/zephyr-smp1.toml; do
    require_text 'passthrough_devices = [' "$vm"
    require_text '["/"]' "$vm"
    if rg -qi 'virtio[-_]net|virtio[-_]mmio' "$vm"; then
        printf 'FAIL physical-board VM unexpectedly declares virtio network: %s\n' "$vm" >&2
        exit 1
    fi
done

require_text '/ethernet@fe1b0000' os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.dts
require_text '/ethernet@fe1c0000' os/axvisor/configs/vms/orangepi-5-plus/linux-smp1.dts
require_text '/soc/ethernet@3200c000' os/axvisor/configs/vms/phytiumpi/linux-smp1.dts
require_text '0x20 0x40000000 0x00 0x40000000' os/axvisor/configs/vms/phytiumpi/linux-smp1.dts
require_text 'model = "Firefly ITX-3588J HDMI(Linux)"' os/axvisor/configs/vms/rk3588/linux-smp8.dts
require_text 'kernel_path = "/path/to/kernel"' os/axvisor/configs/vms/rk3588/linux-smp8.toml

if rg -qi 'evm3588' os/axvisor/configs test-suit/axvisor; then
    printf 'FAIL unexpected EVM3588 config/test asset found\n' >&2
    exit 1
fi

virtio_count="$(rg -c 'virtio-net-device' os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml)"
if [[ "$virtio_count" != 3 ]]; then
    printf 'FAIL expected 3 QEMU virtio-net devices, found %s\n' "$virtio_count" >&2
    exit 1
fi
for bus in virtio-mmio-bus.0 virtio-mmio-bus.1 virtio-mmio-bus.2; do
    require_text "$bus" os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml
done

for phrase in \
    '当前仓库不能在 Orange Pi 5 Plus、Phytium Pi 或所谓 EVM3588 上直接运行' \
    'BOARD_DTB' \
    'virtio-net' \
    '0x240000000' \
    '0x2040000000' \
    'Firefly ITX-3588J' \
    'QEMU 对照命令（不是实体板命令）'; do
    require_text "$phrase" "$DOC"
done

maximum_allowance='Axvisor maximum <= bare-metal maximum + max(2 x bare-metal maximum, 50 us)'
require_text "$maximum_allowance" "$DOC"
require_text "$maximum_allowance" "$REPORT"

if [[ "$realtime_preflight" == true ]]; then
    missing_realtime_asset=false

    for name in \
        AXVISOR_RT_BOARD_DTB \
        AXVISOR_RT_LINUX1_IMAGE \
        AXVISOR_RT_LINUX2_IMAGE \
        AXVISOR_RT_ZEPHYR_IMAGE \
        AXVISOR_RT_LINUX1_VM_CONFIG \
        AXVISOR_RT_LINUX2_VM_CONFIG \
        AXVISOR_RT_ZEPHYR_VM_CONFIG; do
        if [[ -z "${!name:-}" || ! -f "${!name}" ]]; then
            printf 'FAIL missing realtime input: %s\n' "$name" >&2
            missing_realtime_asset=true
        fi
    done

    for name in AXVISOR_RT_POWER_RESET AXVISOR_RT_SERIAL_CAPTURE; do
        if [[ -z "${!name:-}" || ! -f "${!name}" || ! -x "${!name}" ]]; then
            printf 'FAIL missing realtime input: %s\n' "$name" >&2
            missing_realtime_asset=true
        fi
    done

    for name in \
        AXVISOR_RT_NET0_DEVICE \
        AXVISOR_RT_NET1_DEVICE \
        AXVISOR_RT_NET2_DEVICE \
        AXVISOR_RT_NET0_IRQ \
        AXVISOR_RT_NET1_IRQ \
        AXVISOR_RT_NET2_IRQ \
        AXVISOR_RT_TRAFFIC_PEER; do
        if [[ -z "${!name:-}" ]]; then
            printf 'FAIL missing realtime input: %s\n' "$name" >&2
            missing_realtime_asset=true
        fi
    done

    if [[ "$missing_realtime_asset" == true ]]; then
        exit 1
    fi

    realtime_asset_invalid=false
    if [[ "$AXVISOR_RT_LINUX1_VM_CONFIG" == "$AXVISOR_RT_LINUX2_VM_CONFIG" ||
          "$AXVISOR_RT_LINUX1_VM_CONFIG" == "$AXVISOR_RT_ZEPHYR_VM_CONFIG" ||
          "$AXVISOR_RT_LINUX2_VM_CONFIG" == "$AXVISOR_RT_ZEPHYR_VM_CONFIG" ]]; then
        printf 'FAIL realtime VM config paths must be unique\n' >&2
        realtime_asset_invalid=true
    fi
    if [[ "$AXVISOR_RT_NET0_DEVICE" == "$AXVISOR_RT_NET1_DEVICE" ||
          "$AXVISOR_RT_NET0_DEVICE" == "$AXVISOR_RT_NET2_DEVICE" ||
          "$AXVISOR_RT_NET1_DEVICE" == "$AXVISOR_RT_NET2_DEVICE" ]]; then
        printf 'FAIL realtime network devices must be unique\n' >&2
        realtime_asset_invalid=true
    fi
    if [[ "$AXVISOR_RT_NET0_IRQ" == "$AXVISOR_RT_NET1_IRQ" ||
          "$AXVISOR_RT_NET0_IRQ" == "$AXVISOR_RT_NET2_IRQ" ||
          "$AXVISOR_RT_NET1_IRQ" == "$AXVISOR_RT_NET2_IRQ" ]]; then
        printf 'FAIL realtime network IRQs must be unique\n' >&2
        realtime_asset_invalid=true
    fi

    if ! python3 - \
        "$AXVISOR_RT_LINUX1_VM_CONFIG" \
        "$AXVISOR_RT_LINUX2_VM_CONFIG" \
        "$AXVISOR_RT_ZEPHYR_VM_CONFIG" <<'PY'
import sys
import tomllib

configs = []
failed = False
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as file:
            document = tomllib.load(file)
    except (OSError, tomllib.TOMLDecodeError) as error:
        print(f"FAIL invalid realtime VM config TOML {path}: {error}", file=sys.stderr)
        failed = True
        continue

    base = document.get("base")
    if not isinstance(base, dict):
        print(f"FAIL missing base table in realtime VM config: {path}", file=sys.stderr)
        failed = True
        continue

    vm_id = base.get("id")
    if vm_id is None:
        print(f"FAIL missing base.id in realtime VM config: {path}", file=sys.stderr)
        failed = True
    elif type(vm_id) is not int or vm_id < 0:
        print(f"FAIL base.id must be a non-negative integer in realtime VM config: {path}", file=sys.stderr)
        failed = True
        vm_id = None

    phys_cpu_ids = base.get("phys_cpu_ids")
    if not isinstance(phys_cpu_ids, list) or not phys_cpu_ids:
        print(
            f"FAIL base.phys_cpu_ids must be explicit and non-empty in realtime VM config: {path}",
            file=sys.stderr,
        )
        failed = True
        phys_cpu_ids = None
    elif any(type(cpu_id) is not int or cpu_id < 0 for cpu_id in phys_cpu_ids):
        print(f"FAIL base.phys_cpu_ids must contain non-negative integers in realtime VM config: {path}", file=sys.stderr)
        failed = True
        phys_cpu_ids = None

    configs.append((path, vm_id, phys_cpu_ids))

for index, (left_path, left_id, left_cpus) in enumerate(configs):
    for right_path, right_id, right_cpus in configs[index + 1:]:
        if left_id is not None and right_id is not None and left_id == right_id:
            print(
                f"FAIL duplicate realtime VM base.id {left_id!r}: {left_path} and {right_path}",
                file=sys.stderr,
            )
            failed = True
        if left_cpus is not None and right_cpus is not None:
            overlap = sorted(set(left_cpus) & set(right_cpus))
            if overlap:
                overlap_text = ",".join(str(cpu_id) for cpu_id in overlap)
                print(
                    f"FAIL overlapping realtime VM base.phys_cpu_ids ({overlap_text}): "
                    f"{left_path} and {right_path}",
                    file=sys.stderr,
                )
                failed = True

raise SystemExit(1 if failed else 0)
PY
    then
        realtime_asset_invalid=true
    fi

    if [[ "$realtime_asset_invalid" == true ]]; then
        exit 1
    fi
fi

printf 'PASS real ARM board documentation contract\n'
printf 'PASS Orange Pi and Phytium single-Linux assets checked\n'
printf 'PASS EVM3588 config/test absence checked\n'
printf 'PASS QEMU three-virtio-net comparison checked\n'
if [[ "$realtime_preflight" == true ]]; then
    printf 'PASS realtime physical asset preflight: %s\n' "$realtime_board"
fi
