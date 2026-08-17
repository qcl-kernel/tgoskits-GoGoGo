#![no_std]
#![no_main]
#![doc = include_str!("../../README.md")]

extern crate alloc;

use alloc::{borrow::ToOwned, vec::Vec};

use ax_std as _;

#[cfg(feature = "axvisor-guest")]
struct EmbeddedRootFsIfImpl;

#[cfg(feature = "axvisor-guest")]
#[ax_crate_interface::impl_interface]
impl ax_runtime::EmbeddedRootFsIf for EmbeddedRootFsIfImpl {
    fn archive() -> &'static [u8] {
        include_bytes!(concat!(env!("OUT_DIR"), "/starryos-rootfs.cpio"))
    }
}

#[cfg(feature = "axvisor-guest")]
pub const CMDLINE: &[&str] = &["/init"];

#[cfg(not(feature = "axvisor-guest"))]
pub const CMDLINE: &[&str] = &["/bin/sh", "-c", include_str!("init.sh")];

#[unsafe(no_mangle)]
extern "C" fn main() {
    let args = CMDLINE
        .iter()
        .copied()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let envs = [];

    starry_kernel::entry::init(&args, &envs);
}
