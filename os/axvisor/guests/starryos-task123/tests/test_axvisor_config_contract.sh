#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../../../.." && pwd)"
BOARD="$ROOT/os/axvisor/configs/board/qemu-aarch64-starryos-task123.toml"
QEMU="$ROOT/os/axvisor/configs/qemu/qemu-aarch64-starryos-task123.toml"
STARRY_VM="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"
RTTHREAD_VM="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"

fail() {
    echo "starryos AxVisor config contract: $*" >&2
    exit 1
}

[[ -f "$BOARD" ]] || fail "board config is missing"
[[ -f "$QEMU" ]] || fail "QEMU config is missing"
[[ -f "$STARRY_VM" ]] || fail "StarryOS VM config is missing"
[[ -f "$RTTHREAD_VM" ]] || fail "RT-Thread VM config is missing"

grep -Fq 'starryos-task123.toml' "$BOARD" || fail "board config does not select StarryOS"
grep -Fq 'rtthread-net.toml' "$BOARD" || fail "board config does not select RT-Thread"
grep -Fxq 'cpu_num = 2' "$STARRY_VM" || fail "StarryOS must have two vCPUs"
grep -Fxq 'cpu_num = 1' "$RTTHREAD_VM" || fail "RT-Thread must have one vCPU"
grep -Fq 'model = "virtio-net"' "$STARRY_VM" || fail "StarryOS virtio-net is missing"
grep -Fq 'model = "virtio-net"' "$RTTHREAD_VM" || fail "RT-Thread virtio-net is missing"
grep -Fq 'virtio-net-device,netdev=net0' "$QEMU" || fail "QEMU net0 endpoint is missing"
grep -Fq 'virtio-net-device,netdev=net2' "$QEMU" || fail "QEMU net2 endpoint is missing"
! grep -Eq '(^|,)\s*(nvme|virtio-blk)' "$QEMU" || fail "QEMU config must not add a guest block data channel"

echo "starryos AxVisor config contract: PASS"
