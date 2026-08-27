//! VM-scoped AArch64 EL1 TLB invalidation.

#[cfg(target_arch = "aarch64")]
use core::arch::asm;

#[cfg(target_arch = "aarch64")]
use crate::{AxVM, AxVmError, AxVmResult};

/// Invalid VM-to-host CPU affinity for VM-scoped TLB maintenance.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum VmPcpuMaskError {
    /// The VM has no vCPUs.
    NoVcpus,
    /// A vCPU can migrate outside a bounded physical CPU set.
    MissingAffinity { vcpu_id: usize },
    /// A vCPU has an explicitly empty physical CPU set.
    EmptyAffinity { vcpu_id: usize },
}

/// Failure returned by one target CPU during a VM-scoped operation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct VmTlbiDispatchError<E> {
    pub(super) cpu_id: usize,
    pub(super) source: E,
}

pub(super) fn vm_pcpu_mask(
    placements: &[(usize, Option<usize>, usize)],
) -> Result<usize, VmPcpuMaskError> {
    if placements.is_empty() {
        return Err(VmPcpuMaskError::NoVcpus);
    }

    let mut vm_mask = 0usize;
    for &(vcpu_id, affinity, _) in placements {
        let affinity = affinity.ok_or(VmPcpuMaskError::MissingAffinity { vcpu_id })?;
        if affinity == 0 {
            return Err(VmPcpuMaskError::EmptyAffinity { vcpu_id });
        }
        vm_mask |= affinity;
    }
    Ok(vm_mask)
}

pub(super) fn run_on_vm_pcpus<E>(
    mut vm_mask: usize,
    mut run: impl FnMut(usize) -> Result<(), E>,
) -> Result<(), VmTlbiDispatchError<E>> {
    while vm_mask != 0 {
        let cpu_id = vm_mask.trailing_zeros() as usize;
        run(cpu_id).map_err(|source| VmTlbiDispatchError { cpu_id, source })?;
        vm_mask &= vm_mask - 1;
    }
    Ok(())
}

#[cfg(target_arch = "aarch64")]
pub(super) fn invalidate_vm(vm: &AxVM) -> AxVmResult {
    let placements = vm.get_vcpu_affinities_pcpu_ids();
    let vm_mask = vm_pcpu_mask(&placements).map_err(|error| {
        AxVmError::invalid_state(
            "perform VM-scoped AArch64 TLBI",
            std::format!("invalid vCPU affinity: {error:?}"),
        )
    })?;

    run_on_vm_pcpus(vm_mask, |cpu_id| {
        crate::host::task::run_on_cpu_sync(
            cpu_id,
            invalidate_guest_el1_tlb_local,
            core::ptr::null_mut(),
        )
    })
    .map_err(|error| {
        AxVmError::host(
            "perform VM-scoped AArch64 TLBI",
            std::format!(
                "target CPU {} rejected synchronous execution: {:?}",
                error.cpu_id,
                error.source
            ),
        )
    })
}

#[cfg(target_arch = "aarch64")]
unsafe fn invalidate_guest_el1_tlb_local(_arg: *mut ()) {
    // This is deliberately the non-shareable operation. AxVM dispatches it
    // once to each pCPU in the VM mask, so unrelated RTOS CPUs are untouched.
    unsafe {
        asm!("dsb sy", "tlbi vmalle1", "dsb sy", "isb", options(nostack));
    }
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, vec};

    use super::{VmPcpuMaskError, VmTlbiDispatchError, run_on_vm_pcpus, vm_pcpu_mask};

    #[test]
    fn linux_mask_contains_only_its_two_host_cpus() {
        let linux = [(0, Some(0b0011), 0), (1, Some(0b0011), 1)];
        let rtthread = [(0, Some(0b0100), 2)];

        let linux_mask = vm_pcpu_mask(&linux).unwrap();
        let rtthread_mask = vm_pcpu_mask(&rtthread).unwrap();

        assert_eq!(linux_mask, 0b0011);
        assert_eq!(rtthread_mask, 0b0100);
        assert_eq!(linux_mask & rtthread_mask, 0);
    }

    #[test]
    fn vm_scoped_policy_rejects_unbounded_or_empty_affinity() {
        assert_eq!(vm_pcpu_mask(&[]), Err(VmPcpuMaskError::NoVcpus));
        assert_eq!(
            vm_pcpu_mask(&[(0, None, 0)]),
            Err(VmPcpuMaskError::MissingAffinity { vcpu_id: 0 })
        );
        assert_eq!(
            vm_pcpu_mask(&[(1, Some(0), 1)]),
            Err(VmPcpuMaskError::EmptyAffinity { vcpu_id: 1 })
        );
    }

    #[test]
    fn shootdown_runs_each_selected_cpu_exactly_once() {
        let visited = RefCell::new(vec![]);

        run_on_vm_pcpus(0b1011, |cpu_id| {
            visited.borrow_mut().push(cpu_id);
            Ok::<_, ()>(())
        })
        .unwrap();

        assert_eq!(*visited.borrow(), vec![0, 1, 3]);
    }

    #[test]
    fn shootdown_stops_and_reports_the_failing_cpu() {
        let visited = RefCell::new(vec![]);

        let result = run_on_vm_pcpus(0b1111, |cpu_id| {
            visited.borrow_mut().push(cpu_id);
            if cpu_id == 1 {
                Err("ipi failed")
            } else {
                Ok(())
            }
        });

        assert_eq!(
            result,
            Err(VmTlbiDispatchError {
                cpu_id: 1,
                source: "ipi failed",
            })
        );
        assert_eq!(*visited.borrow(), vec![0, 1]);
    }
}
