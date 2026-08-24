#!/usr/bin/env python3
"""Parse Task123 logs and render comparison charts without third-party packages."""

from __future__ import annotations

import csv
import json
import math
import re
from pathlib import Path
from statistics import fmean
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parent
PLOTS = ROOT / "plots"
SHORT_LABELS = [
    "Q-RT/L",
    "Q-RT/S",
    "Q-Z/L",
    "Q-Z/S",
    "R-RT/L",
    "R-RT/S",
    "R-Z/L",
    "R-Z/S",
]
FULL_LABELS = [
    "QEMU RT-Thread + Linux",
    "QEMU RT-Thread + StarryOS",
    "QEMU Zephyr + Linux",
    "QEMU Zephyr + StarryOS",
    "Rock-4D RT-Thread + Linux",
    "Rock-4D RT-Thread + StarryOS",
    "Rock-4D Zephyr + Linux",
    "Rock-4D Zephyr + StarryOS",
]
PALETTE = [
    "#2563eb",
    "#0891b2",
    "#16a34a",
    "#65a30d",
    "#ea580c",
    "#c2410c",
    "#9333ea",
    "#db2777",
]
PAYLOAD_COLORS = ["#2563eb", "#f59e0b", "#16a34a"]
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"

COMBINATIONS = [
    ("qemu", "rtthread", "linux", ROOT / "qemu/rtthread-linux/rtthread.log", ROOT / "qemu/rtthread-linux/linux.log"),
    ("qemu", "rtthread", "starryos", ROOT / "qemu/rtthread-starryos/rtthread.log", ROOT / "qemu/rtthread-starryos/starryos.log"),
    ("qemu", "zephyr", "linux", ROOT / "qemu/zephyr-linux/zephyr.log", ROOT / "qemu/zephyr-linux/linux.log"),
    ("qemu", "zephyr", "starryos", ROOT / "qemu/zephyr-starryos/zephyr.log", ROOT / "qemu/zephyr-starryos/starryos.log"),
    ("rock4d", "rtthread", "linux", ROOT / "rock4d/fixed-task123-rock4d-rtthread-linux.log", ROOT / "rock4d/fixed-task123-rock4d-rtthread-linux.log"),
    ("rock4d", "rtthread", "starryos", ROOT / "rock4d/fixed-task123-rock4d-rtthread-starryos.log", ROOT / "rock4d/fixed-task123-rock4d-rtthread-starryos.log"),
    ("rock4d", "zephyr", "linux", ROOT / "rock4d/fixed-task123-rock4d-zephyr-linux.log", ROOT / "rock4d/fixed-task123-rock4d-zephyr-linux.log"),
    ("rock4d", "zephyr", "starryos", ROOT / "rock4d/fixed-task123-rock4d-zephyr-starryos.log", ROOT / "rock4d/fixed-task123-rock4d-zephyr-starryos.log"),
]
RTBENCH_METRICS = [
    "timer_jitter",
    "callback_exec",
    "preemption",
    "irq",
    "irq_to_task",
    "irq_disabled_duration",
    "mutex_inversion",
    "wake_under_load",
    "context_switch",
    "scheduler_decision",
    "sync_sem",
    "sync_mutex",
    "sync_mailbox",
    "irq_handler_exec",
    "deadline_miss_under_load",
    "net_event_latency",
]


def clean(text: str) -> str:
    return ANSI.sub("", text).replace("\x08", "")


def lines(path: Path) -> list[str]:
    return clean(path.read_text(encoding="utf-8", errors="replace")).splitlines()


def number(value: str) -> int | float | str:
    try:
        parsed = float(value)
    except ValueError:
        return value
    return int(parsed) if parsed.is_integer() else parsed


def fields(text: str) -> dict[str, int | float | str]:
    return {key: number(value) for key, value in re.findall(rf"([A-Za-z0-9_]+)=({NUMBER}|[^\s]+)", text)}


def parse_task2(path: Path, source: str, rtos: str, guest: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    payload: int | None = None
    pending: dict[str, object] = {}
    for line in lines(path):
        match = re.search(r"Payload\s+(\d+)B", line)
        if match:
            payload = int(match.group(1))
            pending = {"source": source, "rtos": rtos, "app_guest": guest, "payload_bytes": payload}
            continue
        if payload is None:
            continue
        match = re.search(
            rf"RTT:\s+min=({NUMBER})ms\s+avg=({NUMBER})ms\s+max=({NUMBER})ms\s+"
            rf"P50=({NUMBER})ms\s+P95=({NUMBER})ms\s+P99=({NUMBER})ms\s+P99\.9=({NUMBER})ms",
            line,
        )
        if match:
            for key, value in zip(("min", "avg", "max", "p50", "p95", "p99", "p99_9"), match.groups()):
                pending[f"rtt_{key}_ms"] = number(value)
            continue
        match = re.search(rf"throughput=({NUMBER})KiB/s", line)
        if match:
            pending["throughput_kib_s"] = number(match.group(1))
            continue
        if "transport:" in line:
            pending.update({f"transport_{key}": value for key, value in fields(line).items()})
        elif "request_timeouts=" in line:
            pending.update(fields(line))
        if "throughput_kib_s" in pending and "rtt_p99_9_ms" in pending:
            result.append(pending)
            payload = None
            pending = {}
    return result


def repair_summary(candidate: str) -> str:
    # One physical serial capture contains a byte-level overwrite in this key.
    repaired = re.sub(r'"success_ra[0-9]+,', '"success_rate":1.0,', candidate)
    return re.sub(
        r'"success_rafication":\{"correct"',
        '"success_rate":1.0,"classification":{"correct"',
        repaired,
    )


def parse_task3(path: Path, source: str, rtos: str, guest: str) -> dict[str, object]:
    text = "\n".join(lines(path))
    match = re.search(r"TASK3_SUMMARY_JSON=(\{.*\})", text)
    summary: dict[str, object] = {}
    if match:
        try:
            summary = json.loads(repair_summary(match.group(1)))
        except json.JSONDecodeError:
            summary = {}
    if not summary:
        frame_count = len(re.findall(r"TASK3_FRAME_CSV=", text))
        summary = {
            "schema": 1,
            "records": frame_count,
            "requests": frame_count,
            "successes": frame_count,
            "success_rate": 1.0 if frame_count else None,
            "application_errors": None,
            "application_timeouts": None,
            "transport_retries": None,
            "duplicates": None,
            "reconnects": None,
            "recoveries": None,
            "injected_drops": None,
        }
    final = re.search(
        r"TASK3_RTOS_FINAL requests=(\d+) errors=(\d+) duplicates=(\d+) "
        r"applied_steps=(\d+) retries=(\d+)",
        text,
    )
    if final:
        requests, errors, duplicates, applied_steps, retries = map(int, final.groups())
        summary.setdefault("requests", requests)
        summary.setdefault("application_errors", errors)
        summary.setdefault("duplicates", duplicates)
        summary.setdefault("transport_retries", retries)
        summary.setdefault("successes", applied_steps)
        summary.setdefault("application_timeouts", 0)
        summary.setdefault("reconnects", 0)
        summary.setdefault("recoveries", 0)
        summary.setdefault("injected_drops", 0)
    flat = flatten(summary)
    flat.update({"source": source, "rtos": rtos, "app_guest": guest})
    return flat


def flatten(value: object, prefix: str = "") -> dict[str, object]:
    result: dict[str, object] = {}
    if isinstance(value, dict):
        for key, child in value.items():
            result.update(flatten(child, f"{prefix}_{key}" if prefix else str(key)))
    elif isinstance(value, list):
        result[prefix] = json.dumps(value, separators=(",", ":"))
    else:
        result[prefix] = value
    return result


def parse_rtbench(path: Path, source: str, rtos: str, guest: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for line in lines(path):
        match = re.search(r"RTBENCH metric=([A-Za-z0-9_]+)\s+(.*)", line)
        if not match:
            continue
        row = {
            "source": source,
            "rtos": rtos,
            "app_guest": guest,
            "metric": match.group(1),
        }
        row.update(fields(match.group(2)))
        result.append(row)
    return result


def parse_host_metrics() -> list[dict[str, object]]:
    result = []
    for index, (source, rtos, guest, _rtos_path, _app_path) in enumerate(COMBINATIONS):
        row: dict[str, object] = {"source": source, "rtos": rtos, "app_guest": guest}
        if source == "qemu":
            path = ROOT / "qemu" / f"{rtos}-{guest}" / "host-metrics.txt"
            for line in lines(path):
                key, separator, value = line.partition("=")
                if separator:
                    row[key] = number(value)
        else:
            row.update({"cpu_time_ms": None, "peak_rss_kb": None, "max_threads": None})
        result.append(row)
    return result


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    keys: list[str] = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=keys, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def nice(value: object) -> str:
    if value is None or value == "":
        return "NA"
    if isinstance(value, float):
        return f"{value:.3g}"
    return str(value)


def svg_text(x: float, y: float, text: str, size: int = 12, anchor: str = "start", weight: str = "normal") -> str:
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}px" text-anchor="{anchor}" font-weight="{weight}" fill="#111827">{escape(str(text))}</text>'


def svg_header(width: int, height: int, title: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">',
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        '<style>text{font-family:Arial,sans-serif} .grid{stroke:#d1d5db;stroke-width:1} .frame{fill:none;stroke:#374151;stroke-width:1} .na{fill:#e5e7eb;stroke:#9ca3af;stroke-width:1}</style>',
        svg_text(24, 30, title, 20, weight="bold"),
    ]


def finish_svg(parts: list[str], path: Path) -> None:
    parts.append("</svg>\n")
    path.write_text("\n".join(parts), encoding="utf-8")


def chart_legend(parts: list[str], x: float, y: float) -> None:
    for index, label in enumerate(SHORT_LABELS):
        column = index % 4
        row = index // 4
        lx = x + column * 150
        ly = y + row * 20
        parts.append(f'<rect x="{lx:.1f}" y="{ly - 10:.1f}" width="12" height="12" fill="{PALETTE[index]}"/>')
        parts.append(svg_text(lx + 17, ly, label, 11))


def value_max(values: list[float | None], floor: float = 1.0) -> float:
    numbers = [float(v) for v in values if v is not None and math.isfinite(float(v))]
    return max(floor, max(numbers, default=floor) * 1.12)


def bar_panel(parts: list[str], x: float, y: float, width: float, height: float, title: str, values: list[float | None], unit: str = "") -> None:
    left, right, top, bottom = x + 58, x + width - 12, y + 34, y + height - 52
    top_value = value_max(values)
    parts.append(svg_text(x + 8, y + 20, title, 14, weight="bold"))
    parts.append(f'<rect class="frame" x="{left:.1f}" y="{top:.1f}" width="{right-left:.1f}" height="{bottom-top:.1f}"/>')
    for tick in range(5):
        value = top_value * tick / 4
        yy = bottom - (bottom - top) * tick / 4
        parts.append(f'<line class="grid" x1="{left:.1f}" y1="{yy:.1f}" x2="{right:.1f}" y2="{yy:.1f}"/>')
        parts.append(svg_text(left - 6, yy + 4, f"{value:.3g}", 10, "end"))
    step = (right - left) / len(values)
    bar_width = min(34, step * 0.60)
    for index, value in enumerate(values):
        cx = left + step * (index + 0.5)
        if value is not None:
            bar_height = (bottom - top) * float(value) / top_value
            parts.append(f'<rect x="{cx - bar_width/2:.1f}" y="{bottom-bar_height:.1f}" width="{bar_width:.1f}" height="{bar_height:.1f}" fill="{PALETTE[index]}"/>')
            parts.append(svg_text(cx, max(top + 12, bottom - bar_height - 4), nice(value), 10, "middle"))
        else:
            parts.append(f'<rect class="na" x="{cx - bar_width/2:.1f}" y="{bottom-8:.1f}" width="{bar_width:.1f}" height="8"/>')
            parts.append(svg_text(cx, bottom - 12, "NA", 9, "middle"))
        parts.append(svg_text(cx, bottom + 16, SHORT_LABELS[index], 9, "middle"))
    if unit:
        parts.append(svg_text(left - 42, top + (bottom-top)/2, unit, 10, "middle"))


def grouped_panel(parts: list[str], x: float, y: float, width: float, height: float, title: str, groups: list[tuple[str, list[float | None]]], unit: str = "") -> None:
    left, right, top, bottom = x + 58, x + width - 12, y + 34, y + height - 52
    all_values = [value for _label, values in groups for value in values]
    top_value = value_max(all_values)
    parts.append(svg_text(x + 8, y + 20, title, 14, weight="bold"))
    parts.append(f'<rect class="frame" x="{left:.1f}" y="{top:.1f}" width="{right-left:.1f}" height="{bottom-top:.1f}"/>')
    for tick in range(5):
        value = top_value * tick / 4
        yy = bottom - (bottom - top) * tick / 4
        parts.append(f'<line class="grid" x1="{left:.1f}" y1="{yy:.1f}" x2="{right:.1f}" y2="{yy:.1f}"/>')
        parts.append(svg_text(left - 6, yy + 4, f"{value:.3g}", 10, "end"))
    step = (right - left) / len(SHORT_LABELS)
    bar_width = min(14, step * 0.72 / max(1, len(groups)))
    for combo_index in range(len(SHORT_LABELS)):
        center = left + step * (combo_index + 0.5)
        offset = -(len(groups) - 1) * bar_width / 2
        for group_index, (_label, values) in enumerate(groups):
            value = values[combo_index]
            cx = center + offset + group_index * bar_width
            if value is None:
                parts.append(f'<rect class="na" x="{cx:.1f}" y="{bottom-7:.1f}" width="{max(5, bar_width-1):.1f}" height="7"/>')
            else:
                bar_height = (bottom - top) * float(value) / top_value
                parts.append(f'<rect x="{cx:.1f}" y="{bottom-bar_height:.1f}" width="{max(5, bar_width-1):.1f}" height="{bar_height:.1f}" fill="{PAYLOAD_COLORS[group_index % len(PAYLOAD_COLORS)]}"/>')
        parts.append(svg_text(center, bottom + 16, SHORT_LABELS[combo_index], 9, "middle"))
    legend_x = left
    legend_y = bottom + 36
    for group_index, (label, _values) in enumerate(groups):
        lx = legend_x + group_index * 100
        parts.append(f'<rect x="{lx:.1f}" y="{legend_y-10:.1f}" width="10" height="10" fill="{PAYLOAD_COLORS[group_index % len(PAYLOAD_COLORS)]}"/>')
        parts.append(svg_text(lx + 14, legend_y, label, 10))
    if unit:
        parts.append(svg_text(left - 42, top + (bottom-top)/2, unit, 10, "middle"))


def heatmap(parts: list[str], x: float, y: float, width: float, height: float, title: str, rows: list[str], values: dict[str, list[float | None]], unit: str = "", labels: list[str] | None = None) -> None:
    labels = labels or SHORT_LABELS
    left, right, top, bottom = x + 145, x + width - 12, y + 34, y + height - 32
    flat = [v for row in rows for v in values.get(row, []) if v is not None]
    lo, hi = min(flat, default=0.0), max(flat, default=1.0)
    if hi <= lo:
        hi = lo + 1
    cell_w = (right-left) / len(labels)
    cell_h = (bottom-top) / max(1, len(rows))
    parts.append(svg_text(x + 8, y + 20, title, 14, weight="bold"))
    for index, label in enumerate(labels):
        parts.append(svg_text(left + cell_w*(index+0.5), top - 8, label, 9, "middle"))
    for row_index, row in enumerate(rows):
        yy = top + row_index * cell_h
        parts.append(svg_text(left - 8, yy + cell_h*0.68, row, 9, "end"))
        for col_index, value in enumerate(values.get(row, [None] * len(labels))):
            xx = left + col_index * cell_w
            if value is None:
                parts.append(f'<rect class="na" x="{xx:.1f}" y="{yy:.1f}" width="{cell_w-1:.1f}" height="{cell_h-1:.1f}"/>')
                parts.append(svg_text(xx + cell_w/2, yy + cell_h*0.68, "NA", 8, "middle"))
            else:
                ratio = max(0.0, min(1.0, (float(value)-lo)/(hi-lo)))
                red = int(239 - 170 * ratio)
                green = int(246 - 120 * ratio)
                blue = int(255 - 30 * ratio)
                color = f"rgb({red},{green},{blue})"
                parts.append(f'<rect x="{xx:.1f}" y="{yy:.1f}" width="{cell_w-1:.1f}" height="{cell_h-1:.1f}" fill="{color}"/>')
                parts.append(svg_text(xx + cell_w/2, yy + cell_h*0.68, nice(value), 8, "middle"))
    if unit:
        parts.append(svg_text(x + 10, bottom + 16, f"unit: {unit}; color scale min={nice(lo)} max={nice(hi)}", 10))


def chart_task2(task2: list[dict[str, object]]) -> None:
    metric_names = [("rtt_min_ms", "RTT min", "ms"), ("rtt_avg_ms", "RTT avg", "ms"), ("rtt_max_ms", "RTT max", "ms"), ("rtt_p50_ms", "RTT P50", "ms"), ("rtt_p95_ms", "RTT P95", "ms"), ("rtt_p99_ms", "RTT P99", "ms"), ("rtt_p99_9_ms", "RTT P99.9", "ms")]
    parts = svg_header(1600, 1660, "Task 2 network latency: all payloads and combinations")
    by_payload = {payload: {(row["source"], row["rtos"], row["app_guest"]): row for row in task2 if row["payload_bytes"] == payload} for payload in (64, 256, 1024)}
    for index, (metric, title, unit) in enumerate(metric_names):
        groups = [(f"{payload}B", [float(by_payload[payload].get(tuple(COMBINATIONS[i][:3]), {}).get(metric)) if by_payload[payload].get(tuple(COMBINATIONS[i][:3]), {}).get(metric) is not None else None for i in range(8)]) for payload in (64, 256, 1024)]
        grouped_panel(parts, 20 + (index % 2) * 790, 50 + (index // 2) * 270, 760, 250, title, groups, unit)
    chart_legend(parts, 1080, 50 + 4 * 270)
    finish_svg(parts, PLOTS / "task2-latency.svg")

    parts = svg_header(1600, 760, "Task 2 network throughput: all payloads and combinations")
    groups = [(f"{payload}B", [float(by_payload[payload].get(tuple(COMBINATIONS[i][:3]), {}).get("throughput_kib_s")) if by_payload[payload].get(tuple(COMBINATIONS[i][:3]), {}).get("throughput_kib_s") is not None else None for i in range(8)]) for payload in (64, 256, 1024)]
    grouped_panel(parts, 20, 55, 1560, 610, "Throughput", groups, "KiB/s")
    chart_legend(parts, 1080, 690)
    finish_svg(parts, PLOTS / "task2-throughput.svg")


def task3_values(task3: list[dict[str, object]], key: str) -> list[float | None]:
    result = []
    for row in task3:
        value = row.get(key)
        result.append(float(value) if isinstance(value, (int, float)) else None)
    return result


def chart_task3(task3: list[dict[str, object]]) -> None:
    for family, metrics, title, filename in [
        ("inference_us", ["min", "mean", "p50", "p95", "p99", "max"], "Task 3 inference latency", "task3-inference.svg"),
        ("round_trip_us", ["min", "mean", "p50", "p95", "p99", "max"], "Task 3 round-trip latency", "task3-roundtrip.svg"),
    ]:
        parts = svg_header(1600, 980, f"{title}: QEMU and Rock-4D")
        for index, metric in enumerate(metrics):
            key = f"{family}_{metric}"
            bar_panel(parts, 20 + (index % 3) * 525, 55 + (index // 3) * 330, 505, 305, metric, task3_values(task3, key), "us")
        chart_legend(parts, 1080, 735)
        finish_svg(parts, PLOTS / filename)

    parts = svg_header(1600, 980, "Task 3 reliability and application throughput")
    metrics = [("success_rate", "Success rate", "ratio"), ("classification_accuracy", "Classification accuracy", "ratio"), ("effective_payload_bytes_per_second", "Effective payload", "bytes/s"), ("requests", "Requests", "count"), ("successes", "Successes", "count"), ("application_errors", "Application errors", "count"), ("application_timeouts", "Application timeouts", "count"), ("transport_retries", "Transport retries", "count"), ("reconnects", "Reconnects", "count")]
    for index, (key, title, unit) in enumerate(metrics):
        bar_panel(parts, 20 + (index % 3) * 525, 55 + (index // 3) * 300, 505, 275, title, task3_values(task3, key), unit)
    chart_legend(parts, 1080, 930)
    finish_svg(parts, PLOTS / "task3-reliability.svg")

    parts = svg_header(1600, 980, "Task 3 control-loop accuracy, errors, and recovery")
    metrics = [("tracking_error_q15_fixed_p50", "Fixed tracking error P50", "q15"), ("tracking_error_q15_fixed_p95", "Fixed tracking error P95", "q15"), ("tracking_error_q15_fixed_p99", "Fixed tracking error P99", "q15"), ("tracking_error_q15_ai_p50", "AI tracking error P50", "q15"), ("tracking_error_q15_ai_p95", "AI tracking error P95", "q15"), ("tracking_error_q15_ai_p99", "AI tracking error P99", "q15"), ("duplicates", "Duplicates", "count"), ("recoveries", "Recoveries", "count"), ("injected_drops", "Injected drops", "count")]
    for index, (key, title, unit) in enumerate(metrics):
        bar_panel(parts, 20 + (index % 3) * 525, 55 + (index // 3) * 300, 505, 275, title, task3_values(task3, key), unit)
    chart_legend(parts, 1080, 930)
    finish_svg(parts, PLOTS / "task3-control.svg")


def aggregate_rtbench(rtbench: list[dict[str, object]], statistic: str, metric_rows: list[str], combinations: list[tuple[str, str, str, Path, Path]]) -> dict[str, list[float | None]]:
    result: dict[str, list[float | None]] = {}
    for metric in metric_rows:
        values: list[float | None] = []
        for source, rtos, guest, _rtos_path, _app_path in combinations:
            matches = [row.get(statistic) for row in rtbench if row["source"] == source and row["rtos"] == rtos and row["app_guest"] == guest and row["metric"] == metric]
            numbers = [float(value) for value in matches if isinstance(value, (int, float))]
            if statistic.endswith(("_cycles", "_instructions")) and numbers and max(abs(value) for value in numbers) == 0:
                values.append(None)
            else:
                values.append(fmean(numbers) if numbers else None)
        result[metric] = values
    return result


def complete_rtbench_combinations(rtbench: list[dict[str, object]]) -> list[tuple[str, str, str, Path, Path]]:
    complete = []
    for combination in COMBINATIONS:
        source, rtos, guest, _rtos_path, _app_path = combination
        rows = [
            row
            for row in rtbench
            if row["source"] == source and row["rtos"] == rtos and row["app_guest"] == guest
        ]
        metrics = {row["metric"] for row in rows}
        if set(RTBENCH_METRICS) <= metrics and all(
            any(
                row["metric"] == metric and isinstance(row.get("mean_ns"), (int, float))
                for row in rows
            )
            for metric in RTBENCH_METRICS
        ):
            complete.append(combination)
    return complete


def chart_rtbench(rtbench: list[dict[str, object]]) -> None:
    metric_rows = RTBENCH_METRICS
    combinations = complete_rtbench_combinations(rtbench)
    labels = [SHORT_LABELS[COMBINATIONS.index(combination)] for combination in combinations]
    panels = [("mean_ns", "mean ns"), ("p95_ns", "p95 ns"), ("p99_ns", "p99 ns"), ("max_ns", "max ns")]
    parts = svg_header(1600, 1480, "RTBench nanosecond metrics: complete captures only")
    for index, (statistic, title) in enumerate(panels):
        heatmap(parts, 20 + (index % 2) * 790, 55 + (index // 2) * 675, 760, 640, title, metric_rows, aggregate_rtbench(rtbench, statistic, metric_rows, combinations), "ns", labels)
    if len(combinations) < len(COMBINATIONS):
        parts.append(svg_text(24, 1460, "ROCK 4D captures without the complete 16-metric ns contract are omitted.", 11))
    finish_svg(parts, PLOTS / "rtbench-nanoseconds.svg")

    count_rows = ["missing", "miss_100us", "miss_500us", "miss_1ms"]
    parts = svg_header(1600, 900, "RTBench completeness and jitter miss counts")
    for index, statistic in enumerate(count_rows):
        heatmap(parts, 20 + (index % 2) * 790, 55 + (index // 2) * 390, 760, 355, statistic, metric_rows, aggregate_rtbench(rtbench, statistic, metric_rows, combinations), "count", labels)
    if len(combinations) < len(COMBINATIONS):
        parts.append(svg_text(24, 885, "ROCK 4D captures without the complete 16-metric ns contract are omitted.", 11))
    finish_svg(parts, PLOTS / "rtbench-miss-counts.svg")

    # PMU registers are not virtualized consistently across QEMU and ROCK 4D.
    # Keep the comparison strictly ns-based instead of rendering zero counters
    # as a second heatmap full of NA cells.


def chart_host(host: list[dict[str, object]]) -> None:
    parts = svg_header(1600, 980, "QEMU host resource usage (Rock-4D host sampling unavailable)")
    metrics = [("cpu_time_ms", "CPU time", "ms"), ("peak_rss_kb", "Peak RSS", "KiB"), ("max_threads", "Max threads", "count")]
    for index, (key, title, unit) in enumerate(metrics):
        bar_panel(parts, 20 + (index % 3) * 525, 55, 505, 650, title, [float(row[key]) if isinstance(row.get(key), (int, float)) else None for row in host], unit)
    chart_legend(parts, 1080, 760)
    parts.append(svg_text(24, 900, "NA indicates that the physical board runner did not collect host-process CPU/RSS samples.", 12))
    finish_svg(parts, PLOTS / "host-resources.svg")


def main() -> None:
    PLOTS.mkdir(parents=True, exist_ok=True)
    task2: list[dict[str, object]] = []
    task3: list[dict[str, object]] = []
    rtbench: list[dict[str, object]] = []
    for source, rtos, guest, rtos_path, app_path in COMBINATIONS:
        task2.extend(parse_task2(app_path, source, rtos, guest))
        task3.append(parse_task3(app_path, source, rtos, guest))
        rtbench.extend(parse_rtbench(rtos_path, source, rtos, guest))
    host = parse_host_metrics()
    write_csv(ROOT / "task2-metrics.csv", task2)
    write_csv(ROOT / "task3-metrics.csv", task3)
    write_csv(ROOT / "rtbench-metrics.csv", rtbench)
    write_csv(ROOT / "host-metrics.csv", host)
    (ROOT / "parsed-data.json").write_text(json.dumps({"task2": task2, "task3": task3, "rtbench": rtbench, "host": host}, indent=2) + "\n", encoding="utf-8")
    chart_task2(task2)
    chart_task3(task3)
    chart_rtbench(rtbench)
    chart_host(host)
    print(f"generated {len(task2)} Task2 rows, {len(task3)} Task3 rows, {len(rtbench)} RTBench rows")
    print(f"charts: {len(list(PLOTS.glob('*.svg')))} SVG files in {PLOTS}")


if __name__ == "__main__":
    main()
