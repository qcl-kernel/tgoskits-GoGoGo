---
name: perf-tracker
description: Record and visualize StarryOS qperf performance metrics across multiple profiling runs. Use this skill automatically after every `cargo xtask starry perf ...` invocation to extract key metrics (arch, frequency, samples, dropped_samples, window_duration, folded_stack_lines, host_time, hotspots) into a structured CSV data table. Use it also when the user asks to plot, chart, compare, or visualize performance trends over time. The skill appends one row per run to `target/perf-history/perf_metrics.csv` and can generate matplotlib charts (timeline, bar comparison, hotspot breakdown) as PNG files on demand.
---

# Perf Tracker

This skill automatically records performance metrics after every StarryOS qperf profiling run, stores them in a structured CSV data table, and generates visualization charts on demand.

## When to Use

- After every `cargo xtask starry perf ...` or `cargo starry perf ...` command completes successfully, invoke the record workflow to append a new row to the data table.
- When the user asks to plot, chart, compare, or visualize performance trends, invoke the plot workflow.

## Record Workflow (after each perf run)

1. Locate the latest qperf output directory. If the command was run with default paths, this is `target/qperf/<case>/perf/<arch>/latest/`. If `--out` or `--output-dir` was used, check that path instead.
2. Read `summary.txt` from the qperf output directory to extract performance metrics.
3. If `report.json` exists, read it for additional structured metrics.
4. If `hotspots.csv` exists, read the top 5 hotspots.
5. Append one row to the data table at `target/perf-history/perf_metrics.csv` using the record script:

```bash
python3 <skill-path>/scripts/record_perf.py record \
  --repo-root /path/to/tgoskits \
  --summary  /path/to/qperf-output/summary.txt \
  [--report-json /path/to/qperf-output/../report.json] \
  [--hotspots-csv /path/to/qperf-output/../hotspots.csv]
```

### Key Metrics Recorded

| Column | Source | Description |
|---|---|---|
| timestamp | system time | ISO-8601 recording time |
| arch | summary.txt `arch =` | Target architecture |
| case | summary.txt `case =` | qperf case name |
| build_profile | summary.txt `build_profile =` | debug or release |
| freq_hz | summary.txt `frequency_hz =` | Sampling frequency |
| sampling_mode | summary.txt `sampling_mode =` | tb or insn |
| callchain_mode | summary.txt `callchain_mode =` | leaf or fp |
| smp | command arg or 1 | Number of CPUs |
| samples | plugin_summary `samples =` | Total samples collected |
| dropped_samples | plugin_summary `dropped_samples =` | Dropped samples |
| sample_failures | plugin_summary `sample_failures =` | Failed samples |
| folded_stack_lines | summary.txt `folded_stack_lines =` | Folded stack entries |
| window_enabled | summary.txt `window_enabled =` | Whether windowing was used |
| window_duration_sec | summary.txt `window_duration_sec =` | Profiling window duration |
| host_time_sec | host_time output `Elapsed time:` | Host wall-clock seconds |
| host_user_sec | host_time output `User time:` | Host user CPU seconds |
| host_system_sec | host_time output `System time:` | Host system CPU seconds |
| host_cpu_percent | host_time output `Percent of CPU` | Host CPU utilization % |
| top_hotspot_1 | hotspots.csv row 1 | Top hotspot function |
| top_hotspot_1_percent | hotspots.csv row 1 | Top hotspot percentage |
| top_hotspot_2 | hotspots.csv row 2 | Second hotspot function |
| top_hotspot_2_percent | hotspots.csv row 2 | Second hotspot percentage |
| top_hotspot_3 | hotspots.csv row 3 | Third hotspot function |
| top_hotspot_3_percent | hotspots.csv row 3 | Third hotspot percentage |
| qperf_dir | summary path parent | Path to the qperf output directory |

### Automatic Invocation

After any `cargo starry perf` or `cargo xtask starry perf` run that produces a `summary.txt`, immediately run the record script without waiting for the user to ask. Announce in commentary that metrics are being recorded.

## Plot Workflow

When the user asks to visualize or compare performance data, use the plot script:

```bash
python3 <skill-path>/scripts/plot_perf.py \
  --csv target/perf-history/perf_metrics.csv \
  --output-dir target/perf-history/charts \
  [--filter-arch riscv64] \
  [--filter-case boot] \
  [--chart-type all]
```

### Chart Types

- `timeline`: plots `window_duration_sec` and `folded_stack_lines` across all recorded runs (x = timestamp).
- `samples`: bar chart of `samples` vs `dropped_samples` per run.
- `hotspots`: grouped bar chart of top-3 hotspot percentages for each run.
- `host_time`: line chart of `host_user_sec`, `host_system_sec`, `host_cpu_percent` over time.
- `all` (default): generates all of the above.

Each chart is saved as a PNG in the output directory. After generating, display the images to the user.

## Resources

- `scripts/record_perf.py` --- extract metrics from qperf output and append to CSV.
- `scripts/plot_perf.py` --- generate matplotlib charts from the accumulated CSV.
- `references/metrics_reference.md` --- full column schema and summary.txt field mapping.
