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
    fn resolve(workspace_root: &Path, environment: &Task123Environment) -> anyhow::Result<Self> {
        let rtthread_image = environment.image.clone().or_else(|| {
            let native_source = environment
                .native_source
                .clone()
                .unwrap_or_else(|| workspace_root.join("tmp/rt-thread-5.2.2-native-current"));
            let candidate = native_source.join("bsp/qemu-virt64-aarch64/rtthread.bin");
            let metadata = default_metadata_path(&candidate);
            (candidate.is_file() && metadata.is_file()).then_some(candidate)
        });
        let rtthread_image_meta = rtthread_image.as_ref().map(|image| {
            environment
                .image_meta
                .clone()
                .unwrap_or_else(|| default_metadata_path(image))
        });

        Ok(Self {
            runner: workspace_root.join("os/axvisor/scripts/run_task123_guest_comparison.sh"),
            rtthread_image,
            rtthread_image_meta,
            require_image_metadata: true,
        })
    }
}

fn default_metadata_path(image: &Path) -> PathBuf {
    let mut metadata = image.as_os_str().to_os_string();
    metadata.push(".meta.json");
    PathBuf::from(metadata)
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
    let plan = Task123Plan::resolve(&workspace_root, &environment)?;
    plan.execute(&args.runner_arguments())
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
    fn plan_uses_explicit_image_without_requiring_persistent_build() {
        let plan = Task123Plan::resolve(
            Path::new("/workspace"),
            &Task123Environment {
                image: Some(PathBuf::from("/explicit/rtthread.bin")),
                image_meta: Some(PathBuf::from("/explicit/rtthread.meta.json")),
                native_source: None,
            },
        )
        .unwrap();

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
        let image = workspace
            .path()
            .join("tmp/rt-thread-5.2.2-native-current/bsp/qemu-virt64-aarch64/rtthread.bin");
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(
            PathBuf::from(format!("{}.meta.json", image.display())),
            b"metadata",
        )
        .unwrap();

        let plan = Task123Plan::resolve(workspace.path(), &Task123Environment::default()).unwrap();

        assert_eq!(plan.rtthread_image, Some(image.clone()));
        assert_eq!(
            plan.rtthread_image_meta,
            Some(PathBuf::from(format!("{}.meta.json", image.display())))
        );
    }

    #[test]
    fn plan_builds_on_demand_without_persistent_image() {
        let plan = Task123Plan::resolve(
            Path::new("/definitely-missing-workspace"),
            &Task123Environment::default(),
        )
        .unwrap();

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
        assert!(plan.require_image_metadata);
    }

    #[test]
    fn plan_honors_native_source_for_persistent_image_discovery() {
        let workspace = tempdir().unwrap();
        let native_source = workspace.path().join("custom-native-source");
        let image = native_source.join("bsp/qemu-virt64-aarch64/rtthread.bin");
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::write(&image, b"image").unwrap();
        std::fs::write(
            PathBuf::from(format!("{}.meta.json", image.display())),
            b"metadata",
        )
        .unwrap();

        let plan = Task123Plan::resolve(
            workspace.path(),
            &Task123Environment {
                native_source: Some(native_source),
                ..Task123Environment::default()
            },
        )
        .unwrap();

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
        )
        .unwrap();

        assert_eq!(plan.rtthread_image, None);
        assert_eq!(plan.rtthread_image_meta, None);
    }
}
