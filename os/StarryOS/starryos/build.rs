fn main() {
    println!("cargo:rerun-if-changed=linker.ld");

    let out_dir = std::env::var("OUT_DIR").unwrap();
    let linker = format!("{out_dir}/linker.x");

    std::fs::write(&linker, include_str!("linker.ld")).unwrap();
    println!("cargo:rustc-link-search={out_dir}");

    let target_dir = std::path::Path::new(&out_dir).join("../../..");
    std::fs::write(target_dir.join("linker.x"), include_str!("linker.ld")).unwrap();

    println!("cargo:rerun-if-env-changed=STARRY_EMBEDDED_ROOTFS");
    if std::env::var_os("CARGO_FEATURE_AXVISOR_GUEST").is_some() {
        let source = std::env::var_os("STARRY_EMBEDDED_ROOTFS")
            .expect("STARRY_EMBEDDED_ROOTFS is required with axvisor-guest");
        let source = std::path::PathBuf::from(source);
        println!("cargo:rerun-if-changed={}", source.display());
        std::fs::copy(&source, std::path::Path::new(&out_dir).join("starryos-rootfs.cpio"))
            .unwrap_or_else(|error| {
                panic!(
                    "failed to copy embedded root filesystem {}: {error}",
                    source.display()
                )
            });
    }
}
