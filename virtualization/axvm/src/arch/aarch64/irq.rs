//! AArch64 platform IRQ routing used by AxVM.

pub(crate) fn register_platform_irq_injector() {
    ax_plat::irq::aarch64_hv::register_virtual_irq_injector(inject_platform_irq);
}

pub fn register_guest_irq_route(
    physical_intid: usize,
    vm_id: usize,
    vcpu_id: usize,
    guest_intid: usize,
    target_cpu: usize,
) {
    ax_plat::irq::aarch64_hv::register_guest_irq_route(
        physical_intid,
        vm_id,
        vcpu_id,
        guest_intid,
        target_cpu,
    );
}

pub fn unregister_guest_irq_routes(vm_id: usize) {
    ax_plat::irq::aarch64_hv::unregister_guest_irq_routes(vm_id);
}

fn inject_platform_irq(
    vm_id: usize,
    vcpu_id: usize,
    guest_intid: usize,
    physical_intid: usize,
) -> bool {
    match crate::runtime::vcpus::queue_pending_interrupt(
        vm_id,
        vcpu_id,
        crate::vm::PendingInterrupt::External {
            vector: guest_intid,
            physical_irq: physical_intid,
        },
    ) {
        Ok(()) => true,
        Err(error) => {
            warn!(
                "failed to queue AArch64 routed SPI {physical_intid} as guest INTID \
                 {guest_intid} for VM[{vm_id}] VCpu[{vcpu_id}]: {error:?}"
            );
            false
        }
    }
}
