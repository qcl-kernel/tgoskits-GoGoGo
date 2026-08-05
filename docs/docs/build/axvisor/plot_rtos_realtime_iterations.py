#!/usr/bin/env python3
"""Plot Axvisor RTOS real-time benchmark iterations from the companion CSV."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Callable, Iterable, Mapping, Optional, Sequence

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.axes import Axes
from matplotlib.lines import Line2D
from matplotlib.ticker import MaxNLocator


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CSV = SCRIPT_DIR / "rtos-realtime-iterations.csv"
DEFAULT_OUTPUT = SCRIPT_DIR / "rtos-realtime-iterations.png"

SINGLE_GUEST = "Single guest"
THREE_GUEST_NETWORK = "Three guest network"
ONE_LINUX_ONE_RTOS = "One Linux + one RTOS network"
SCENARIOS = (SINGLE_GUEST, ONE_LINUX_ONE_RTOS, THREE_GUEST_NETWORK)
SCENARIO_COLORS = {
    SINGLE_GUEST: "#2c6e91",
    ONE_LINUX_ONE_RTOS: "#4c956c",
    THREE_GUEST_NETWORK: "#c24e3e",
}
SCENARIO_LINESTYLES = {
    SINGLE_GUEST: "-",
    ONE_LINUX_ONE_RTOS: ":",
    THREE_GUEST_NETWORK: "--",
}
BASELINE_COLOR = "#f26b38"


def parse_number(value: object) -> Optional[float]:
    """Return a numeric CSV value, keeping NA and empty values missing."""
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() in {"na", "nan", "none"}:
        return None
    return float(text)


def completion_rate(row: Mapping[str, object]) -> Optional[float]:
    """Return callback completion percentage, or None for an undefined run."""
    callbacks = parse_number(row.get("callbacks"))
    expected = parse_number(row.get("expected_callbacks"))
    if callbacks is None or expected is None or expected <= 0:
        return None
    return callbacks / expected * 100.0


def scenario_for(workload: str) -> str:
    """Map CSV workload names to the two experiment scenarios."""
    if workload.startswith("three_guest_network"):
        return THREE_GUEST_NETWORK
    if workload.startswith("one_linux_one_rtos"):
        return ONE_LINUX_ONE_RTOS
    if workload.startswith("single_guest"):
        return SINGLE_GUEST
    raise ValueError(f"Unsupported workload: {workload}")


def load_rows(csv_path: Path) -> list[dict[str, str]]:
    """Read benchmark rows without changing the source CSV."""
    with csv_path.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    required = {"iteration", "workload", "callbacks", "expected_callbacks"}
    missing = required.difference(rows[0] if rows else ())
    if missing:
        raise ValueError(f"CSV is missing required columns: {', '.join(sorted(missing))}")
    return rows


def _valid_points(
    rows: Sequence[Mapping[str, str]],
    scenario: str,
    value_fn: Callable[[Mapping[str, str]], Optional[float]],
) -> list[tuple[int, float]]:
    points = []
    for row in rows:
        if scenario_for(row["workload"]) != scenario:
            continue
        value = value_fn(row)
        if value is not None:
            points.append((int(row["iteration"]), value))
    return points


def _plot_contiguous_segments(
    ax: Axes,
    points: Sequence[tuple[int, float]],
    *,
    color: str,
    linestyle: str,
    label: str,
    marker: str = "o",
    linewidth: float = 2.0,
) -> Optional[Line2D]:
    """Plot only adjacent measured iterations, leaving gaps visible."""
    if not points:
        return None

    handle: Optional[Line2D] = None
    segment: list[tuple[int, float]] = []
    segments: list[list[tuple[int, float]]] = []
    for point in points:
        if segment and point[0] != segment[-1][0] + 1:
            segments.append(segment)
            segment = []
        segment.append(point)
    if segment:
        segments.append(segment)

    for segment in segments:
        line, = ax.plot(
            [point[0] for point in segment],
            [point[1] for point in segment],
            color=color,
            linestyle=linestyle,
            marker=marker,
            markersize=5.5,
            linewidth=linewidth,
            label=label if handle is None else "_nolegend_",
            zorder=3,
        )
        if handle is None:
            handle = line
    return handle


def _baseline_row(rows: Sequence[Mapping[str, str]]) -> Optional[Mapping[str, str]]:
    return next((row for row in rows if row.get("revision") == "baseline"), None)


def _mark_baseline(ax: Axes) -> None:
    """Make iteration 0 easy to identify without inventing values for NA metrics."""
    ax.axvspan(-0.45, 0.45, color="#fff0e7", zorder=0)
    ax.axvline(0, color=BASELINE_COLOR, linestyle=":", linewidth=1.4, zorder=1)


def _add_baseline_point(
    ax: Axes,
    baseline: Optional[Mapping[str, str]],
    value_fn: Callable[[Mapping[str, str]], Optional[float]],
) -> None:
    if baseline is None:
        return
    value = value_fn(baseline)
    if value is not None:
        ax.scatter(
            [0],
            [value],
            s=135,
            marker="*",
            color=BASELINE_COLOR,
            edgecolors="#8e321e",
            linewidths=0.7,
            zorder=6,
        )


def _metric_value(field: str) -> Callable[[Mapping[str, str]], Optional[float]]:
    return lambda row: parse_number(row.get(field))


def _metric_ns_to_us(field: str) -> Callable[[Mapping[str, str]], Optional[float]]:
    def value(row: Mapping[str, str]) -> Optional[float]:
        raw = parse_number(row.get(field))
        return None if raw is None else raw / 1000.0

    return value


def _style_axis(ax: Axes, title: str, ylabel: str) -> None:
    ax.set_title(title, loc="left", fontsize=12, fontweight="bold", pad=9)
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color="#d9dee3", linewidth=0.8, alpha=0.8)
    ax.grid(axis="x", visible=False)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#9aa4ad")
    ax.spines["bottom"].set_color("#9aa4ad")
    ax.tick_params(colors="#4f5961")


def plot_rtos_realtime_iterations(csv_path: Path = DEFAULT_CSV, output_path: Path = DEFAULT_OUTPUT) -> Path:
    """Generate the reproducible RTOS iteration figure and return its path."""
    rows = load_rows(csv_path)
    if not rows:
        raise ValueError("CSV contains no benchmark rows")

    iterations = [int(row["iteration"]) for row in rows]
    max_iteration = max(iterations)
    baseline = _baseline_row(rows)

    plt.rcParams.update({
        "font.family": "DejaVu Sans",
        "axes.titlesize": 12,
        "axes.labelsize": 10,
        "xtick.labelsize": 9,
        "ytick.labelsize": 9,
    })
    fig, axes = plt.subplots(
        2,
        2,
        figsize=(12, 7.2),
        sharex=True,
        gridspec_kw={"hspace": 0.34, "wspace": 0.24},
    )
    fig.subplots_adjust(
        left=0.085,
        right=0.985,
        bottom=0.105,
        top=0.835,
        hspace=0.48,
        wspace=0.24,
    )
    fig.patch.set_facecolor("white")
    fig.suptitle(
        "Axvisor RTOS real-time iterations",
        x=0.06,
        y=0.985,
        ha="left",
        fontsize=18,
        fontweight="bold",
        color="#20252a",
    )
    fig.text(
        0.06,
        0.925,
        "Timer/callback completion, tail latency, and deadline misses by measured iteration",
        ha="left",
        fontsize=10,
        color="#68727b",
    )

    for ax in axes.flat:
        _style_axis(ax, "", "")
        _mark_baseline(ax)
        ax.set_xlim(-0.45, max_iteration + 0.45)
        ax.xaxis.set_major_locator(MaxNLocator(integer=True, nbins=12))
        ax.set_xlabel("Iteration #")
    for ax in axes[0]:
        ax.set_xlabel("")

    completion_ax, tail_ax = axes[0]
    max_ax, miss_ax = axes[1]

    completion_fn = completion_rate
    _style_axis(completion_ax, "Timer/callback completion", "Completed / expected (%)")
    completion_ax.set_ylim(-2, 105)
    completion_ax.set_yticks([0, 25, 50, 75, 100])
    if baseline is not None:
        completion_ax.annotate(
            "baseline\n(before fix)",
            xy=(0, 0),
            xycoords="data",
            xytext=(12, 12),
            textcoords="offset points",
            color=BASELINE_COLOR,
            fontsize=9,
            fontweight="bold",
            ha="left",
            va="bottom",
        )

    for scenario in SCENARIOS:
        _plot_contiguous_segments(
            completion_ax,
            _valid_points(rows, scenario, completion_fn),
            color=SCENARIO_COLORS[scenario],
            linestyle=SCENARIO_LINESTYLES[scenario],
            label=scenario,
        )
    _add_baseline_point(completion_ax, baseline, completion_fn)
    completion_ax.legend(loc="lower right", frameon=False, fontsize=9)

    _style_axis(tail_ax, "p99/p99.9/p99.99 latency (symlog)", "Latency (us)")
    tail_values = []
    for row in rows:
        for field, scale in (("p99_us", 1.0), ("p99_9_us", 1.0), ("p99_99_ns", 0.001)):
            value = parse_number(row.get(field))
            if value is not None:
                tail_values.append(value * scale)
    tail_limit = max(20.0, max(tail_values, default=0.0) * 1.15)
    tail_ax.set_yscale("symlog", linthresh=1.0)
    tail_ax.set_ylim(0, tail_limit)
    tail_ax.set_yticks([tick for tick in (0, 1, 10, 100, 1000, 10000)
                        if tick <= tail_limit])
    for field, label, linestyle, value_fn in (
        ("p99_us", "p99", "-", _metric_value("p99_us")),
        ("p99_9_us", "p99.9", "--", _metric_value("p99_9_us")),
        ("p99_99_ns", "p99.99", "-.", _metric_ns_to_us("p99_99_ns")),
    ):
        for scenario in SCENARIOS:
            _plot_contiguous_segments(
                tail_ax,
                _valid_points(rows, scenario, value_fn),
                color=SCENARIO_COLORS[scenario],
                linestyle=linestyle,
                label=f"{scenario} {label}",
            )
    _add_baseline_point(tail_ax, baseline, value_fn)
    tail_ax.legend(
        loc="upper left",
        bbox_to_anchor=(1.02, 1.0),
        frameon=False,
        fontsize=8,
        ncol=1,
        borderaxespad=0,
    )

    max_fn = _metric_value("max_us")
    _style_axis(max_ax, "Maximum observed latency", "Latency (us)")
    max_values = [
        value
        for row in rows
        for value in (parse_number(row.get("max_us")),)
        if value is not None
    ]
    max_limit = max(2100.0, max(max_values, default=0.0) * 1.15)
    max_ax.set_yscale("symlog", linthresh=100.0)
    max_ax.set_ylim(0, max_limit)
    max_ax.set_yticks([tick for tick in (0, 10, 100, 1000, 10000)
                       if tick <= max_limit])
    for scenario in SCENARIOS:
        _plot_contiguous_segments(
            max_ax,
            _valid_points(rows, scenario, max_fn),
            color=SCENARIO_COLORS[scenario],
            linestyle=SCENARIO_LINESTYLES[scenario],
            label=scenario,
        )
    _add_baseline_point(max_ax, baseline, max_fn)
    max_ax.legend(loc="upper right", frameon=False, fontsize=9)

    _style_axis(miss_ax, "Deadline misses", "Count")
    miss_fields = (
        ("miss_gt100us", ">100 us", "#2c6e91"),
        ("miss_gt500us", ">500 us", "#d18b36"),
        ("miss_gt1ms", ">1 ms", "#b33f38"),
    )
    max_miss = 0.0
    for field, threshold, metric_color in miss_fields:
        value_fn = _metric_value(field)
        for scenario in SCENARIOS:
            points = _valid_points(rows, scenario, value_fn)
            if points:
                max_miss = max(max_miss, max(value for _, value in points))
            _plot_contiguous_segments(
                miss_ax,
                points,
                color=metric_color,
                linestyle=SCENARIO_LINESTYLES[scenario],
                label=f"{scenario} {threshold}",
                marker="o",
                linewidth=1.8,
            )
            _add_baseline_point(miss_ax, baseline, value_fn)
    miss_ax.set_ylim(-max(0.5, max_miss * 0.08), max(1.0, max_miss * 1.28))
    miss_ax.legend(
        loc="upper left",
        bbox_to_anchor=(1.02, 1.0),
        frameon=False,
        fontsize=7.5,
        ncol=1,
        borderaxespad=0,
    )

    fig.text(
        0.06,
        0.025,
        "NA measurements are omitted and never interpreted as zero.  Star = repair-before-fix baseline.",
        fontsize=8.5,
        color="#7b858d",
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV, help="Input iteration CSV")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output PNG path")
    args = parser.parse_args()
    output = plot_rtos_realtime_iterations(args.csv, args.output)
    print(f"Wrote {output.resolve()}")


if __name__ == "__main__":
    main()
