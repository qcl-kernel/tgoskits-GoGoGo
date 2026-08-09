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
    /// The vCPU has consumed its scheduling budget/timeslice and should be
    /// re-evaluated by the RT scheduler before re-entering the guest.
    pub(crate) budget_exhausted: bool,
    /// Guest CPU time consumed since the last scheduling point, in
    /// nanoseconds. The scheduler uses this to debit budgets.
    pub(crate) consumed_ns: u64,
}

impl VcpuRunAction {
    pub(crate) const fn nothing() -> Self {
        Self {
            waits_for_event: false,
            stop_reason: None,
            resets_vm: false,
            exits_vcpu: false,
            budget_exhausted: false,
            consumed_ns: 0,
        }
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
    /// The vCPU should yield because its scheduling budget is exhausted or a
    /// higher-priority vCPU is waiting. The run loop will perform a scheduler
    /// re-evaluation before re-entering the guest.
    YieldForScheduler { consumed_ns: u64 },
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
