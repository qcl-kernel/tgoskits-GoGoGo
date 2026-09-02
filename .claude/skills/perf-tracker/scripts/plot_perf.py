#!/usr/bin/env python3
"""
Generate visualization charts from the accumulated perf_metrics.csv data table.

Usage:
    plot_perf.py --csv target/perf-history/perf_metrics.csv \\
        --output-dir target/perf-history/charts \\
        [--filter-arch riscv64] [--filter-case boot] \\
        [--chart-type all]

Chart types: timeline, samples, hotspots, host_time, all
"""

import argparse
import csv
import sys
from datetime import datetime
from pathlib import Path


def load_csv(path):
    """Load CSV into a list of dict rows."""
    if not Path(path).exists():
        print(f"Error: CSV not found: {path}", file=sys.stderr)
        sys.exit(1)
    with open(path, "r", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def to_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def to_int(val, default=0):
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


def filter_rows(rows, arch=None, case=None):
    result = rows
    if arch:
        result = [r for r in result if r.get("arch") == arch]
    if case:
        result = [r for r in result if r.get("case") == case]
    return result


def make_labels(rows):
    """Create short labels for each row: case_arch shorttime."""
    labels = []
    for r in rows:
        ts = r.get("timestamp", "")
        short_ts = ""
        if ts:
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                short_ts = dt.strftime("%m-%d %H:%M")
            except ValueError:
                short_ts = ts[:16]
        label = f"{r.get('case', '?')}/{r.get('arch', '?')}"
        if short_ts:
            label += f" {short_ts}"
        labels.append(label)
    return labels


def check_matplotlib():
    try:
        import matplotlib  # noqa: F401
        return True
    except ImportError:
        print(
            "Error: matplotlib is not installed. Install it with:\n"
            "  pip install matplotlib\n"
            "  or: pip3 install matplotlib",
            file=sys.stderr,
        )
        return False


def chart_timeline(rows, labels, output_dir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(max(10, len(rows) * 1.2), 8))
    durations = [to_float(r.get("window_duration_sec")) for r in rows]
    folded = [to_int(r.get("folded_stack_lines")) for r in rows]

    ax1.bar(range(len(rows)), durations, color="steelblue", alpha=0.8)
    ax1.set_ylabel("Window Duration (sec)")
    ax1.set_title("Profiling Window Duration Across Runs")
    ax1.set_xticks(range(len(rows)))
    ax1.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)

    ax2.bar(range(len(rows)), folded, color="darkorange", alpha=0.8)
    ax2.set_ylabel("Folded Stack Lines")
    ax2.set_title("Folded Stack Entries Across Runs")
    ax2.set_xticks(range(len(rows)))
    ax2.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)

    plt.tight_layout()
    path = Path(output_dir) / "perf_timeline.png"
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  timeline chart: {path}")


def chart_samples(rows, labels, output_dir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    fig, ax = plt.subplots(figsize=(max(10, len(rows) * 1.2), 6))
    x = np.arange(len(rows))
    width = 0.35
    samples = [to_int(r.get("samples")) for r in rows]
    dropped = [to_int(r.get("dropped_samples")) for r in rows]

    ax.bar(x - width / 2, samples, width, label="Samples", color="seagreen", alpha=0.8)
    ax.bar(x + width / 2, dropped, width, label="Dropped", color="crimson", alpha=0.8)
    ax.set_ylabel("Count")
    ax.set_title("Samples vs Dropped Samples per Run")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
    ax.legend()
    ax.set_yscale("log")

    plt.tight_layout()
    path = Path(output_dir) / "perf_samples.png"
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  samples chart: {path}")


def chart_hotspots(rows, labels, output_dir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    fig, ax = plt.subplots(figsize=(max(12, len(rows) * 1.5), 7))
    x = np.arange(len(rows))
    width = 0.25
    h1 = [to_float(r.get("top_hotspot_1_percent")) for r in rows]
    h2 = [to_float(r.get("top_hotspot_2_percent")) for r in rows]
    h3 = [to_float(r.get("top_hotspot_3_percent")) for r in rows]

    ax.bar(x - width, h1, width, label="Hotspot #1", color="royalblue", alpha=0.8)
    ax.bar(x, h2, width, label="Hotspot #2", color="orange", alpha=0.8)
    ax.bar(x + width, h3, width, label="Hotspot #3", color="green", alpha=0.8)

    for i, r in enumerate(rows):
        for offset, idx in [(-width, 1), (0, 2), (width, 3)]:
            name = r.get(f"top_hotspot_{idx}", "")
            pct = to_float(r.get(f"top_hotspot_{idx}_percent"))
            if name:
                short = name[:25] + "..." if len(name) > 25 else name
                ax.text(i + offset, pct + 0.5, short, ha="center", va="bottom", fontsize=6, rotation=90)

    ax.set_ylabel("Self Percentage (%)")
    ax.set_title("Top-3 Hotspots per Run")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
    ax.legend()

    plt.tight_layout()
    path = Path(output_dir) / "perf_hotspots.png"
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  hotspots chart: {path}")


def chart_host_time(rows, labels, output_dir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(max(10, len(rows) * 1.2), 8))
    user = [to_float(r.get("host_user_sec")) for r in rows]
    system = [to_float(r.get("host_system_sec")) for r in rows]
    cpu_pct = [to_float(r.get("host_cpu_percent")) for r in rows]

    ax1.plot(range(len(rows)), user, marker="o", label="User time (s)", color="steelblue")
    ax1.plot(range(len(rows)), system, marker="s", label="System time (s)", color="darkorange")
    ax1.set_ylabel("Seconds")
    ax1.set_title("Host CPU Time Across Runs")
    ax1.set_xticks(range(len(rows)))
    ax1.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
    ax1.legend()

    ax2.bar(range(len(rows)), cpu_pct, color="seagreen", alpha=0.8)
    ax2.set_ylabel("CPU Percent (%)")
    ax2.set_title("Host CPU Utilization Across Runs")
    ax2.set_xticks(range(len(rows)))
    ax2.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)

    plt.tight_layout()
    path = Path(output_dir) / "perf_host_time.png"
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  host_time chart: {path}")


def main():
    parser = argparse.ArgumentParser(
        description="Plot performance metrics from CSV data table"
    )
    parser.add_argument("--csv", required=True, help="Path to perf_metrics.csv")
    parser.add_argument("--output-dir", required=True, help="Directory to save charts")
    parser.add_argument("--filter-arch", default=None, help="Filter by architecture")
    parser.add_argument("--filter-case", default=None, help="Filter by case name")
    parser.add_argument(
        "--chart-type",
        default="all",
        choices=["timeline", "samples", "hotspots", "host_time", "all"],
    )
    args = parser.parse_args()

    rows = load_csv(args.csv)
    rows = filter_rows(rows, arch=args.filter_arch, case=args.filter_case)
    if not rows:
        print("No rows match the given filters. Nothing to plot.", file=sys.stderr)
        return 1

    if not check_matplotlib():
        return 1

    labels = make_labels(rows)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Plotting {len(rows)} runs...")
    ct = args.chart_type
    if ct in ("timeline", "all"):
        chart_timeline(rows, labels, output_dir)
    if ct in ("samples", "all"):
        chart_samples(rows, labels, output_dir)
    if ct in ("hotspots", "all"):
        chart_hotspots(rows, labels, output_dir)
    if ct in ("host_time", "all"):
        chart_host_time(rows, labels, output_dir)

    print(f"Charts saved to {output_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
