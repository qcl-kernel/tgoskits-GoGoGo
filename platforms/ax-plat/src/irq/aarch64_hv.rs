//! AArch64 physical-to-virtual interrupt routing interface.

#[def_plat_interface]
pub trait Aarch64HvIrqIf {
    /// Registers the AxVM callback used by the hard-IRQ routing path.
    fn register_virtual_irq_injector(injector: fn(usize, usize, usize, usize) -> bool);

    /// Routes one physical GIC INTID to a guest vCPU and virtual INTID.
    fn register_guest_irq_route(
        physical_intid: usize,
        vm_id: usize,
        vcpu_id: usize,
        guest_intid: usize,
        target_cpu: usize,
    );

    /// Removes all physical interrupt routes owned by a VM.
    fn unregister_guest_irq_routes(vm_id: usize);
}
