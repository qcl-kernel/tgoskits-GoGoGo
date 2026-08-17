#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)"
VM_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"
BUILD_CONFIG="$ROOT/os/StarryOS/configs/axvisor/task123-aarch64.toml"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$VM_CONFIG" ]] || fail "StarryOS AxVisor VM config is missing"
[[ -f "$BUILD_CONFIG" ]] || fail "StarryOS Task 1/2/3 build config is missing"

grep -Fxq 'guest_type = "virtualized"' "$VM_CONFIG" ||
    fail "StarryOS guest must use virtualized mode"
grep -Fxq 'cpu_num = 2' "$VM_CONFIG" ||
    fail "StarryOS guest must expose two vCPUs"
grep -Fq 'model = "virtio-net"' "$VM_CONFIG" ||
    fail "StarryOS guest must expose virtio-net"
grep -Fq 'starryos-task123' "$VM_CONFIG" ||
    fail "StarryOS VM config must identify the replacement guest"
! grep -Eq 'linux(-kernel|[-_])|linux-net|Image' "$VM_CONFIG" ||
    fail "StarryOS VM config must not reference the Linux guest"
grep -Fq 'axvisor-guest' "$BUILD_CONFIG" ||
    fail "StarryOS build config must enable the explicit AxVisor guest path"
grep -Fq 'aarch64-unknown-none-softfloat' "$BUILD_CONFIG" ||
    fail "StarryOS build target must be AArch64"

printf 'starryos task123 contract: PASS\n'
