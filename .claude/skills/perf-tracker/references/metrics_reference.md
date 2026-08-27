# Metrics Reference

## CSV Schema

The data table `target/perf-history/perf_metrics.csv` has the following columns:

| Column | Type | Source Field | Notes |
|---|---|---|---|
| timestamp | string (ISO-8601) | system clock | UTC recording time |
| arch | string | summary.txt `arch` | e.g. riscv64, aarch64, x86_64 |
| case | string | summary.txt `case` | qperf case name |
| build_profile | string | summary.txt `build_profile` | debug or release |
| freq_hz | int | summary.txt `frequency_hz` | Sampling frequency in Hz |
| sampling_mode | string | summary.txt `sampling_mode` | tb (translation block) or insn (instruction) |
| callchain_mode | string | summary.txt `callchain_mode` | leaf or fp |
| smp | int | CLI arg or blank | Number of CPUs, if known |
| samples | int | plugin_summary `samples` | Total samples collected |
| dropped_samples | int | plugin_summary `dropped_samples` | Samples dropped due to full queue |
| sample_failures | int | plugin_summary `sample_failures` | Samples that failed to enqueue |
| folded_stack_lines | int | summary.txt `folded_stack_lines` | Lines in the folded stack output |
| window_enabled | bool | summary.txt `window_enabled` | Whether profiling window was used |
| window_duration_sec | float | summary.txt `window_duration_sec` | Duration of profiling window |
| window_start_time | float | summary.txt `window_start_time` | Window start (relative seconds) |
| window_stop_time | float | summary.txt `window_stop_time` | Window stop (relative seconds) |
| host_time_sec | float | qemu.time.txt `Elapsed time` | Host wall-clock seconds |
| host_user_sec | float | qemu.time.txt `User time` | Host user CPU seconds |
| host_system_sec | float | qemu.time.txt `System time` | Host system CPU seconds |
| host_cpu_percent | float | qemu.time.txt `Percent of CPU` | Host CPU utilization percentage |
| top_hotspot_1 | string | hotspots.csv row 1 symbol | Hottest function |
| top_hotspot_1_percent | float | hotspots.csv row 1 percent | Self percentage |
| top_hotspot_2 | string | hotspots.csv row 2 symbol | Second hottest function |
| top_hotspot_2_percent | float | hotspots.csv row 2 percent | Self percentage |
| top_hotspot_3 | string | hotspots.csv row 3 symbol | Third hottest function |
| top_hotspot_3_percent | float | hotspots.csv row 3 percent | Self percentage |
| qperf_dir | string | summary.txt parent dir | Path to the qperf output directory |

## summary.txt Field Mapping

The qperf `summary.txt` file is a `key = value` text file. The plugin summary section
(starting with `[plugin_summary]`) contains runtime stats from the qperf plugin.

Key fields used by the record script:

```
arch = riscv64
case = boot
build_profile = release
frequency_hz = 99
sampling_mode = tb
callchain_mode = leaf
folded_stack_lines = 1234
window_enabled = true
window_duration_sec = 3.456789012

[plugin_summary]
samples = 50000
dropped_samples = 12
sample_failures = 0
```

## Auto-discovery

The record script auto-discovers these files relative to `summary.txt`:

- `report.json` in the parent of the qperf directory (work_dir)
- `hotspots.csv` in the parent of the qperf directory (work_dir)
- `qemu.time.txt` in the qperf directory itself

## Chart Types

| Chart | File | Description |
|---|---|---|
| timeline | perf_timeline.png | Window duration and folded stack lines across runs |
| samples | perf_samples.png | Log-scale bar chart of collected vs dropped samples |
| hotspots | perf_hotspots.png | Grouped bar chart of top-3 hotspot percentages |
| host_time | perf_host_time.png | Host user/system CPU time and utilization percentage |
