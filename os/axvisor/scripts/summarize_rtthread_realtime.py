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
    "context_switch",
    "scheduler_decision",
    "sync_sem",
    "sync_mutex",
    "sync_mailbox",
    "irq_handler_exec",
    "deadline_miss_under_load",
    "net_event_latency",
)
STABILITY_METRICS = ("stability_jitter", "callback_exec")
UNIT_STAT_FIELDS = {
    "ns": (
        "p50_ns", "p95_ns", "p99_ns", "p99_9_ns", "max_ns", "mean_ns",
    ),
    "cycles": (
        "p50_cycles", "p95_cycles", "p99_cycles", "p99_9_cycles",
        "max_cycles", "mean_cycles",
    ),
    "instructions": (
        "p50_instructions", "p95_instructions", "p99_instructions",
        "p99_9_instructions", "max_instructions", "mean_instructions",
    ),
}
STAT_FIELDS = UNIT_STAT_FIELDS["ns"]
ALL_STAT_FIELDS = (
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
    b"miss_1ms", b"mean_ns", b"p50_cycles", b"p95_cycles",
    b"p99_cycles", b"p99_9_cycles", b"max_cycles", b"mean_cycles",
    b"p50_instructions", b"p95_instructions", b"p99_instructions",
    b"p99_9_instructions", b"max_instructions", b"mean_instructions",
)
FIELD_NAME_TEXT = tuple(name.decode("ascii") for name in FIELD_NAMES)
FIELD_VALUE_RE = re.compile(
    r"(?<![A-Za-z_])(" + "|".join(re.escape(name) for name in FIELD_NAME_TEXT) +
    r")=([0-9]+)"
)
METRIC_MARKER = re.compile(rb"RTBENCH metric=([A-Za-z0-9_]+) run=([0-9]+)")
METRIC_BOUNDARY = re.compile(rb"RTBENCH(?:_END|_STABILITY_|_ERROR)")


def parse_value(value: str) -> int:
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"non-integer field value: {value}")
    return int(value)


REPEATED_RUNS = {"timer_jitter", "callback_exec"}
JOINT_SCENARIO_COMPARISONS = (
    ("A_native", "B_axvisor_rtthread", "B_over_A"),
    ("A_native", "C_axvisor_linux_rtthread", "C_over_A"),
    ("B_axvisor_rtthread", "C_axvisor_linux_rtthread", "C_over_B"),
)
JOINT_CHANGE_THRESHOLD = 1.20


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
    # Task 3 status can be emitted by the other guest while RTBENCH is
    # printing a field. Remove the bounded status record so a split field
    # such as "pTASK3_RTOS_FINAL...99_cycles" can be reconstructed.
    data = re.sub(
        rb"TASK3_RTOS_FINAL\s+requests=[0-9]+\s+errors=[0-9]+\s+"
        rb"duplicates=[0-9]+\s+applied_steps=[0-9]+\s+retries=[0-9]+"
        rb"[\r\n\x00 ]*",
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
                re.search(rb"(?<![A-Za-z_])" + re.escape(name) + rb"=([0-9]+)", candidate)
                for name in FIELD_NAMES
            ):
                cursor += 1
                break
            cursor += 1
        chunk = b" ".join(block)
        values = {}
        for name in FIELD_NAMES:
            match = re.search(
                rb"(?<![A-Za-z_])" + re.escape(name) + rb"=([0-9]+)", chunk
            )
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
        for field_match in FIELD_VALUE_RE.finditer(fields_text):
            fields[field_match.group(1)] = parse_value(field_match.group(2))
        required = (
            "expected",
            "collected",
            "missing",
            *ALL_STAT_FIELDS,
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


def ratio(left: int | float | None, right: int | float | None) -> float | None:
    return left / right if left is not None and right else None


def joint_record(record: dict[str, int]) -> dict[str, Any]:
    """Build a same-window view of the three counter domains.

    Percentiles are independently calculated in the guest, so they are
    reported as parallel values.  The efficiency ratios use the three means,
    which are totals over the same sample set and therefore remain paired at
    aggregate level.
    """
    return {
        "p99": {
            "ns": record["p99_ns"],
            "cycles": record["p99_cycles"],
            "instructions": record["p99_instructions"],
        },
        "max": {
            "ns": record["max_ns"],
            "cycles": record["max_cycles"],
            "instructions": record["max_instructions"],
        },
        "mean": {
            "ns": record["mean_ns"],
            "cycles": record["mean_cycles"],
            "instructions": record["mean_instructions"],
        },
        "aggregate_efficiency": {
            "mean_ns_per_instruction": ratio(
                record["mean_ns"], record["mean_instructions"]
            ),
            "mean_cycles_per_instruction": ratio(
                record["mean_cycles"], record["mean_instructions"]
            ),
            "mean_ns_per_cycle": ratio(record["mean_ns"], record["mean_cycles"]),
        },
    }


def classify_joint(
    baseline: dict[str, int], candidate: dict[str, int]
) -> tuple[str, dict[str, float | None]]:
    """Classify a candidate using all three P99 counter domains.

    This is an attribution heuristic, not a hard-real-time guarantee.  The
    latency gate remains based on absolute nanoseconds elsewhere.
    """
    p99_ratios = {
        "ns": ratio(candidate["p99_ns"], baseline["p99_ns"]),
        "cycles": ratio(candidate["p99_cycles"], baseline["p99_cycles"]),
        "instructions": ratio(
            candidate["p99_instructions"], baseline["p99_instructions"]
        ),
    }
    if any(value is None for value in p99_ratios.values()):
        return "insufficient_baseline", p99_ratios

    latency_high = p99_ratios["ns"] > JOINT_CHANGE_THRESHOLD
    cycles_high = p99_ratios["cycles"] > JOINT_CHANGE_THRESHOLD
    instructions_high = p99_ratios["instructions"] > JOINT_CHANGE_THRESHOLD
    if latency_high and not cycles_high and not instructions_high:
        classification = "latency_only"
    elif latency_high and cycles_high and instructions_high:
        classification = "path_expansion"
    elif latency_high:
        classification = "mixed"
    elif cycles_high or instructions_high:
        classification = "work_increase_without_latency_regression"
    else:
        classification = "stable"
    return classification, p99_ratios


def compare_joint(
    baseline: dict[str, int], candidate: dict[str, int]
) -> dict[str, Any]:
    classification, p99_ratios = classify_joint(baseline, candidate)
    baseline_joint = joint_record(baseline)
    candidate_joint = joint_record(candidate)
    return {
        "classification": classification,
        "p99_ratio": p99_ratios,
        "max_ratio": {
            unit: ratio(candidate_joint["max"][unit], baseline_joint["max"][unit])
            for unit in ("ns", "cycles", "instructions")
        },
        "aggregate_efficiency_ratio": {
            key: ratio(
                candidate_joint["aggregate_efficiency"][key],
                baseline_joint["aggregate_efficiency"][key],
            )
            for key in (
                "mean_ns_per_instruction",
                "mean_cycles_per_instruction",
                "mean_ns_per_cycle",
            )
        },
    }


def build_joint_analysis(
    scenarios: dict[str, dict[str, dict[str, int]]],
    metrics: tuple[str, ...],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for metric in metrics:
        result[metric] = {
            "scenarios": {
                label: joint_record(scenarios[label][metric])
                for label in scenarios
            },
            "comparisons": {
                output: compare_joint(
                    scenarios[baseline][metric], scenarios[candidate][metric]
                )
                for baseline, candidate, output in JOINT_SCENARIO_COMPARISONS
                if baseline in scenarios and candidate in scenarios
            },
        }
    return result


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.4f}".rstrip("0").rstrip(".")
    return str(value)


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
        "## 联合三指标分析",
        "",
        "纳秒用于实时性门禁；cycles 和 instructions 用于解释执行工作量。P99 分位数是三类"
        "独立分布，均值效率比来自同一批样本。归因分类是定位启发式，不是硬实时证明。",
        "",
        "| Metric | Comparison | P99 ns ratio | P99 cycles ratio | P99 instructions ratio | "
        "Mean ns/instruction ratio | Mean cycles/instruction ratio | Mean ns/cycle ratio | "
        "Classification |",
        "|---|---|---:|---:|---:|---:|---:|---:|---|",
    ])
    for metric in result["metrics"]:
        joint = result.get("joint_analysis", {}).get(metric, {})
        for comparison, values in joint.get("comparisons", {}).items():
            lines.append(
                f"| {metric} | {comparison} | {fmt(values['p99_ratio']['ns'])} | "
                f"{fmt(values['p99_ratio']['cycles'])} | "
                f"{fmt(values['p99_ratio']['instructions'])} | "
                f"{fmt(values['aggregate_efficiency_ratio']['mean_ns_per_instruction'])} | "
                f"{fmt(values['aggregate_efficiency_ratio']['mean_cycles_per_instruction'])} | "
                f"{fmt(values['aggregate_efficiency_ratio']['mean_ns_per_cycle'])} | "
                f"{values['classification']} |"
            )

    network = result.get("network_comparison")
    for unit, fields in UNIT_STAT_FIELDS.items():
        suffix = unit
        lines.extend([
            "",
            f"## Percentiles ({unit})",
            "",
            f"| Metric | Scenario | P50 ({suffix}) | P95 ({suffix}) | P99 ({suffix}) | P99.9 ({suffix}) | Max ({suffix}) |",
            "|---|---|---:|---:|---:|---:|---:|",
        ])
        for metric in result["metrics"]:
            metric_comparison = result["comparison"].get(metric)
            if metric_comparison is None and network and network.get("metric") == metric:
                metric_comparison = network
            if metric_comparison is None:
                continue
            p50, p95, p99, p99_9, maximum, _mean = fields
            for label in ("A_native", "B_axvisor_rtthread", "C_axvisor_linux_rtthread"):
                record = metric_comparison.get(label)
                if record is None:
                    lines.append(f"| {metric} | {label} | N/A | N/A | N/A | N/A | N/A |")
                    continue
                lines.append(
                    f"| {metric} | {label} | {record[p50]} | {record[p95]} | "
                    f"{record[p99]} | {record[p99_9]} | {record[maximum]} |"
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
    parser.add_argument("--joint-csv-output", type=Path)
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
                for field in (*ALL_STAT_FIELDS, *COUNT_FIELDS)
            },
            "C_over_B": {
                field: ratio(c[field], b[field])
                for field in (*ALL_STAT_FIELDS, *COUNT_FIELDS)
            },
        }

    result = {
        "schema": 1,
        "metrics": list(metric_filter),
        "units": list(UNIT_STAT_FIELDS),
        "core_metrics": list(core_filter),
        "comparison": comparison,
        "assessment": {
            label: classify(records)
            for label, records in scenarios.items()
        },
        "joint_analysis": build_joint_analysis(scenarios, comparison_metrics),
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
                for field in (*ALL_STAT_FIELDS, *COUNT_FIELDS)
            },
        }

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.csv_output:
        args.csv_output.parent.mkdir(parents=True, exist_ok=True)
        with args.csv_output.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["metric", "scenario", *ALL_STAT_FIELDS, *COUNT_FIELDS])
            for metric in metric_filter:
                for label in scenarios:
                    record = scenarios[label].get(metric)
                    writer.writerow([
                        metric,
                        label,
                        *([record[field] for field in (*ALL_STAT_FIELDS, *COUNT_FIELDS)] if record else [""] * (len(ALL_STAT_FIELDS) + len(COUNT_FIELDS))),
                    ])
    if args.joint_csv_output:
        args.joint_csv_output.parent.mkdir(parents=True, exist_ok=True)
        with args.joint_csv_output.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow([
                "metric", "baseline", "candidate", "classification",
                "p99_ns_ratio", "p99_cycles_ratio", "p99_instructions_ratio",
                "max_ns_ratio", "max_cycles_ratio", "max_instructions_ratio",
                "mean_ns_per_instruction_ratio", "mean_cycles_per_instruction_ratio",
                "mean_ns_per_cycle_ratio",
            ])
            for metric in comparison_metrics:
                comparisons = result["joint_analysis"][metric]["comparisons"]
                for output, values in comparisons.items():
                    baseline, candidate = {
                        "B_over_A": ("A_native", "B_axvisor_rtthread"),
                        "C_over_A": ("A_native", "C_axvisor_linux_rtthread"),
                        "C_over_B": ("B_axvisor_rtthread", "C_axvisor_linux_rtthread"),
                    }[output]
                    writer.writerow([
                        metric, baseline, candidate, values["classification"],
                        values["p99_ratio"]["ns"], values["p99_ratio"]["cycles"],
                        values["p99_ratio"]["instructions"], values["max_ratio"]["ns"],
                        values["max_ratio"]["cycles"], values["max_ratio"]["instructions"],
                        values["aggregate_efficiency_ratio"]["mean_ns_per_instruction"],
                        values["aggregate_efficiency_ratio"]["mean_cycles_per_instruction"],
                        values["aggregate_efficiency_ratio"]["mean_ns_per_cycle"],
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
