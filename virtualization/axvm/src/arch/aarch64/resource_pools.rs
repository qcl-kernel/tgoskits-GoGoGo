//! AArch64 machine-owned automatic device and MSI resource windows.

use arm_vgic::{ArmVgicConfig, LPI_INTID_BASE};
use axdevice::ResourcePools;
use axdevice_base::*;

use crate::AxVmResult;

const AUTO_MMIO: core::ops::Range<u64> = 0x0a00_0000..0x0b00_0000;
const AUTO_MSI_ID_END: u32 = 0x1_0000;

pub(super) fn create(vgic: &ArmVgicConfig, vm_id: usize) -> AxVmResult<ResourcePools> {
    let controller = vgic.controller_id();
    let spi_count = match vgic {
        ArmVgicConfig::V2(config) => config.spi_count(),
        ArmVgicConfig::V3(config) => config.spi_count(),
    };
    let spi_end = 32usize
        .checked_add(spi_count)
        .ok_or_else(|| crate::AxVmError::invalid_config("AArch64 automatic SPI range overflows"))?;

    let mut pools = ResourcePools::new();
    pools.add_auto_mmio(AUTO_MMIO)?;
    // Fixed window used by the legacy virtio-net placement (0x0a00_0000) and
    // its wired controller input (SPI 16 = input 48), which the RT-Thread and
    // Zephyr task123 guests hard-code in their static device maps.
    pools.allow_fixed_mmio(0x0a00_0000..0x0a00_0200)?;
    pools.allow_fixed_controller_inputs(controller, ControllerInputId::new(48)..ControllerInputId::new(49))?;
    // Offset the auto SPI range per-VM so that concurrent VMs don't collide
    // in the global ASSIGNED_SPI_ROUTES table. Each VM gets a 64-SPI window.
    let window = 64usize;
    let auto_irq_start = 32usize + vm_id * window;
    let auto_irq_end = auto_irq_start
        .checked_add(window)
        .unwrap_or(spi_end)
        .min(spi_end);
    pools.add_auto_controller_inputs(
        controller,
        ControllerInputId::new(auto_irq_start)..ControllerInputId::new(auto_irq_end),
    )?;

    for assigned in vgic.assigned_spis() {
        let owner = std::format!("aarch64-physical-spi-{}", assigned.intid().raw());
        pools.reserve_wired_host_irq(
            owner,
            controller,
            ControllerInputId::new(assigned.intid().raw() as usize),
            assigned.host_irq(),
            assigned.trigger(),
        )?;
    }

    if let ArmVgicConfig::V3(config) = vgic {
        let lpi_end = config.lpi_limit().checked_add(1).ok_or_else(|| {
            crate::AxVmError::invalid_config("AArch64 automatic LPI range overflows")
        })?;
        for its in config.its() {
            pools.add_auto_msi_domain(
                controller,
                its.id(),
                MsiDeviceId::new(0)..MsiDeviceId::new(AUTO_MSI_ID_END),
                MsiEventId::new(0)..MsiEventId::new(AUTO_MSI_ID_END),
                LpiId::new(LPI_INTID_BASE)..LpiId::new(lpi_end),
            )?;
        }
    }
    Ok(pools)
}
