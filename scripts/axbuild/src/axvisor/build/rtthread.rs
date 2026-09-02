use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, anyhow};
use ostool::build::config::Cargo;

use crate::context::ResolvedAxvisorRequest;

const RTTHREAD_IMAGE_NAME: &str = "rtthread.bin";
const BUILD_SCRIPT: &str = "os/axvisor/scripts/build_rtthread_image.sh";

pub(super) fn inject_prebuild(
    cargo: &mut Cargo,
    request: &ResolvedAxvisorRequest,
    vmconfigs: &[PathBuf],
) -> anyhow::Result<()> {
    let workspace_root = request
        .axvisor_dir
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| anyhow!("Axvisor directory has no workspace root"))?;
    let build_script = workspace_root.join(BUILD_SCRIPT);

    for vmconfig in vmconfigs {
        let Some(image_path) = rtthread_image_path(vmconfig)? else {
            continue;
        };
        let mut command = format!(
            "bash {} --vm-config {}",
            shell_quote(&build_script),
            shell_quote(vmconfig),
        );
        if vmconfig
            .components()
            .any(|component| component.as_os_str() == "rock-4d")
        {
            command.push_str(" --rock4d");
        }
        if !cargo
            .pre_build_cmds
            .iter()
            .any(|existing| existing == &command)
        {
            cargo.pre_build_cmds.push(command);
        }
        log::info!(
            "AxVisor pre-build will prepare RT-Thread image {} for VM config {}",
            image_path.display(),
            vmconfig.display()
        );
    }
    Ok(())
}

fn rtthread_image_path(vmconfig: &Path) -> anyhow::Result<Option<PathBuf>> {
    let content = fs::read_to_string(vmconfig)
        .with_context(|| format!("failed to read VM config {}", vmconfig.display()))?;
    let document = content
        .parse::<toml::Table>()
        .with_context(|| format!("failed to parse VM config {}", vmconfig.display()))?;
    let Some(kernel) = document.get("kernel").and_then(toml::Value::as_table) else {
        return Ok(None);
    };
    if kernel.get("image_location").and_then(toml::Value::as_str) != Some("memory") {
        return Ok(None);
    }
    let Some(kernel_path) = kernel.get("kernel_path").and_then(toml::Value::as_str) else {
        return Ok(None);
    };
    if Path::new(kernel_path)
        .file_name()
        .and_then(|name| name.to_str())
        != Some(RTTHREAD_IMAGE_NAME)
    {
        return Ok(None);
    }
    let path = Path::new(kernel_path);
    Ok(Some(if path.is_absolute() {
        path.to_path_buf()
    } else {
        vmconfig
            .parent()
            .map(|parent| parent.join(path))
            .unwrap_or_else(|| path.to_path_buf())
    }))
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
    fn detects_relative_rtthread_image_path() {
        let root = tempdir().unwrap();
        let config = root.path().join("rock-4d/rtthread.toml");
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        fs::write(
            &config,
            "[kernel]\nimage_location = \"memory\"\nkernel_path = \"rtthread.bin\"\n",
        )
        .unwrap();

        assert_eq!(
            rtthread_image_path(&config).unwrap(),
            Some(config.parent().unwrap().join("rtthread.bin"))
        );
    }

    #[test]
    fn ignores_non_rtthread_memory_images() {
        let root = tempdir().unwrap();
        let config = root.path().join("guest.toml");
        fs::write(
            &config,
            "[kernel]\nimage_location = \"memory\"\nkernel_path = \"linux.bin\"\n",
        )
        .unwrap();

        assert_eq!(rtthread_image_path(&config).unwrap(), None);
    }
}
