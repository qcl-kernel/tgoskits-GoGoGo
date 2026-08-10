//! AArch64 GIC host operations for the ArceOS-backed AxVM runtime.

use arm_gic_driver::v3::{
    ICH_ELRSR_EL2, ICH_HCR_EL2, ICH_LR_EL2, ICH_VTR_EL2, ReadWriteable, Readable, ich_lr_el2_get,
    ich_lr_el2_write,
};
use ax_memory_addr::{PhysAddr, VirtAddr};

use crate::host::{HostMemory, default_host};

fn with_gic<T>(f: impl FnOnce(&mut rdif_intc::Intc) -> T) -> T {
    let mut gic = rdrive::get_one::<rdif_intc::Intc>()
        .expect("failed to get GIC driver")
        .lock()
        .expect("failed to lock GIC driver");
    f(&mut gic)
}

pub(crate) fn inject_interrupt(irq: usize) {
    debug!("Injecting virtual interrupt: {irq}");

    with_gic(|gic| {
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v2::Gic>() {
            use arm_gic_driver::{
                IntId,
                v2::{VirtualInterruptConfig, VirtualInterruptState},
            };

            let gich = gic.hypervisor_interface().expect("failed to get GICH");
            gich.enable();
            gich.set_virtual_interrupt(
                0,
                VirtualInterruptConfig::software(
                    unsafe { IntId::raw(irq as _) },
                    None,
                    0,
                    VirtualInterruptState::Pending,
                    false,
                    true,
                ),
            );
            return;
        }

        if gic.typed_mut::<arm_gic_driver::v3::Gic>().is_some() {
            inject_interrupt_gic_v3(irq);
            return;
        }

        panic!("no GIC driver found");
    });
}

fn inject_interrupt_gic_v3(vector: usize) {
    debug!("Injecting virtual interrupt: vector={vector}");
    let elsr = ICH_ELRSR_EL2.read(ICH_ELRSR_EL2::STATUS);
    let lr_num = ICH_VTR_EL2.read(ICH_VTR_EL2::LISTREGS) as usize + 1;

    let mut free_lr = None;
    for i in 0..lr_num {
        if (1 << i) & elsr > 0 {
            free_lr.get_or_insert(i);
            continue;
        }

        let lr_val = ich_lr_el2_get(i);
        if lr_val.read(ICH_LR_EL2::VINTID) == vector as u64
            && lr_val.matches_any(&[ICH_LR_EL2::STATE::Pending, ICH_LR_EL2::STATE::Active])
        {
            debug!("Virtual interrupt {vector} already pending/active in LR{i}, skipping");
            return;
        }
    }

    let free_lr = free_lr
        .or_else(|| {
            (0..lr_num).find(|&i| ich_lr_el2_get(i).matches_all(ICH_LR_EL2::STATE::Invalid))
        })
        .unwrap_or_else(|| panic!("no free list register to inject IRQ {vector}"));

    ich_lr_el2_write(
        free_lr,
        ICH_LR_EL2::VINTID.val(vector as u64) + ICH_LR_EL2::STATE::Pending + ICH_LR_EL2::GROUP::SET,
    );

    if !ICH_HCR_EL2.is_set(ICH_HCR_EL2::EN) {
        warn!("Virtual interrupt interface not enabled, enabling now");
        ICH_HCR_EL2.modify(ICH_HCR_EL2::EN::SET);
    }

    debug!("Virtual interrupt {vector} injected successfully in LR{free_lr}");
}

pub(crate) fn read_gicd_iidr() -> u32 {
    with_gic(|gic| {
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v2::Gic>() {
            return gic.iidr_raw();
        }
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v3::Gic>() {
            return gic.iidr_raw();
        }
        panic!("no GIC driver found");
    })
}

pub(crate) fn read_gicd_typer() -> u32 {
    with_gic(|gic| {
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v2::Gic>() {
            return gic.typer_raw();
        }
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v3::Gic>() {
            return gic.typer_raw();
        }
        panic!("no GIC driver found");
    })
}

pub(crate) fn host_gicd_base() -> PhysAddr {
    with_gic(|gic| {
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v2::Gic>() {
            return default_host().virt_to_phys(VirtAddr::from(usize::from(gic.gicd_addr())));
        }
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v3::Gic>() {
            return default_host().virt_to_phys(VirtAddr::from(usize::from(gic.gicd_addr())));
        }
        panic!("no GIC driver found");
    })
}

pub(crate) fn host_gicr_base() -> PhysAddr {
    with_gic(|gic| {
        if let Some(gic) = gic.typed_mut::<arm_gic_driver::v3::Gic>() {
            return default_host().virt_to_phys(VirtAddr::from(usize::from(gic.gicr_addr())));
        }
        panic!("no GICv3 driver found");
    })
}

pub(crate) fn handle_current_irq() -> Option<usize> {
    // AArch64 ArceOS platform IRQ handlers acknowledge the current IRQ
    // internally. The raw vector argument is ignored by current GIC-backed
    // platforms, so keep the ack/EOI ownership inside the platform handler.
    ax_std::os::arceos::modules::ax_hal::irq::handle_irq(0).then_some(0)
}

pub(crate) fn fetch_irq() -> usize {
    handle_current_irq().unwrap_or(0)
}

use alloc::vec::Vec;

static PASSTHROUGH_SPIS_PTR: core::sync::atomic::AtomicPtr<u32> =
    core::sync::atomic::AtomicPtr::new(core::ptr::null_mut());
static PASSTHROUGH_SPIS_LEN: core::sync::atomic::AtomicUsize =
    core::sync::atomic::AtomicUsize::new(0);

pub(crate) fn install_passthrough_spis(spis: Vec<u32>) {
    let len = spis.len();
    let boxed: alloc::boxed::Box<[u32]> = spis.into_boxed_slice();
    let raw = alloc::boxed::Box::into_raw(boxed) as *mut u32;
    let old = PASSTHROUGH_SPIS_PTR.swap(raw, core::sync::atomic::Ordering::AcqRel);
    PASSTHROUGH_SPIS_LEN.store(len, core::sync::atomic::Ordering::Release);
    if !old.is_null() {
        let old_len = PASSTHROUGH_SPIS_LEN.load(core::sync::atomic::Ordering::Acquire);
        unsafe { let _ = alloc::boxed::Box::from_raw(core::slice::from_raw_parts_mut(old, old_len)); }
    }
}

fn write_gicd_set_clear(irqs: &[u32], is_enable: bool) {
    let gicd_base = host_gicd_base().as_usize();
    let base_reg = if is_enable { 0x0100 } else { 0x0180 };
    for &irq in irqs {
        let reg = base_reg + ((irq as usize) / 32) * 4;
        let bit = 1u32 << ((irq % 32) as u32);
        let paddr = ax_memory_addr::PhysAddr::from_usize(gicd_base + reg);
        let vaddr = crate::host::default_host().phys_to_virt(paddr);
        unsafe { core::ptr::write_volatile(vaddr.as_usize() as *mut u32, bit); }
    }
    unsafe { core::arch::asm!("dsb st", "isb"); }
}

pub(crate) fn disable_passthrough_spis() {
    let raw = PASSTHROUGH_SPIS_PTR.load(core::sync::atomic::Ordering::Acquire);
    let len = PASSTHROUGH_SPIS_LEN.load(core::sync::atomic::Ordering::Acquire);
    if raw.is_null() || len == 0 { return; }
    let spis: &[u32] = unsafe { core::slice::from_raw_parts(raw, len) };
    write_gicd_set_clear(spis, false);
}

pub(crate) fn reenable_passthrough_spis() {
    let raw = PASSTHROUGH_SPIS_PTR.load(core::sync::atomic::Ordering::Acquire);
    let len = PASSTHROUGH_SPIS_LEN.load(core::sync::atomic::Ordering::Acquire);
    if raw.is_null() || len == 0 { return; }
    let spis: &[u32] = unsafe { core::slice::from_raw_parts(raw, len) };
    write_gicd_set_clear(spis, true);
}
