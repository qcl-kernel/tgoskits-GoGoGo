//! Small capability boundaries implemented by the selected guest architecture.

use alloc::vec::Vec;

use crate::AxVmResult;

/// Guest firmware preparation performed before common VM memory loading.
pub(crate) trait GuestBootPlatform {
    fn init_guest_boot_resources() {}

    fn prepare_guest_boot(
        _vm_config: &mut crate::config::AxVMConfig,
        _vm_create_config: &mut axvmconfig::AxVMCrateConfig,
        _provider: &dyn crate::boot::BootImageProvider,
    ) -> AxVmResult<Option<crate::boot::fdt::GuestDtbImage>> {
        Ok(None)
    }
}

/// Architecture-specific guest image planning layered over common byte loading.
pub(crate) trait BootImagePlatform {
    fn default_boot_firmware_load_gpa(
        _config: &axvmconfig::AxVMCrateConfig,
    ) -> Option<axvm_types::GuestPhysAddr> {
        None
    }

    fn load_images_from_memory(
        loader: &mut crate::boot::images::ImageLoaderCore<'_>,
        images: crate::boot::StaticVmImage,
    ) -> AxVmResult {
        loader.load_standard_images_from_memory(images, Self::load_guest_dtb)
    }

    #[cfg(any(feature = "fs", feature = "host-fs"))]
    fn load_images_from_filesystem(
        loader: &mut crate::boot::images::ImageLoaderCore<'_>,
    ) -> AxVmResult {
        loader.load_standard_images_from_filesystem(Self::load_guest_dtb)
    }

    fn load_guest_dtb(
        _loader: &crate::boot::images::ImageLoaderCore<'_>,
        _dtb: &crate::boot::fdt::GuestDtbImage,
    ) -> AxVmResult {
        Ok(())
    }

    fn is_x86_linux_image_config(
        _config: &axvmconfig::AxVMCrateConfig,
        _provider: &dyn crate::boot::BootImageProvider,
    ) -> bool {
        false
    }
}

/// Architecture-specific host timer callback registration.
pub(crate) trait HostTimePlatform {
    fn register_timer_callback() {
        ax_std::os::arceos::modules::ax_task::register_timer_callback(|_| {
            crate::check_timer_events();
        });
    }
}

#[allow(
    dead_code,
    reason = "used by AArch64 production and portable host tests"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Aarch64PassthroughSpiRoute {
    pub(crate) irq: u32,
    pub(crate) cpu_phys_id: usize,
    pub(crate) target_cpu_affinity: (u8, u8, u8, u8),
}

#[allow(
    dead_code,
    reason = "used by AArch64 production and portable host tests"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Aarch64PassthroughSpiRouteError {
    MissingVcpuPlacement,
}

#[allow(
    dead_code,
    reason = "used by AArch64 production and portable host tests"
)]
pub(crate) fn aarch64_passthrough_spi_routes(
    vcpu_placements: &[(usize, Option<usize>, usize)],
    passthrough_spis: &[u32],
) -> Result<Vec<Aarch64PassthroughSpiRoute>, Aarch64PassthroughSpiRouteError> {
    if passthrough_spis.is_empty() {
        return Ok(Vec::new());
    }
    let cpu_phys_id = vcpu_placements
        .first()
        .map(|(_, _, cpu_phys_id)| *cpu_phys_id)
        .ok_or(Aarch64PassthroughSpiRouteError::MissingVcpuPlacement)?;
    Ok(passthrough_spis
        .iter()
        .map(|spi| Aarch64PassthroughSpiRoute {
            irq: *spi + 32,
            cpu_phys_id,
            target_cpu_affinity: (0, 0, 0, cpu_phys_id as u8),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_spi_routes_use_configured_vcpu_placement_and_gic_offset() {
        let routes =
            aarch64_passthrough_spi_routes(&[(3, Some(1 << 11), 11), (4, None, 19)], &[0, 41])
                .expect("configured placement must produce SPI routes");

        assert_eq!(
            routes,
            alloc::vec![
                Aarch64PassthroughSpiRoute {
                    irq: 32,
                    cpu_phys_id: 11,
                    target_cpu_affinity: (0, 0, 0, 11),
                },
                Aarch64PassthroughSpiRoute {
                    irq: 73,
                    cpu_phys_id: 11,
                    target_cpu_affinity: (0, 0, 0, 11),
                },
            ]
        );
    }

    #[test]
    fn passthrough_spi_routes_reject_missing_vcpu_placement() {
        assert_eq!(
            aarch64_passthrough_spi_routes(&[], &[18]),
            Err(Aarch64PassthroughSpiRouteError::MissingVcpuPlacement)
        );
    }
}
