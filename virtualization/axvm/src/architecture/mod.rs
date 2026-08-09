//! Architecture-neutral contracts shared by target implementations.

pub(crate) mod capabilities;
mod exit;
pub(crate) mod ops;
mod types;

pub(crate) use capabilities::{
    BootImagePlatform, GuestBootPlatform, HostTimePlatform, MachinePlatform,
    minimum_recorded_target_cpu_capability, unsupported_target_cpu_capability,
};
pub(crate) use exit::{handle_hypercall, handle_mmio_read, handle_mmio_write};
#[cfg(any(target_arch = "riscv64", target_arch = "loongarch64"))]
pub(crate) use exit::{try_handle_mmio_read, try_handle_mmio_write};
pub(crate) use ops::ArchOps;
pub(crate) use types::{BoundVcpuExit, HypercallExit, MmioReadExit, MmioWriteExit, VcpuRunAction};

// ---------------------------------------------------------------------------
// Per-CPU Preemption Flag
// ---------------------------------------------------------------------------

use core::sync::atomic::{AtomicBool, Ordering};

/// Per-CPU flag set by the host timer callback when a scheduler-preemption
/// tick has fired. Checked in [`ArchOps::before_vcpu_run`] so that
/// architectures without a native VM preemption timer can still force a
/// scheduling point.
#[ax_percpu::def_percpu]
pub(crate) static PREEMPTION_DUE: AtomicBool = AtomicBool::new(false);

/// Mark the current CPU as needing a scheduling evaluation.
pub(crate) fn signal_preemption_due() {
    // SAFETY: called from the timer IRQ context pinned to the local CPU.
    #[allow(static_mut_refs)]
    unsafe {
        PREEMPTION_DUE.current_ref_mut_raw().store(true, Ordering::Release);
    }
}

/// Test and clear the preemption-due flag for the current CPU.
pub(crate) fn take_preemption_due() -> bool {
    // SAFETY: called from the vCPU task pinned to the local CPU.
    #[allow(static_mut_refs)]
    unsafe {
        PREEMPTION_DUE
            .current_ref_mut_raw()
            .swap(false, Ordering::Acquire)
    }
}
