use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

use clap::{Args, ValueEnum};
use serde_json::{Map, Value, json};

use super::Axvisor;

#[derive(Args, Default)]
pub struct Task123Args {
    /// Run the five-minute diagnostic comparison
    #[arg(long, conflicts_with_all = ["full", "realtime_suite"])]
    pub quick: bool,

    /// Run the one-hour formal comparison
    #[arg(long, conflicts_with_all = ["quick", "realtime_suite"])]
    pub full: bool,

    /// Run the RTBench realtime suite instead of stability-only comparison
    #[arg(long = "realtime-suite", conflicts_with_all = ["quick", "full"])]
    pub realtime_suite: bool,

    /// Select one RTOS for a single or two-guest comparison
    #[arg(long, value_enum)]
    pub rtos: Option<Task123Rtos>,

    /// Select one application guest for a single-combination run
    #[arg(long, value_enum)]
    pub app_guest: Option<Task123AppGuest>,

    /// Run all RTOS/application-guest combinations
    #[arg(long, value_name = "all", value_parser = ["all"])]
    pub matrix: Option<String>,

    /// Number of RTBench samples for --realtime-suite
    #[arg(long)]
    pub rtbench_samples: Option<u32>,

    /// Number of Task 2 requests per payload
    #[arg(long)]
    pub task2_count: Option<u32>,

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

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum Task123Rtos {
    Rtthread,
    Zephyr,
}

impl Task123Rtos {
    fn as_str(self) -> &'static str {
        match self {
            Self::Rtthread => "rtthread",
            Self::Zephyr => "zephyr",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum Task123AppGuest {
    Linux,
    Starryos,
}

impl Task123AppGuest {
    fn as_str(self) -> &'static str {
        match self {
            Self::Linux => "linux",
            Self::Starryos => "starryos",
        }
    }
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

const RTTHREAD_PATCHES: [&str; 11] = [
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
    "0011-virtio-net-rx-dma-cache.patch",
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
        assert!(
            self.matrix.is_none() || (self.rtos.is_none() && self.app_guest.is_none()),
            "--matrix all cannot be combined with --rtos or --app-guest"
        );
        assert!(
            self.rtbench_samples.is_none() || self.realtime_suite,
            "--rtbench-samples requires --realtime-suite"
        );
        assert!(
            self.task2_count.is_none_or(|count| count > 0),
            "--task2-count must be greater than zero"
        );
        let mut arguments = Vec::new();
        if self.realtime_suite {
            arguments.push("--realtime-suite".to_string());
        } else if self.full {
            arguments.push("--full".to_string());
        } else {
            arguments.push("--quick".to_string());
        }
        if let Some(matrix) = &self.matrix {
            arguments.push("--matrix".to_string());
            arguments.push(matrix.clone());
        } else {
            if let Some(rtos) = self.rtos {
                arguments.push("--rtos".to_string());
                arguments.push(rtos.as_str().to_string());
            }
            if let Some(app_guest) = self.app_guest {
                arguments.push("--app-guest".to_string());
                arguments.push(app_guest.as_str().to_string());
            }
        }
        if let Some(samples) = self.rtbench_samples {
            arguments.push("--rtbench-samples".to_string());
            arguments.push(samples.to_string());
        }
        if let Some(count) = self.task2_count {
            arguments.push("--task2-count".to_string());
            arguments.push(count.to_string());
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
    anyhow::ensure!(
        args.matrix.is_none() || (args.rtos.is_none() && args.app_guest.is_none()),
        "--matrix all cannot be combined with --rtos or --app-guest"
    );
    anyhow::ensure!(
        args.rtbench_samples.is_none() || args.realtime_suite,
        "--rtbench-samples requires --realtime-suite"
    );
    anyhow::ensure!(
        args.task2_count.is_none_or(|count| count > 0),
        "--task2-count must be greater than zero"
    );
    let workspace_root = axvisor.app.workspace_root().to_path_buf();
    let environment = Task123Environment::from_process();
    let plan = Task123Plan::resolve(&workspace_root, &environment);
    let output = args
        .output
        .clone()
        .unwrap_or_else(|| default_output_path(&workspace_root));
    let output = if output.is_absolute() {
        output
    } else {
        workspace_root.join(output)
    };
    prepare_output_parent(&workspace_root, &output)?;
    let mut runner_arguments = args.runner_arguments();
    if args.output.is_none() {
        runner_arguments.push("--output".to_string());
        runner_arguments.push(output.display().to_string());
    }
    plan.execute(&runner_arguments)?;
    if args.matrix.as_deref() == Some("all") {
        write_matrix_report(&output, &args)?;
    }
    Ok(())
}

fn default_output_path(workspace_root: &Path) -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    workspace_root.join(format!("tmp/task123-xtask-matrix-{timestamp}"))
}

fn write_matrix_report(output: &Path, args: &Task123Args) -> anyhow::Result<()> {
    let mut combinations = Vec::new();
    for rtos in ["rtthread", "zephyr"] {
        for app_guest in ["linux", "starryos"] {
            let run = output.join(format!("{rtos}-{app_guest}"));
            let summary_path = run.join("summary.json");
            let summary: Value = serde_json::from_str(&fs::read_to_string(&summary_path)?)?;
            let app_log = run.join(format!("{app_guest}.log"));
            let rtos_log = run.join(format!("{rtos}.log"));
            let task3 = summary
                .get("success_rate")
                .and_then(Value::as_f64)
                .map(|success_rate| {
                    json!({
                        "success_rate": success_rate,
                        "requests": summary.get("requests"),
                        "successes": summary.get("successes"),
                        "round_trip_us": summary.get("round_trip_us"),
                        "inference_us": summary.get("inference_us"),
                        "rtos_processing_us": summary.get("rtos_processing_us"),
                        "transport_retries": summary.get("transport_retries"),
                        "timeouts": summary.get("timeouts"),
                        "duplicates": summary.get("duplicates"),
                        "reconnects": summary.get("reconnects"),
                        "recoveries": summary.get("recoveries"),
                        "injected_drops": summary.get("injected_drops"),
                        "effective_payload_bytes_per_second":
                            summary.get("effective_payload_bytes_per_second"),
                        "classification": summary.get("classification"),
                    })
                })
                .unwrap_or_else(|| json!({"error": "missing success_rate"}));
            combinations.push(json!({
                "rtos": rtos,
                "app_guest": app_guest,
                "task2": marker_status(&app_log, "TASK2_"),
                "task3": marker_status(&app_log, "TASK3_"),
                "task123": marker_status(&app_log, "TASK123_"),
                "task3_summary": task3,
                "rtbench": parse_rtbench_log(&rtos_log),
                "artifacts": {
                    "run": run,
                    "summary": summary_path,
                    "app_log": app_log,
                    "rtos_log": rtos_log,
                }
            }));
        }
    }

    let report = json!({
        "schema": 1,
        "mode": if args.realtime_suite { "realtime-suite" } else if args.full { "full" } else { "quick" },
        "matrix": "all",
        "combinations": combinations,
    });
    fs::write(
        output.join("matrix-summary.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    fs::write(
        output.join("matrix-report.md"),
        render_matrix_report(&report),
    )?;
    println!(
        "MATRIX_SUMMARY {}",
        output.join("matrix-summary.json").display()
    );
    println!(
        "MATRIX_REPORT {}",
        output.join("matrix-report.md").display()
    );
    Ok(())
}

fn marker_status(path: &Path, marker: &str) -> &'static str {
    let Ok(contents) = fs::read_to_string(path) else {
        return "MISSING";
    };
    if contents
        .lines()
        .any(|line| line.contains(marker) && line.contains("status=PASS"))
    {
        "PASS"
    } else {
        "FAIL_OR_MISSING"
    }
}

fn parse_rtbench_log(path: &Path) -> Value {
    let Ok(contents) = fs::read_to_string(path) else {
        return json!({});
    };
    let mut metrics = Map::new();
    for line in contents
        .lines()
        .filter(|line| line.contains("RTBENCH metric="))
    {
        let fields = line
            .split_whitespace()
            .filter_map(|field| field.split_once('='))
            .collect::<BTreeMap<_, _>>();
        let Some(metric) = fields.get("metric") else {
            continue;
        };
        let mut values = Map::new();
        for field in [
            "p50_ns",
            "p95_ns",
            "p99_ns",
            "p99_9_ns",
            "max_ns",
            "mean_ns",
            "p50_cycles",
            "p95_cycles",
            "p99_cycles",
            "p99_9_cycles",
            "max_cycles",
            "mean_cycles",
            "p50_instructions",
            "p95_instructions",
            "p99_instructions",
            "p99_9_instructions",
            "max_instructions",
            "mean_instructions",
            "missing",
        ] {
            if let Some(value) = fields
                .get(field)
                .and_then(|value| value.parse::<u64>().ok())
            {
                values.insert(field.to_string(), Value::from(value));
            }
        }
        metrics.insert((*metric).to_string(), Value::Object(values));
    }
    Value::Object(metrics)
}

fn render_matrix_report(report: &Value) -> String {
    let mut output = String::from(concat!(
        "# Task123 cargo xtask RTOS 矩阵报告\n\n",
        "| RTOS | 应用客户机 | Task 2 | Task 3 | Task 123 | 成功率 | Task 3 超时 | Task 3 重传 | \
         RTT p50 (us) | RTBench stability jitter p99 (ns) | p99 cycles | p99 instructions |\n",
        "|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|\n",
    ));
    for combination in report
        .get("combinations")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let text = |path: &[&str]| {
            path.iter()
                .try_fold(combination, |value, key| value.get(*key))
                .and_then(Value::as_str)
                .unwrap_or("-")
                .to_string()
        };
        let number = |path: &[&str]| {
            path.iter()
                .try_fold(combination, |value, key| value.get(*key))
                .map(format_value)
                .unwrap_or_else(|| "-".to_string())
        };
        output.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            text(&["rtos"]),
            text(&["app_guest"]),
            text(&["task2"]),
            text(&["task3"]),
            text(&["task123"]),
            number(&["task3_summary", "success_rate"]),
            number(&["task3_summary", "timeouts"]),
            number(&["task3_summary", "transport_retries"]),
            number(&["task3_summary", "round_trip_us", "p50"]),
            number(&["rtbench", "stability_jitter", "p99_ns"]),
            number(&["rtbench", "stability_jitter", "p99_cycles"]),
            number(&["rtbench", "stability_jitter", "p99_instructions"]),
        ));
    }
    output.push_str(
        "\n数据来自各组合的 `summary.json`、客户机日志和 RTOS RTBench 日志。QEMU TCG \
         的时间数据不等价于物理板实时性上界。\n",
    );
    output
}

fn format_value(value: &Value) -> String {
    match value {
        Value::Number(number) => number.to_string(),
        Value::String(text) => text.clone(),
        Value::Null => "-".to_string(),
        _ => "-".to_string(),
    }
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
    fn runner_arguments_forward_matrix_selection() {
        let args = Task123Args {
            quick: true,
            matrix: Some("all".to_string()),
            ..Task123Args::default()
        };

        assert_eq!(args.runner_arguments(), vec!["--quick", "--matrix", "all"]);
    }

    #[test]
    fn runner_arguments_forward_realtime_suite_and_single_combination() {
        let args = Task123Args {
            realtime_suite: true,
            rtos: Some(Task123Rtos::Zephyr),
            app_guest: Some(Task123AppGuest::Starryos),
            rtbench_samples: Some(1000),
            task2_count: Some(10),
            ..Task123Args::default()
        };

        assert_eq!(
            args.runner_arguments(),
            vec![
                "--realtime-suite",
                "--rtos",
                "zephyr",
                "--app-guest",
                "starryos",
                "--rtbench-samples",
                "1000",
                "--task2-count",
                "10"
            ]
        );
    }

    #[test]
    fn matrix_report_renders_stability_jitter_counters() {
        let report = json!({
            "combinations": [{
                "rtos": "rtthread",
                "app_guest": "linux",
                "task2": "PASS",
                "task3": "PASS",
                "task123": "PASS",
                "task3_summary": {
                    "success_rate": 1.0,
                    "timeouts": 7,
                    "transport_retries": 104,
                    "round_trip_us": {"p50": 42}
                },
                "rtbench": {
                    "stability_jitter": {
                        "p99_ns": 123,
                        "p99_cycles": 456,
                        "p99_instructions": 789
                    }
                }
            }]
        });

        let rendered = render_matrix_report(&report);

        assert!(rendered.contains("| 123 | 456 | 789 |"));
        assert!(rendered.contains("| 7 | 104 |"));
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
