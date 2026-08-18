#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CARGO_TOML="$ROOT/os/axvisor/Cargo.toml"
GIC_DISPATCH="$ROOT/virtualization/axvm/src/arch/aarch64/gic.rs"
AARCH64_RUNTIME="$ROOT/virtualization/axvm/src/arch/aarch64/mod.rs"
VCPU_RUNTIME="$ROOT/virtualization/axvm/src/runtime/vcpus.rs"
AXVM_VM="$ROOT/virtualization/axvm/src/vm/mod.rs"
AXVISOR_CONFIG="$ROOT/os/axvisor/src/config.rs"
TWO_GUEST_BOARD="$ROOT/os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml"
LINUX_VM_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml"
RTTHREAD_VM_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"

require_feature() {
    local feature="$1"
    rg -q --fixed-strings "  \"$feature\"," "$CARGO_TOML" || {
        echo "missing ax-std host realtime feature: $feature" >&2
        exit 1
    }
}

# Network ingress wakeups must be able to kick a remote vCPU and the host
# scheduler must be preemptive enough to run that woken task immediately.
require_feature "ipi"
require_feature "sched-rr"

rg -q --fixed-strings "ax_std::os::arceos::sync::IrqSaveGuard" "$GIC_DISPATCH" || {
    echo "missing acknowledged host IRQ local IRQ guard" >&2
    exit 1
}
rg -q --fixed-strings "ax_std::os::arceos::sync::PreemptGuard" "$GIC_DISPATCH" || {
    echo "missing acknowledged host IRQ preemption guard" >&2
    exit 1
}
if sed -n '/pub(crate) fn vcpu_on(/,/^pub(crate) fn spawn_registered_vcpu_task/p' "$VCPU_RUNTIME" |
    rg -q --fixed-strings "runtime.wait_until"; then
    echo "CPU_ON path still sleeps while the vCPU run guard is held" >&2
    exit 1
fi

rg -q --fixed-strings \
    "host_vcpu_idle_policy: cfg.base.host_vcpu_idle_policy" \
    "$AXVISOR_CONFIG" || {
    echo "guest host_vcpu_idle_policy is not propagated into AxVMConfig" >&2
    exit 1
}

wfi_branch="$(sed -n '/ArmVmExit::WaitForInterrupt =>/,/ArmVmExit::CpuDown/p' "$AARCH64_RUNTIME")"
rg -q --fixed-strings 'aarch64_guest_wfi_action(' <<<"$wfi_branch" || {
    echo "AArch64 WFI exit does not apply the VM host idle policy" >&2
    exit 1
}
rg -q --fixed-strings 'vm.host_vcpu_idle_policy()' <<<"$wfi_branch" || {
    echo "AArch64 WFI exit does not read the VM host idle policy" >&2
    exit 1
}
rg -q --fixed-strings \
    'HostVcpuIdlePolicy::Busy => Ok(BoundVcpuExit::Continue)' \
    <<<"$wfi_branch" || {
    echo "AArch64 busy WFI still leaves the current vCPU run slice" >&2
    exit 1
}
sed -n '/fn host_vcpu_idle_policy(/,/^    }/p' "$AXVM_VM" |
    rg -q --fixed-strings 'self.host_vcpu_idle_policy' || {
    echo "VM host_vcpu_idle_policy getter is not lock-free" >&2
    exit 1
}
rg -q '^cpu_num = 1$' "$RTTHREAD_VM_CONFIG" || {
    echo "RT-Thread real-time VM must have exactly one vCPU" >&2
    exit 1
}
rg -q '^phys_cpu_sets = \[4\]$' "$RTTHREAD_VM_CONFIG" || {
    echo "RT-Thread real-time vCPU must remain pinned to pCPU2" >&2
    exit 1
}
rg -q '^host_vcpu_idle_policy = "busy"$' "$RTTHREAD_VM_CONFIG" || {
    echo "RT-Thread VM must select busy WFI on its dedicated pCPU" >&2
    exit 1
}
if rg -q '^host_vcpu_idle_policy[[:space:]]*=' "$LINUX_VM_CONFIG"; then
    echo "Linux VM must retain the default halt host vCPU idle policy" >&2
    exit 1
fi
rg -q '^cpu_num = 2$' "$LINUX_VM_CONFIG" || {
    echo "Linux VM must expose exactly two vCPUs" >&2
    exit 1
}
rg -q '^phys_cpu_sets = \[0b11, 0b11\]$' "$LINUX_VM_CONFIG" || {
    echo "both Linux vCPUs must remain bounded to pCPU0/1" >&2
    exit 1
}
rg -q '^guest_tlbi_policy = "vm_scoped"$' "$LINUX_VM_CONFIG" || {
    echo "Linux VM must use VM-scoped TLBI on pCPU0/1" >&2
    exit 1
}
if rg -q '^guest_tlbi_policy[[:space:]]*=' "$RTTHREAD_VM_CONFIG"; then
    echo "RT-Thread must retain native TLBI behavior on pCPU2" >&2
    exit 1
fi

rg -q '^log = "Info"$' "$TWO_GUEST_BOARD" || {
    echo "two-guest real-time runs must compile out debug-level hot-path logging" >&2
    exit 1
}

echo "PASS: Axvisor host realtime scheduler contract"
