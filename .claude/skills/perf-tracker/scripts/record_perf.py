#!/usr/bin/env python3
"""
Record StarryOS qperf performance metrics into a structured CSV data table.

Usage:
    record_perf.py record --repo-root /path/to/tgoskits --summary path/to/summary.txt
        [--report-json path/to/report.json] [--hotspots-csv path/to/hotspots.csv]
        [--host-time path/to/qemu.time.txt] [--smp N]

After each `cargo xtask starry perf` run, extract metrics from the qperf output
and append one row to `<repo-root>/target/perf-history/perf_metrics.csv`.
"""

import argparse
import csv
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


CSV_COLUMNS = [
    "timestamp",
    "arch",
    "case",
    "build_profile",
    "freq_hz",
    "sampling_mode",
    "callchain_mode",
    "smp",
    "samples",
    "dropped_samples",
    "sample_failures",
    "folded_stack_lines",
    "window_enabled",
    "window_duration_sec",
    "window_start_time",
    "window_stop_time",
    "host_time_sec",
    "host_user_sec",
    "host_system_sec",
    "host_cpu_percent",
    "top_hotspot_1",
    "top_hotspot_1_percent",
    "top_hotspot_2",
    "top_hotspot_2_percent",
    "top_hotspot_3",
    "top_hotspot_3_percent",
    "qperf_dir",
]


def parse_kv_file(path):
    """Parse a key = value text file into a dict."""
    result = {}
    in_plugin_section = False
    plugin_data = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("[plugin_summary]"):
                in_plugin_section = True
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if in_plugin_section:
                    plugin_data[key] = value
                else:
                    result[key] = value
    for k, v in plugin_data.items():
        if k not in result:
            result[k] = v
    result["_plugin"] = plugin_data
    return result


def parse_host_time(path):
    """Parse qemu.time.txt into a dict of floats."""
    data = {}
    if not path or not Path(path).exists():
        return data
    patterns = {
        "host_time_sec": r"Elapsed time:\s*([0-9.eE+-]+)",
        "host_user_sec": r"User time:\s*([0-9.eE+-]+)",
        "host_system_sec": r"System time:\s*([0-9.eE+-]+)",
        "host_cpu_percent": r"Percent of CPU[^:]*:\s*([0-9.eE+-]+)",
    }
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    for key, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            try:
                data[key] = float(m.group(1))
            except ValueError:
                pass
    return data


def parse_hotspots(path, top_n=3):
    """Parse hotspots.csv and return top N (name, percent) pairs."""
    results = []
    if not path or not Path(path).exists():
        return results
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            reader = csv.DictReader(f)
            for i, row in enumerate(reader):
                if i >= top_n:
                    break
                name = (
                    row.get("symbol")
                    or row.get("name")
                    or row.get("function")
                    or "unknown"
                )
                pct_str = (
                    row.get("percent")
                    or row.get("percentage")
                    or row.get("self_percent")
                    or "0"
                )
                try:
                    pct = float(pct_str)
                except ValueError:
                    pct = 0.0
                results.append((name, pct))
    except Exception:
        pass
    return results


def parse_report_json(path):
    """Extract additional fields from report.json if available."""
    data = {}
    if not path or not Path(path).exists():
        return data
    try:
        with open(path, "r", encoding="utf-8") as f:
            report = json.load(f)
        for key in (
            "samples",
            "dropped_samples",
            "folded_stack_lines",
            "window_duration_sec",
        ):
            if key in report:
                data[key] = report[key]
    except (json.JSONDecodeError, OSError):
        pass
    return data


def safe_float(value, default=None):
    if value is None:
        return default
    try:
        return float(value)
    except (ValueError, TypeError):
        return default


def safe_int(value, default=None):
    if value is None:
        return default
    try:
        return int(value)
    except (ValueError, TypeError):
        return default


def build_row(summary_path, report_json_path, hotspots_path, host_time_path, smp):
    """Build a CSV row dict from the various qperf output files."""
    summary = parse_kv_file(summary_path)
    plugin = summary.get("_plugin", {})
    qperf_dir = str(Path(summary_path).parent)

    report = parse_report_json(report_json_path)
    host_time = parse_host_time(host_time_path)
    hotspots = parse_hotspots(hotspots_path, top_n=3)

    samples = safe_int(
        summary.get("samples") or report.get("samples") or plugin.get("samples")
    )
    dropped = safe_int(
        summary.get("dropped_samples")
        or report.get("dropped_samples")
        or plugin.get("dropped_samples")
    )
    failures = safe_int(
        summary.get("sample_failures") or plugin.get("sample_failures")
    )
    folded_lines = safe_int(
        summary.get("folded_stack_lines") or report.get("folded_stack_lines")
    )
    window_dur = safe_float(
        summary.get("window_duration_sec") or report.get("window_duration_sec")
    )

    row = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "arch": summary.get("arch", ""),
        "case": summary.get("case", ""),
        "build_profile": summary.get("build_profile", ""),
        "freq_hz": safe_int(summary.get("frequency_hz")),
        "sampling_mode": summary.get("sampling_mode", ""),
        "callchain_mode": summary.get("callchain_mode", ""),
        "smp": smp if smp is not None else "",
        "samples": samples if samples is not None else "",
        "dropped_samples": dropped if dropped is not None else "",
        "sample_failures": failures if failures is not None else "",
        "folded_stack_lines": folded_lines if folded_lines is not None else "",
        "window_enabled": summary.get("window_enabled", ""),
        "window_duration_sec": window_dur if window_dur is not None else "",
        "window_start_time": safe_float(summary.get("window_start_time"), ""),
        "window_stop_time": safe_float(summary.get("window_stop_time"), ""),
        "host_time_sec": host_time.get("host_time_sec", ""),
        "host_user_sec": host_time.get("host_user_sec", ""),
        "host_system_sec": host_time.get("host_system_sec", ""),
        "host_cpu_percent": host_time.get("host_cpu_percent", ""),
        "qperf_dir": qperf_dir,
    }

    for i, (name, pct) in enumerate(hotspots):
        row[f"top_hotspot_{i + 1}"] = name
        row[f"top_hotspot_{i + 1}_percent"] = pct
    for i in range(len(hotspots), 3):
        row[f"top_hotspot_{i + 1}"] = ""
        row[f"top_hotspot_{i + 1}_percent"] = ""

    return row


def cmd_record(args):
    summary_path = Path(args.summary).resolve()
    if not summary_path.exists():
        print(f"Error: summary file not found: {summary_path}", file=sys.stderr)
        return 1

    qperf_dir = summary_path.parent

    report_json_path = args.report_json
    if not report_json_path:
        candidate = qperf_dir.parent / "report.json"
        report_json_path = str(candidate) if candidate.exists() else None

    hotspots_path = args.hotspots_csv
    if not hotspots_path:
        candidate = qperf_dir.parent / "hotspots.csv"
        hotspots_path = str(candidate) if candidate.exists() else None

    host_time_path = args.host_time
    if not host_time_path:
        candidate = qperf_dir / "qemu.time.txt"
        host_time_path = str(candidate) if candidate.exists() else None

    row = build_row(
        summary_path, report_json_path, hotspots_path, host_time_path, args.smp
    )

    csv_dir = Path(args.repo_root) / "target" / "perf-history"
    csv_dir.mkdir(parents=True, exist_ok=True)
    csv_path = csv_dir / "perf_metrics.csv"

    file_exists = csv_path.exists() and csv_path.stat().st_size > 0
    with open(csv_path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)

    print(f"Recorded metrics to {csv_path}")
    print(
        f"  arch={row['arch']}  case={row['case']}  "
        f"samples={row['samples']}  folded={row['folded_stack_lines']}"
    )
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Record qperf performance metrics into a CSV data table"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    rec = subparsers.add_parser("record", help="Extract metrics and append to CSV")
    rec.add_argument("--repo-root", required=True, help="Repository root directory")
    rec.add_argument("--summary", required=True, help="Path to qperf summary.txt")
    rec.add_argument(
        "--report-json", default=None, help="Path to report.json (auto-discovered)"
    )
    rec.add_argument(
        "--hotspots-csv", default=None, help="Path to hotspots.csv (auto-discovered)"
    )
    rec.add_argument(
        "--host-time", default=None, help="Path to qemu.time.txt (auto-discovered)"
    )
    rec.add_argument("--smp", type=int, default=None, help="Number of CPUs (SMP)")
    rec.set_defaults(func=cmd_record)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
