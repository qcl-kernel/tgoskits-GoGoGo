#[cfg(any(feature = "fs", feature = "embedded-rootfs"))]
mod block;

#[cfg(all(feature = "fs", feature = "embedded-rootfs"))]
compile_error!("ax-runtime features `fs` and `embedded-rootfs` are mutually exclusive");

#[cfg(feature = "embedded-rootfs")]
#[ax_crate_interface::def_interface]
pub trait EmbeddedRootFsIf {
    fn archive() -> &'static [u8];
}

cfg_if::cfg_if! {
    if #[cfg(feature = "embedded-rootfs")] {
        pub(crate) fn init(_bootargs: Option<&str>) {
            block::install_runtime();
            let archive = ax_crate_interface::call_interface!(EmbeddedRootFsIf::archive);
            let fs = ax_fs_ng::embedded::new_filesystem(archive)
                .unwrap_or_else(|error| panic!("invalid embedded root filesystem: {error}"));
            ax_fs_ng::install_root_filesystem(fs, "embedded-cpio");
        }

        #[cfg(all(feature = "smp", feature = "ipi"))]
        pub(crate) fn online_smp() {
            block::online_smp();
        }
    } else if #[cfg(feature = "fs")] {

        pub(crate) fn init(bootargs: Option<&str>) {
            block::init(bootargs);
        }

        #[cfg(all(feature = "smp", feature = "ipi"))]
        pub(crate) fn online_smp() {
            block::online_smp();
        }
    } else {
        pub(crate) fn init(_bootargs: Option<&str>) {}

        #[cfg(all(feature = "smp", feature = "ipi"))]
        pub(crate) fn online_smp() {}
    }
}
