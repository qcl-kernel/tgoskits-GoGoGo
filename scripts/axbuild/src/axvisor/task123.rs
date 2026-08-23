use std::{
    path::{Path, PathBuf},
    process::Command,
};

use clap::Args;

use super::Axvisor;

#[derive(Args, Default)]
pub struct Task123Args {
    /// Run the five-minute diagnostic comparison
    #[arg(long, conflicts_with = "full")]
    pub quick: bool,

    /// Run the one-hour formal comparison
    #[arg(long)]
    pub full: bool,

    /// Comparison output directory
    #[arg(long)]
    pub output: Option<PathBuf>,

    /// Shared artifact cache directory
    #[arg(long)]
    pub cache: Option<PathBuf>,

    /// Keep complete stability results when QEMU TCG exceeds timer deadlines
    #[arg(long)]
    pub allow_qemu_timer_limit: bool,
}

#[derive(Debug, Default)]
struct Task123Environment {
    image: Option<PathBuf>,
    image_meta: Option<PathBuf>,
    native_source: Option<PathBuf>,
}

#[derive(serde::Deserialize)]
struct Task123ImageMetadata {
    schema: u32,
    patch_set_sha256: String,
}

const RTTHREAD_PATCHES: [&str; 10] = [
    "0000-axvisor-aarch64-port.patch",
    "0009-native-qemu-memory-layout.patch",
    "0002-lwip-rx-mailbox-recover-notice.patch",
    "0003-virtio-net-reclaim-tx-used-ring.patch",
    "0004-virtio-net-use-rx-used-ring-head.patch",
    "0005-lwip-configurable-udp-recv-mailbox.patch",
    "0006-gicv3-use-redistributor-pending-registers.patch",
    "0007-gicv3-query-interrupt-enable-state.patch",
    "0008-aarch64-gtimer-use-absolute-deadlines.patch",
    "0010-virtio-net-benchmark-packet-hook.patch",
];

impl Task123Environment {
    fn from_process() -> Self {
        Self {
            image: non_empty_env("RTTHREAD_IMAGE"),
            image_meta: non_empty_env("RTTHREAD_IMAGE_META"),
            native_source: non_empty_env("RTTHREAD_NATIVE_SRC"),
        }
    }
}

fn non_empty_env(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[derive(Debug, Eq, PartialEq)]
struct Task123Plan {
    runner: PathBuf,
    rtthread_image: Option<PathBuf>,
    rtthread_image_meta: Option<PathBuf>,
    require_image_metadata: bool,
}

impl Task123Plan {
    fn resolve(workspace_root: &Path, environment: &Task123Environment) -> Self {
        let rtthread_image = environment.image.clone().or_else(|| {
            let native_source = environment.native_source.clone().unwrap_or_else(|| {
                workspace_root.join("tmp/source-cache/task123-rtthread-current")
            });
            let candidate = native_source.join("bsp/qemu-virt64-aarch64/rtthread.bin");
            if candidate.is_file() {
                let metadata = default_metadata_path(&candidate);
                if metadata_is_current(&metadata, workspace_root) {
                    return Some(candidate);
                }
            }

            let candidate = native_source.join("rtthread.bin");
            let metadata = default_metadata_path(&candidate);
            (candidate.is_file() && metadata_is_current(&metadata, workspace_root))
                .then_some(candidate)
        });
        let rtthread_image_meta = rtthread_image.as_ref().map(|image| {
            environment
                .image_meta
                .clone()
                .unwrap_or_else(|| default_metadata_path(image))
        });

        Self {
            runner: workspace_root.join("os/axvisor/scripts/run_task123_guest_comparison.sh"),
            rtthread_image,
            rtthread_image_meta,
            require_image_metadata: true,
        }
    }
}

fn default_metadata_path(image: &Path) -> PathBuf {
    let mut metadata = image.as_os_str().to_os_string();
    metadata.push(".meta.json");
    PathBuf::from(metadata)
}

fn metadata_is_current(path: &Path, workspace_root: &Path) -> bool {
    std::fs::File::open(path)
        .and_then(|file| {
            let metadata: Task123ImageMetadata = serde_json::from_reader(file)?;
            Ok(metadata.schema == 1
                && metadata.patch_set_sha256 == patch_set_digest(workspace_root))
        })
        .unwrap_or(false)
}

fn patch_set_digest(workspace_root: &Path) -> String {
    use std::fmt::Write as _;

    use sha2::{Digest, Sha256};

    let mut manifest = String::new();
    for name in RTTHREAD_PATCHES {
        let path = workspace_root
            .join("os/axvisor/patches/rtthread")
            .join(name);
        let Some(contents) = std::fs::read(path).ok() else {
            return String::new();
        };
        let mut patch_digest = Sha256::new();
        patch_digest.update(contents);
        writeln!(&mut manifest, "{:x}  {name}", patch_digest.finalize())
            .expect("writing an in-memory patch manifest cannot fail");
    }
    let mut digest = Sha256::new();
    digest.update(manifest.as_bytes());
    format!("{:x}", digest.finalize())
}

impl Task123Args {
    fn runner_arguments(&self) -> Vec<String> {
        let mut arguments = Vec::new();
        if self.full {
            arguments.push("--full".to_string());
        } else {
            arguments.push("--quick".to_string());
        }
        if let Some(output) = &self.output {
            arguments.push("--output".to_string());
            arguments.push(output.display().to_string());
        }
        if let Some(cache) = &self.cache {
            arguments.push("--cache".to_string());
            arguments.push(cache.display().to_string());
        }
        if self.allow_qemu_timer_limit {
            arguments.push("--allow-qemu-timer-limit".to_string());
        }
        arguments
    }
}

pub(super) async fn run(axvisor: &mut Axvisor, args: Task123Args) -> anyhow::Result<()> {
    let workspace_root = axvisor.app.workspace_root().to_path_buf();
    let environment = Task123Environment::from_process();
    let plan = Task123Plan::resolve(&workspace_root, &environment);
    if let Some(output) = &args.output {
        prepare_output_parent(&workspace_root, output)?;
    }
    plan.execute(&args.runner_arguments())
}

fn prepare_output_parent(workspace_root: &Path, output: &Path) -> anyhow::Result<()> {
    let parent = output.parent().unwrap_or_else(|| Path::new("."));
    let parent = if output.is_absolute() {
        parent.to_path_buf()
    } else {
        workspace_root.join(parent)
    };
    std::fs::create_dir_all(&parent).map_err(|error| {
        anyhow::anyhow!(
            "failed to create Task123 output parent {}: {error}",
            parent.display()
        )
    })
}

impl Task123Plan {
    fn execute(&self, arguments: &[String]) -> anyhow::Result<()> {
        if let Some(image) = &self.rtthread_image {
            println!("RTTHREAD_IMAGE {}", image.display());
        } else {
            println!("RTTHREAD_IMAGE <build-on-demand>");
        }
        if let Some(metadata) = &self.rtthread_image_meta {
            println!("RTTHREAD_IMAGE_META {}", metadata.display());
        }
        println!(
            "RTTHREAD_REQUIRE_IMAGE_METADATA {}",
            if self.require_image_metadata { 1 } else { 0 }
        );

        let mut command = Command::new(&self.runner);
        command.args(arguments);
        if let Some(image) = &self.rtthread_image {
            command.env("RTTHREAD_IMAGE", image);
        }
        if let Some(metadata) = &self.rtthread_image_meta {
            command.env("RTTHREAD_IMAGE_META", metadata);
        }
        if self.require_image_metadata {
            command.env("RTTHREAD_REQUIRE_IMAGE_METADATA", "1");
        }
        let status = command.status()?;
        anyhow::ensure!(
            status.success(),
            "Task123 guest comparison exited with status {status}"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn runner_arguments_default_to_quick_diagnostic_mode() {
        let args = Task123Args::default();

        assert_eq!(args.runner_arguments(), vec!["--quick"]);
    }

    #[test]
    fn runner_arguments_preserve_user_selection() {
        let args = Task123Args {
            full: true,
            ..Task123Args::default()
        };

        assert_eq!(args.runner_arguments(), vec!["--full"]);
    }

    #[test]
    fn runner_arguments_forward_timer_limit_opt_in() {
        let args = Task123Args {
            full: true,
            allow_qemu_timer_limit: true,
            ..Task123Args::default()
        };

        assert_eq!(
            args.runner_arguments(),
            vec!["--full", "--allow-qemu-timer-limit"]
        );
    }

    #[test]
    fn runner_arguments_forward_optional_paths() {
        let args = Task123Args {
            quick: true,
            output: Some(PathBuf::from("/results")),
            cache: Some(PathBuf::from("/cache")),
            allow_qemu_timer_limit: true,
            ..Task123Args::default()
        };

        assert_eq!(
            args.runner_arguments(),
            vec![
                "--quick",
                "--output",
                "/results",
                "--cache",
                "/cache",
                "--allow-qemu-timer-limit"
            ]
        );
    }

    #[test]
    fn prepares_missing_output_parent_for_relative_and_absolute_paths() {
        let workspace = tempdir().unwrap();
        let relative_output = PathBuf::from("tmp/results/run");
        prepare_output_parent(workspace.path(), &relative_output).unwrap();
        assert!(workspace.path().join("tmp/results").is_dir());

        let absolute_output = workspace.path().join("absolute/results/run");
        prepare_output_parent(workspace.path(), &absolute_output).unwrap();
        assert!(workspace.path().join("absolute/results").is_dir());
    }

    #[test]
    fn plan_uses_explicit_image_without_requiring_persistent_build() {
        let plan = Task123Plan::resolve(
            Path::new("/workspace"),
            &Task123Environment {
                image: Some(PathBuf::from("/explicit/rtthread.bin")),
                image_meta: Some(PathBuf::from("/explicit/rtthread.meta.json")),
                native_source: None,
            },
        );

        assert_eq!(
            plan.rtthread_image,
            Some(PathBuf::from("/explicit/rtthread.bin"))
        );
        assert_eq!(
            plan.rtthread_image_meta,
            Some(PathBuf::from("/explicit/rtthread.meta.json"))
        );
        assert!(plan.require_image_metadata);
    }

    #[test]
    fn plan_selects_persistent_image_only_when_image_and_metadata_exist() {
        let workspace = tempdir().unwrap();
        let digest = write_patch_set(workspace.path());
        let image = workspace
            .path()
            .join("tmp/source-cache/task123-rtthread-current/rtthread.bin");
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(
            PathBuf::from(format!("{}.meta.json", image.display())),
            &format!(r#"{{"schema":1,"patch_set_sha256":"{digest}"}}"#),
        )
        .unwrap();

        let plan = Task123Plan::resolve(workspace.path(), &Task123Environment::default());

        assert_eq!(plan.rtthread_image, Some(image.clone()));
        assert_eq!(
            plan.rtthread_image_meta,
            Some(PathBuf::from(format!("{}.meta.json", image.display())))
        );
    }

    #[test]
    fn plan_rejects_persistent_image_with_unsupported_metadata_schema() {
        let workspace = tempdir().unwrap();
        let image = workspace
            .path()
            .join("tmp/source-cache/task123-rtthread-current/rtthread.bin");
        let metadata = PathBuf::from(format!("{}.meta.json", image.display()));
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(&metadata, br#"{"schema": 0}"#).unwrap();

        let plan = Task123Plan::resolve(workspace.path(), &Task123Environment::default());

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
    }

    #[test]
    fn plan_rejects_persistent_image_with_stale_patch_set() {
        let workspace = tempdir().unwrap();
        let patch_dir = workspace.path().join("os/axvisor/patches/rtthread");
        std::fs::create_dir_all(&patch_dir).unwrap();
        for name in RTTHREAD_PATCHES {
            std::fs::write(patch_dir.join(name), name.as_bytes()).unwrap();
        }
        let image = workspace
            .path()
            .join("tmp/source-cache/task123-rtthread-current/rtthread.bin");
        let metadata = PathBuf::from(format!("{}.meta.json", image.display()));
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(
            &metadata,
            br#"{"schema":1,"patch_set_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}"#,
        )
        .unwrap();

        let plan = Task123Plan::resolve(workspace.path(), &Task123Environment::default());

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
    }

    #[test]
    fn plan_builds_on_demand_without_persistent_image() {
        let plan = Task123Plan::resolve(
            Path::new("/definitely-missing-workspace"),
            &Task123Environment::default(),
        );

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
        assert!(plan.require_image_metadata);
    }

    #[test]
    fn plan_honors_native_source_for_persistent_image_discovery() {
        let workspace = tempdir().unwrap();
        let digest = write_patch_set(workspace.path());
        let native_source = workspace.path().join("custom-native-source");
        let image = native_source.join("bsp/qemu-virt64-aarch64/rtthread.bin");
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(
            PathBuf::from(format!("{}.meta.json", image.display())),
            &format!(r#"{{"schema":1,"patch_set_sha256":"{digest}"}}"#),
        )
        .unwrap();

        let plan = Task123Plan::resolve(
            workspace.path(),
            &Task123Environment {
                native_source: Some(native_source),
                ..Task123Environment::default()
            },
        );

        assert_eq!(plan.rtthread_image, Some(image.clone()));
        assert_eq!(
            plan.rtthread_image_meta,
            Some(PathBuf::from(format!("{}.meta.json", image.display())))
        );
    }

    #[test]
    fn plan_ignores_metadata_when_image_is_not_selected() {
        let plan = Task123Plan::resolve(
            Path::new("/definitely-missing-workspace"),
            &Task123Environment {
                image_meta: Some(PathBuf::from("/explicit/rtthread.meta.json")),
                ..Task123Environment::default()
            },
        );

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
    }

    #[test]
    fn patch_set_digest_matches_relative_sha256sum_manifest() {
        let workspace = tempdir().unwrap();
        write_patch_set(workspace.path());

        let patch_dir = workspace.path().join("os/axvisor/patches/rtthread");
        let manifest = std::process::Command::new("sha256sum")
            .args(RTTHREAD_PATCHES)
            .current_dir(&patch_dir)
            .output()
            .unwrap();
        assert!(manifest.status.success());

        let mut expected = sha2::Sha256::new();
        use sha2::Digest as _;
        expected.update(manifest.stdout);
        let expected = format!("{:x}", expected.finalize());

        assert_eq!(patch_set_digest(workspace.path()), expected);
    }

    fn write_patch_set(workspace_root: &Path) -> String {
        let patch_dir = workspace_root.join("os/axvisor/patches/rtthread");
        std::fs::create_dir_all(&patch_dir).unwrap();
        for name in RTTHREAD_PATCHES {
            std::fs::write(patch_dir.join(name), name.as_bytes()).unwrap();
        }
        patch_set_digest(workspace_root)
    }
}
