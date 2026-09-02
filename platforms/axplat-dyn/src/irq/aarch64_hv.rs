use core::sync::atomic::{AtomicPtr, AtomicU64, Ordering};

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
use ax_plat::irq::{Aarch64HvIrqIf, IrqSource};

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
use super::IrqIfImpl;

const AARCH64_GIC_INTID_COUNT: usize = 1024;
const ROUTE_NONE: u64 = 0;
const ROUTE_PRESENT: u64 = 1 << 63;
const VM_ID_SHIFT: u32 = 32;
const VCPU_ID_SHIFT: u32 = 16;
const FIELD_MASK: u64 = 0xffff;
const VM_ID_MASK: u64 = 0x7fff_ffff;

static VIRTUAL_IRQ_INJECTOR: AtomicPtr<()> = AtomicPtr::new(core::ptr::null_mut());
static GUEST_IRQ_ROUTES: GuestIrqRoutes<AARCH64_GIC_INTID_COUNT> = GuestIrqRoutes::new();

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct GuestIrqRoute {
    vm_id: usize,
    vcpu_id: usize,
    guest_intid: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RouteError {
    Conflict,
    OutOfRange,
}

struct GuestIrqRoutes<const N: usize> {
    entries: [AtomicU64; N],
}

impl<const N: usize> GuestIrqRoutes<N> {
    const fn new() -> Self {
        Self {
            entries: [const { AtomicU64::new(ROUTE_NONE) }; N],
        }
    }

    fn register(
        &self,
        physical_intid: usize,
        vm_id: usize,
        vcpu_id: usize,
        guest_intid: usize,
    ) -> Result<(), RouteError> {
        let Some(entry) = self.entries.get(physical_intid) else {
            return Err(RouteError::OutOfRange);
        };
        let Some(encoded) = encode_route(vm_id, vcpu_id, guest_intid) else {
            return Err(RouteError::OutOfRange);
        };
        match entry.compare_exchange(ROUTE_NONE, encoded, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => Ok(()),
            Err(previous) if previous == encoded => Ok(()),
            Err(_) => Err(RouteError::Conflict),
        }
    }

    fn lookup(&self, physical_intid: usize) -> Option<GuestIrqRoute> {
        self.entries
            .get(physical_intid)
            .and_then(|entry| decode_route(entry.load(Ordering::Acquire)))
    }

    fn unregister_vm(&self, vm_id: usize) {
        for entry in &self.entries {
            let mut current = entry.load(Ordering::Acquire);
            while decode_route(current).is_some_and(|route| route.vm_id == vm_id) {
                match entry.compare_exchange(
                    current,
                    ROUTE_NONE,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => break,
                    Err(updated) => current = updated,
                }
            }
        }
    }
}

fn encode_route(vm_id: usize, vcpu_id: usize, guest_intid: usize) -> Option<u64> {
    if vm_id > VM_ID_MASK as usize
        || vcpu_id > FIELD_MASK as usize
        || guest_intid > FIELD_MASK as usize
    {
        return None;
    }
    Some(
        ROUTE_PRESENT
            | ((vm_id as u64) << VM_ID_SHIFT)
            | ((vcpu_id as u64) << VCPU_ID_SHIFT)
            | guest_intid as u64,
    )
}

fn decode_route(encoded: u64) -> Option<GuestIrqRoute> {
    (encoded & ROUTE_PRESENT != 0).then_some(GuestIrqRoute {
        vm_id: ((encoded >> VM_ID_SHIFT) & VM_ID_MASK) as usize,
        vcpu_id: ((encoded >> VCPU_ID_SHIFT) & FIELD_MASK) as usize,
        guest_intid: (encoded & FIELD_MASK) as usize,
    })
}

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
#[impl_plat_interface]
impl Aarch64HvIrqIf for IrqIfImpl {
    fn register_virtual_irq_injector(injector: fn(usize, usize, usize, usize) -> bool) {
        VIRTUAL_IRQ_INJECTOR.store(injector as *mut (), Ordering::Release);
        debug!("AArch64 virtual IRQ injector registered");
    }

    fn register_guest_irq_route(
        physical_intid: usize,
        vm_id: usize,
        vcpu_id: usize,
        guest_intid: usize,
        target_cpu: usize,
    ) {
        match GUEST_IRQ_ROUTES.register(physical_intid, vm_id, vcpu_id, guest_intid) {
            Ok(()) => {
                set_physical_irq_affinity(physical_intid, target_cpu);
                set_physical_irq_enabled(physical_intid, true);
                info!(
                    "AArch64 routed SPI: physical_intid={physical_intid} -> VM[{vm_id}] \
                     VCpu[{vcpu_id}] guest_intid={guest_intid}, pCPU={target_cpu}"
                );
            }
            Err(error) => warn!(
                "AArch64 routed SPI registration rejected: physical_intid={physical_intid}, \
                 VM[{vm_id}] VCpu[{vcpu_id}], guest_intid={guest_intid}: {error:?}"
            ),
        }
    }

    fn unregister_guest_irq_routes(vm_id: usize) {
        for physical_intid in 0..AARCH64_GIC_INTID_COUNT {
            if GUEST_IRQ_ROUTES.lookup(physical_intid).is_some_and(|route| route.vm_id == vm_id) {
                set_physical_irq_enabled(physical_intid, false);
            }
        }
        GUEST_IRQ_ROUTES.unregister_vm(vm_id);
    }
}

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
fn resolve_physical_irq(
    physical_intid: usize,
) -> Result<ax_plat::irq::IrqId, ax_plat::irq::IrqError> {
    let gsi = u32::try_from(physical_intid).map_err(|_| ax_plat::irq::IrqError::InvalidIrq)?;
    somehal::irq::resolve_irq_source(IrqSource::AcpiGsi(gsi))
}

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
fn set_physical_irq_enabled(physical_intid: usize, enabled: bool) {
    match resolve_physical_irq(physical_intid) {
        Ok(irq) => {
            if let Err(error) = somehal::irq::irq_set_enable(irq, enabled) {
                warn!("failed to set routed SPI {physical_intid} enabled={enabled}: {error:?}");
            }
        }
        Err(error) => warn!("failed to resolve routed SPI {physical_intid}: {error:?}"),
    }
}

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
fn set_physical_irq_affinity(physical_intid: usize, target_cpu: usize) {
    match resolve_physical_irq(physical_intid) {
        Ok(irq) => {
            if let Err(error) = somehal::irq::irq_set_affinity(
                irq,
                somehal::irq::IrqAffinity::Fixed { cpu_id: target_cpu },
            ) {
                warn!("failed to set routed SPI {physical_intid} affinity: {error:?}");
            }
        }
        Err(error) => warn!("failed to resolve routed SPI {physical_intid}: {error:?}"),
    }
}

#[cfg(all(target_arch = "aarch64", feature = "hv"))]
pub(super) fn inject_virtual_irq(physical_intid: usize) -> bool {
    let Some(route) = GUEST_IRQ_ROUTES.lookup(physical_intid) else {
        return false;
    };
    let injector = VIRTUAL_IRQ_INJECTOR.load(Ordering::Acquire);
    if injector.is_null() {
        warn!("AArch64 virtual IRQ injector is not registered");
        return false;
    }
    unsafe {
        core::mem::transmute::<*mut (), fn(usize, usize, usize, usize) -> bool>(injector)(
            route.vm_id,
            route.vcpu_id,
            route.guest_intid,
            physical_intid,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn route_registration_preserves_owner_and_guest_intid() {
        let routes = GuestIrqRoutes::<64>::new();

        assert_eq!(routes.register(50, 3, 0, 50), Ok(()));
        assert_eq!(routes.lookup(50), Some(GuestIrqRoute {
            vm_id: 3,
            vcpu_id: 0,
            guest_intid: 50,
        }));
    }

    #[test]
    fn conflicting_route_is_rejected_until_owner_unregisters() {
        let routes = GuestIrqRoutes::<64>::new();

        assert_eq!(routes.register(50, 3, 0, 50), Ok(()));
        assert_eq!(routes.register(50, 1, 0, 50), Err(RouteError::Conflict));

        routes.unregister_vm(3);
        assert_eq!(routes.register(50, 1, 0, 50), Ok(()));
        assert_eq!(routes.lookup(50).unwrap().vm_id, 1);
    }

    #[test]
    fn out_of_range_physical_intid_is_rejected() {
        let routes = GuestIrqRoutes::<64>::new();

        assert_eq!(routes.register(64, 3, 0, 50), Err(RouteError::OutOfRange));
        assert_eq!(routes.lookup(64), None);
    }
}
