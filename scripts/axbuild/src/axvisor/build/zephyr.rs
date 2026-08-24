use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, anyhow};
use ostool::build::config::Cargo;

use crate::context::ResolvedAxvisorRequest;

const ZEPHYR_IMAGE_NAME: &str = "zephyr.bin";
const BUILD_SCRIPT: &str = "os/axvisor/scripts/build_zephyr_task123.sh";
const DEFAULT_OUTPUT: &str =
    "tmp/source-cache/zephyr/dccb09599635bdff17633fa7e9dab014b91dce90/current-image";

pub(super) fn inject_prebuild(
    cargo: &mut Cargo,
    request: &ResolvedAxvisorRequest,
    vmconfigs: &[PathBuf],
    rock4d_hint: bool,
) -> anyhow::Result<()> {
    let workspace_root = request
        .axvisor_dir
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| anyhow!("AxVisor directory has no workspace root"))?;
    let build_script = workspace_root.join(BUILD_SCRIPT);
    let output = workspace_root.join(DEFAULT_OUTPUT);

    for vmconfig in vmconfigs {
        if !has_zephyr_image(vmconfig)? {
            continue;
        }
        let board = if rock4d_hint || is_rock4d_vmconfig(vmconfig) {
            "rock-4d"
        } else {
            "qemu"
        };
        let command = format!(
            "bash {} --board {} {}",
            shell_quote(&build_script),
            board,
            shell_quote(&output),
        );
        if !cargo
            .pre_build_cmds
            .iter()
            .any(|existing| existing == &command)
        {
            cargo.pre_build_cmds.push(command);
        }
        log::info!(
            "AxVisor pre-build will prepare Zephyr image {} for VM config {}",
            output.join("current/zephyr.bin").display(),
            vmconfig.display()
        );
    }
    Ok(())
}

fn is_rock4d_vmconfig(vmconfig: &Path) -> bool {
    vmconfig
        .components()
        .any(|component| component.as_os_str() == "rock-4d")
}

fn has_zephyr_image(vmconfig: &Path) -> anyhow::Result<bool> {
    let content = fs::read_to_string(vmconfig)
        .with_context(|| format!("failed to read VM config {}", vmconfig.display()))?;
    let document = content
        .parse::<toml::Table>()
        .with_context(|| format!("failed to parse VM config {}", vmconfig.display()))?;
    let Some(kernel) = document.get("kernel").and_then(toml::Value::as_table) else {
        return Ok(false);
    };
    if kernel.get("image_location").and_then(toml::Value::as_str) != Some("memory") {
        return Ok(false);
    }
    Ok(kernel
        .get("kernel_path")
        .and_then(toml::Value::as_str)
        .map(Path::new)
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        == Some(ZEPHYR_IMAGE_NAME))
}

fn shell_quote(path: &Path) -> String {
    let value = path.to_string_lossy().replace('\'', "'\\''");
    format!("'{value}'")
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn detects_memory_zephyr_image() {
        let root = tempdir().unwrap();
        let config = root.path().join("zephyr.toml");
        fs::write(
            &config,
            "[kernel]\nimage_location = \"memory\"\nkernel_path = \"zephyr.bin\"\n",
        )
        .unwrap();

        assert!(has_zephyr_image(&config).unwrap());
    }

    #[test]
    fn ignores_non_zephyr_image() {
        let root = tempdir().unwrap();
        let config = root.path().join("guest.toml");
        fs::write(
            &config,
            "[kernel]\nimage_location = \"memory\"\nkernel_path = \"linux.bin\"\n",
        )
        .unwrap();

        assert!(!has_zephyr_image(&config).unwrap());
    }

    #[test]
    fn recognizes_rock4d_vmconfig_path() {
        assert!(is_rock4d_vmconfig(Path::new(
            "os/axvisor/configs/vms/rock-4d/zephyr-task123.toml"
        )));
        assert!(!is_rock4d_vmconfig(Path::new(
            "os/axvisor/configs/vms/qemu/aarch64/zephyr-task123.toml"
        )));
    }
}
