#!/usr/bin/env python3
"""Summarize comparable RT-Thread real-time benchmark logs.

Input logs contain one stable line per metric:
RTBENCH metric=NAME ... key=value ...
The same metric may appear once per scenario. This tool deliberately rejects
duplicate, incomplete, or malformed records instead of averaging them.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any


SUIT_METRICS = (
    "timer_jitter",
    "callback_exec",
    "preemption",
    "irq",
    "irq_to_task",
    "irq_disabled_duration",
    "mutex_inversion",
    "wake_under_load",
    "net_event_latency",
)
STABILITY_METRICS = ("stability_jitter", "callback_exec")
STAT_FIELDS = (
    "p50_ns",
    "p95_ns",
    "p99_ns",
    "p99_9_ns",
    "max_ns",
    "mean_ns",
)
COUNT_FIELDS = (
    "miss_100us",
    "miss_500us",
    "miss_1ms",
)
LINE_RE = re.compile(r"RTBENCH metric=([A-Za-z0-9_]+) run=([0-9]+)(.*)$")
FIELD_NAMES = (
    b"expected", b"collected", b"missing", b"p50_ns", b"p95_ns",
    b"p99_ns", b"p99_9_ns", b"max_ns", b"miss_100us", b"miss_500us",
    b"miss_1ms", b"mean_ns",
)
METRIC_MARKER = re.compile(rb"RTBENCH metric=([A-Za-z0-9_]+) run=([0-9]+)")
METRIC_BOUNDARY = re.compile(rb"RTBENCH(?:_END|_STABILITY_|_ERROR)")


def parse_value(value: str) -> int:
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"non-integer field value: {value}")
    return int(value)


REPEATED_RUNS = {"timer_jitter", "callback_exec"}


def normalized_log_lines(path: Path) -> list[str]:
    """Recover RTBENCH records from a serial stream with host-log injection."""
    data = path.read_bytes()
    host_log = re.compile(rb"\x1b\[37m\[[^\r\n]*?\x1b\[m\r?\n?")
    data = host_log.sub(b"", data)
    data = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)
    # Serial output can contain a NUL when a guest log is interleaved between
    # two bytes of an RTBENCH record. It is not part of the benchmark schema.
    data = data.replace(b"\x00", b"")
    # RT-IPC status messages may be inserted into the same serial line after
    # color stripping. Remove only the bounded message, preserving later
    # benchmark fields such as the remainder of a split metric name.
    data = re.sub(
        rb"\[(?:I|W)/rtipic\.[^]]+\]\s+client\s+(?:connected|disconnected)[\r\n\x00 ]*",
        b"",
        data,
    )
    # A byte-level serial collision can split the fixed mutex_inversion token
    # as "mute" + interleaved log + "inversion". Recover that known token
    # before the record is split into lines.
    data = re.sub(
        rb"RTBENCH metric=mute[\r\n\x00 ]*_?inversion run=",
        b"RTBENCH metric=mutex_inversion run=",
        data,
    )
    data = data.replace(b"\r", b"")

    lines = data.splitlines()
    normalized: list[bytes] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        marker = METRIC_MARKER.search(line)
        if marker is None:
            normalized.append(line)
            index += 1
            continue
        block = [line]
        cursor = index + 1
        while cursor < len(lines):
            continuation = lines[cursor]
            if METRIC_MARKER.search(continuation) or METRIC_BOUNDARY.search(continuation):
                break
            block.append(continuation)
            candidate = b" ".join(block)
            if all(
                re.search(rb"\b" + re.escape(name) + rb"=([0-9]+)", candidate)
                for name in FIELD_NAMES
            ):
                cursor += 1
                break
            cursor += 1
        chunk = b" ".join(block)
        values = {}
        for name in FIELD_NAMES:
            match = re.search(rb"\b" + re.escape(name) + rb"=([0-9]+)", chunk)
            if match is not None:
                values[name] = match.group(1)
        if len(values) == len(FIELD_NAMES):
            normalized.append(
                b"RTBENCH metric=" + marker.group(1) + b" run=" + marker.group(2) + b" " +
                b" ".join(name + b"=" + values[name] for name in FIELD_NAMES)
            )
        else:
            normalized.append(chunk)
        index = cursor
    return [line.decode("utf-8", errors="replace") for line in normalized]


def parse_log(path: Path) -> dict[str, dict[str, int]]:
    records: dict[str, dict[str, int]] = {}
    for raw_line in normalized_log_lines(path):
        match = LINE_RE.search(raw_line)
        if match is None:
            continue
        metric, _run, fields_text = match.groups()
        if metric in records and metric not in REPEATED_RUNS:
            raise ValueError(f"duplicate metric in {path}: {metric}")
        fields: dict[str, int] = {}
        for item in fields_text.split():
            if "=" not in item:
                continue
            key, value = item.split("=", 1)
            fields[key] = parse_value(value)
        required = (
            "expected",
            "collected",
            "missing",
            *STAT_FIELDS,
            *COUNT_FIELDS,
        )
        missing = [key for key in required if key not in fields]
        if missing:
            raise ValueError(f"metric {metric} is missing fields: {', '.join(missing)}")
        if fields["collected"] != fields["expected"] or fields["missing"] != 0:
            raise ValueError(f"metric {metric} has missing samples: {fields['missing']}")
        # Keep the worst run by observed maximum so strict-tail assessment
        # cannot hide a rare long-tail event in an earlier repeated run.
        if metric not in records or fields["max_ns"] > records[metric]["max_ns"]:
            records[metric] = fields
    return records


def require_metrics(records: dict[str, dict[str, int]], metrics: tuple[str, ...], label: str) -> None:
    missing = [metric for metric in metrics if metric not in records]
    if missing:
        raise ValueError(f"{label} is missing metrics: {', '.join(missing)}")
    extra = set(records) - set(metrics)
    if extra:
        raise ValueError(f"{label} has unexpected metrics: {', '.join(sorted(extra))}")


def ratio(left: int, right: int) -> float | None:
    return left / right if right else None


def markdown_report(result: dict[str, Any]) -> str:
    lines = [
        "# RT-Thread realtime comparison",
        "",
        f"Metrics: `{', '.join(result['metrics'])}`",
        "",
        "## Assessment",
        "",
        "| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |",
        "|---|---:|---:|---:|",
    ]
    for label, assessment in result["assessment"].items():
        lines.append(
            f"| {label} | {assessment['data_complete']} | "
            f"{assessment['strict_tail_pass']} | {assessment['tail_degradation']} |"
        )

    lines.extend([
        "",
        "## Percentiles",
        "",
        "| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    network = result.get("network_comparison")
    for metric in result["metrics"]:
        metric_comparison = result["comparison"].get(metric)
        if metric_comparison is None and network and network.get("metric") == metric:
            metric_comparison = network
        if metric_comparison is None:
            continue
        for label in ("A_native", "B_axvisor_rtthread", "C_axvisor_linux_rtthread"):
            record = metric_comparison.get(label)
            if record is None:
                lines.append(f"| {metric} | {label} | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |")
                continue
            lines.append(
                f"| {metric} | {label} | {record['p50_ns']} | {record['p95_ns']} | "
                f"{record['p99_ns']} | {record['p99_9_ns']} | {record['max_ns']} | "
                f"{record['miss_100us']} | {record['miss_500us']} | {record['miss_1ms']} |"
            )

    if result.get("network_metric_status"):
        lines.extend([
            "",
            f"Network metric status for B: `{result['network_metric_status']}`.",
            "",
            result["network_comparison"]["reason"],
        ])
    return "\n".join(lines) + "\n"


def classify(records: dict[str, dict[str, int]]) -> dict[str, Any]:
    tails = [record["max_ns"] for record in records.values()]
    return {
        "data_complete": True,
        "strict_tail_pass": all(value <= 1_000_000 for value in tails),
        "tail_degradation": max(tails),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--axvisor-only", type=Path, required=True)
    parser.add_argument("--axvisor-linux", type=Path, required=True)
    parser.add_argument("--suite-samples", type=int)
    parser.add_argument("--stability", action="store_true")
    parser.add_argument(
        "--axvisor-only-core",
        action="store_true",
        help="B contains the core suite; network latency is not applicable without a peer guest",
    )
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--csv-output", type=Path)
    parser.add_argument("--markdown-output", type=Path)
    args = parser.parse_args()

    if args.axvisor_only_core and args.stability:
        parser.error("--axvisor-only-core is only valid for suite results")

    metric_filter = STABILITY_METRICS if args.stability else SUIT_METRICS
    core_filter = tuple(
        metric for metric in metric_filter if metric != "net_event_latency"
    )
    scenarios = {
        "A_native": parse_log(args.native),
        "B_axvisor_rtthread": parse_log(args.axvisor_only),
        "C_axvisor_linux_rtthread": parse_log(args.axvisor_linux),
    }
    required_metrics = {
        "A_native": metric_filter,
        "B_axvisor_rtthread": core_filter if args.axvisor_only_core else metric_filter,
        "C_axvisor_linux_rtthread": metric_filter,
    }
    for label, records in scenarios.items():
        require_metrics(records, required_metrics[label], label)
        if args.suite_samples is not None and not args.stability:
            bad = [name for name, rec in records.items() if rec["expected"] != args.suite_samples]
            if bad:
                raise ValueError(f"{label} has unexpected sample counts: {', '.join(bad)}")

    comparison: dict[str, Any] = {}
    comparison_metrics = core_filter if args.axvisor_only_core else metric_filter
    for metric in comparison_metrics:
        a = scenarios["A_native"][metric]
        b = scenarios["B_axvisor_rtthread"][metric]
        c = scenarios["C_axvisor_linux_rtthread"][metric]
        comparison[metric] = {
            "A_native": a,
            "B_axvisor_rtthread": b,
            "C_axvisor_linux_rtthread": c,
            "B_over_A": {
                field: ratio(b[field], a[field])
                for field in (*STAT_FIELDS, *COUNT_FIELDS)
            },
            "C_over_B": {
                field: ratio(c[field], b[field])
                for field in (*STAT_FIELDS, *COUNT_FIELDS)
            },
        }

    result = {
        "schema": 1,
        "metrics": list(metric_filter),
        "core_metrics": list(core_filter),
        "comparison": comparison,
        "assessment": {
            label: classify(records)
            for label, records in scenarios.items()
        },
    }

    if args.axvisor_only_core:
        network = "net_event_latency"
        result["network_metric_status"] = "not_applicable_for_B"
        result["network_comparison"] = {
            "metric": network,
            "A_native": scenarios["A_native"][network],
            "B_axvisor_rtthread": None,
            "C_axvisor_linux_rtthread": scenarios["C_axvisor_linux_rtthread"][network],
            "reason": "AxVisor-only has one guest and no peer endpoint for the cross-guest UDP probe",
            "C_over_A": {
                field: ratio(
                    scenarios["C_axvisor_linux_rtthread"][network][field],
                    scenarios["A_native"][network][field],
                )
                for field in (*STAT_FIELDS, *COUNT_FIELDS)
            },
        }

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.csv_output:
        args.csv_output.parent.mkdir(parents=True, exist_ok=True)
        with args.csv_output.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["metric", "scenario", *STAT_FIELDS, *COUNT_FIELDS])
            for metric in metric_filter:
                for label in scenarios:
                    record = scenarios[label].get(metric)
                    writer.writerow([
                        metric,
                        label,
                        *([record[field] for field in (*STAT_FIELDS, *COUNT_FIELDS)] if record else [""] * (len(STAT_FIELDS) + len(COUNT_FIELDS))),
                    ])
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(markdown_report(result), encoding="utf-8")

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"summarize_rtthread_realtime: {error}", file=sys.stderr)
        raise SystemExit(1)
