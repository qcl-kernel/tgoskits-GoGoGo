//! Architecture-neutral vCPU contexts and normalized runtime actions.

use axvm_types::{AccessWidth, GuestPhysAddr};

use crate::StopReason;

/// Scheduler effects selected after an architecture-local vCPU exit.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct VcpuRunAction {
    pub(crate) waits_for_event: bool,
    pub(crate) stop_reason: Option<StopReason>,
    pub(crate) resets_vm: bool,
    pub(crate) exits_vcpu: bool,
}

impl VcpuRunAction {
    /// Selects the host scheduler effect after a trapped guest WFI.
    #[cfg(any(target_arch = "aarch64", test))]
    pub(crate) const fn for_guest_wfi(policy: axvmconfig::HostVcpuIdlePolicy) -> Self {
        Self {
            waits_for_event: matches!(policy, axvmconfig::HostVcpuIdlePolicy::Halt),
            stop_reason: None,
            resets_vm: false,
            exits_vcpu: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use axvmconfig::HostVcpuIdlePolicy;

    use super::VcpuRunAction;

    #[test]
    fn guest_wfi_halts_by_default_but_busy_policy_keeps_running() {
        assert!(VcpuRunAction::for_guest_wfi(HostVcpuIdlePolicy::Halt).waits_for_event);
        assert!(!VcpuRunAction::for_guest_wfi(HostVcpuIdlePolicy::Busy).waits_for_event);
    }
}

/// Result of handling one exit while the vCPU is still bound to the host CPU.
#[derive(Debug)]
pub(crate) enum BoundVcpuExit<D> {
    /// The exit was handled completely; re-enter the guest in the current run slice.
    Continue,
    /// The run slice is complete and can return this scheduler action after unbind.
    Complete(VcpuRunAction),
    /// Finish architecture-local work after unbinding the vCPU.
    Defer(D),
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct MmioReadExit {
    pub(crate) addr: GuestPhysAddr,
    pub(crate) width: AccessWidth,
    pub(crate) reg: usize,
    pub(crate) reg_width: AccessWidth,
    pub(crate) signed_ext: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct MmioWriteExit {
    pub(crate) addr: GuestPhysAddr,
    pub(crate) width: AccessWidth,
    pub(crate) data: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct HypercallExit {
    pub(crate) nr: u64,
    pub(crate) args: [u64; 6],
}
