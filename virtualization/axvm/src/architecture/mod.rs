//! Architecture-neutral contracts shared by target implementations.

mod capabilities;
mod exit;
pub(crate) mod ops;
mod types;

#[allow(
    unused_imports,
    reason = "used by AArch64 production while remaining host-testable"
)]
pub(crate) use capabilities::{Aarch64PassthroughSpiRoute, aarch64_passthrough_spi_routes};
pub(crate) use capabilities::{BootImagePlatform, GuestBootPlatform, HostTimePlatform};
pub(crate) use exit::{handle_hypercall, handle_mmio_read, handle_mmio_write};
pub(crate) use ops::ArchOps;
pub(crate) use types::{BoundVcpuExit, HypercallExit, MmioReadExit, MmioWriteExit, VcpuRunAction};
