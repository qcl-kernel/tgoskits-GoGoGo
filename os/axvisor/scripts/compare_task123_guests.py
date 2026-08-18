#!/usr/bin/env python3
"""Compare equivalent Linux and StarryOS Task123 run directories."""

from __future__ import annotations

import argparse
import json
import re
import tempfile
from pathlib import Path
from typing import Any


NUMBER = r"[0-9]+(?:\.[0-9]+)?"
RTT_KEYS = ("min", "avg", "p50", "p95", "p99", "p99.9", "max")
SHARED_ARTIFACTS = (
    "qemu",
    "rtthread-normal",
    "rtthread-drop-status",
    "rtthread-delayed-server",
    "rootfs",
    "model",
    "protocol-source",
    "protocol-header",
)
RTBENCH_FIELDS = (
    "expected",
    "collected",
    "missing",
    "p50_ns",
    "p95_ns",
    "p99_ns",
    "p99_9_ns",
    "max_ns",
    "miss_100us",
    "miss_500us",
    "miss_1ms",
    "mean_ns",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def duration_to_ms(value: str, unit: str) -> float:
    factors = {"ns": 1e-6, "us": 1e-3, "ms": 1.0, "s": 1000.0}
    return float(value) * factors[unit]


def parse_key_values(line: str) -> dict[str, str]:
    return dict(re.findall(r"([A-Za-z][A-Za-z0-9_.-]*)=([^\s]+)", line))


def parse_task2(path: Path) -> dict[str, Any]:
    payloads: dict[str, dict[str, Any]] = {}
    current: str | None = None
    for raw_line in path.read_text(encoding="ascii", errors="strict").splitlines():
        line = raw_line.strip()
        match = re.search(r"--- Payload ([0-9]+)B ---", line)
        if match:
            current = match.group(1)
            payloads[current] = {"payload_bytes": int(current)}
            continue
        if current is None:
            continue
        section = payloads[current]
        match = re.search(r"sent=([0-9]+)\s+recv=([0-9]+)", line)
        if match:
            section["sent"] = int(match.group(1))
            section["received"] = int(match.group(2))
            continue
        if line.startswith("RTT:"):
            values: dict[str, float] = {}
            for key in RTT_KEYS:
                match = re.search(
                    rf"\b{re.escape(key)}=({NUMBER})(ns|us|ms|s)\b",
                    line,
                    flags=re.IGNORECASE,
                )
                if match is None:
                    fail(f"missing RTT field {key} in {path}: {line}")
                values[key] = duration_to_ms(match.group(1), match.group(2))
            section["rtt_ms"] = values
            continue
        match = re.search(rf"throughput=({NUMBER})(B/s|KiB/s|MiB/s|GiB/s)", line)
        if match:
            multipliers = {
                "B/s": 1,
                "KiB/s": 1024,
                "MiB/s": 1024**2,
                "GiB/s": 1024**3,
            }
            section["throughput_bytes_per_s"] = float(match.group(1)) * multipliers[match.group(2)]
            continue
        if line.startswith("request_timeouts="):
            section["application"] = {
                key: int(value)
                for key, value in parse_key_values(line).items()
                if key in {"request_timeouts", "protocol_errors", "reconnects"}
            }
            continue
        if line.startswith("transport:"):
            section["transport"] = {
                key: int(value)
                for key, value in parse_key_values(line).items()
                if key in {"retrans", "timeouts", "dup", "reorder", "errors"}
            }

    if set(payloads) != {"64", "256", "1024"}:
        fail(f"Task2 must contain 64/256/1024-byte payload sections: {path}")
    for payload, section in payloads.items():
        required = {
            "sent",
            "received",
            "rtt_ms",
            "throughput_bytes_per_s",
            "application",
            "transport",
        }
        if not required.issubset(section):
            fail(f"incomplete Task2 section {payload}B in {path}")
    return {"payloads": payloads}


def parse_rtbench(path: Path) -> dict[str, Any]:
    metrics: dict[str, dict[str, Any]] = {}
    for raw_line in path.read_text(encoding="ascii", errors="strict").splitlines():
        line = raw_line.strip()
        match = re.match(r"RTBENCH metric=([A-Za-z0-9_]+)\s+(.*)$", line)
        if not match:
            continue
        metric_name = match.group(1)
        values = parse_key_values(match.group(2))
        if any(field not in values for field in RTBENCH_FIELDS):
            fail(f"incomplete RTBench metric {metric_name} in {path}")
        metrics[metric_name] = {field: int(values[field]) for field in RTBENCH_FIELDS}
    if "stability_jitter" not in metrics or "callback_exec" not in metrics:
        fail(f"stability_jitter and callback_exec are required in {path}")
    return metrics


def parse_summary(path: Path) -> dict[str, Any]:
    try:
        summary = json.loads(path.read_text(encoding="ascii"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid Task3 summary {path}: {error}")
    if not isinstance(summary, dict):
        fail(f"Task3 summary is not an object: {path}")
    fields = ("success_rate", "inference_us", "round_trip_us", "rtos_processing_us")
    if any(field not in summary for field in fields):
        fail(f"Task3 summary is missing comparison fields: {path}")
    return {field: summary[field] for field in fields}


def parse_manifest(path: Path, expected_guest: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        artifact = re.fullmatch(
            r"ARTIFACT name=([^\s]+) path=([^\s]+) sha256=([0-9a-f]{64})", line
        )
        if artifact:
            key = f"artifact:{artifact.group(1)}"
            if key in values:
                fail(f"duplicate manifest artifact {artifact.group(1)}: {path}")
            values[key] = artifact.group(3)
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    if values.get("app_guest") != expected_guest:
        fail(f"manifest app_guest does not match {expected_guest}: {path}")
    if values.get("result_gate") != "PASS":
        fail(f"manifest is not result-gate authenticated: {path}")
    return values


def parse_host_metrics(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"elapsed_ms", "cpu_time_ms", "peak_rss_kb", "max_threads", "sample_count"}:
            values[key] = int(value)
    required = {"elapsed_ms", "cpu_time_ms", "peak_rss_kb", "max_threads", "sample_count"}
    if not required.issubset(values):
        fail(f"host metrics are incomplete: {path}")
    return values


def guest_log(run_dir: Path, guest: str) -> Path:
    path = run_dir / f"{guest}.log"
    if not path.is_file() and guest == "linux":
        path = run_dir / "app.log"
    if not path.is_file():
        fail(f"authenticated application log is missing: {path}")
    return path


def load_guest(run_dir: Path, guest: str) -> dict[str, Any]:
    return {
        "app_guest": guest,
        "run_dir": str(run_dir.resolve()),
        "manifest": parse_manifest(run_dir / "manifest.txt", guest),
        "task2": parse_task2(guest_log(run_dir, guest)),
        "task3": parse_summary(run_dir / "summary.json"),
        "rtbench": parse_rtbench(run_dir / "rtthread.log"),
        "host": parse_host_metrics(run_dir / "host-metrics.txt"),
    }


def relative_percent(baseline: int | float, candidate: int | float) -> float | None:
    if baseline == 0:
        return None
    return round((candidate - baseline) * 100.0 / baseline, 4)


def compare_values(baseline: int | float, candidate: int | float) -> dict[str, Any]:
    return {
        "linux": baseline,
        "starryos": candidate,
        "starryos_vs_linux_percent": relative_percent(baseline, candidate),
    }


def compare_guests(linux: dict[str, Any], starryos: dict[str, Any]) -> dict[str, Any]:
    for field in ("mode", "task2_count", "task3_frames", "task3_fault", "qemu_timer_slack_ns"):
        if linux["manifest"].get(field) != starryos["manifest"].get(field):
            fail(
                f"guest manifests disagree on {field}: "
                f"{linux['manifest'].get(field)!r} != {starryos['manifest'].get(field)!r}"
            )
    for artifact in SHARED_ARTIFACTS:
        left = linux["manifest"].get(f"artifact:{artifact}")
        right = starryos["manifest"].get(f"artifact:{artifact}")
        if left is None or right is None:
            fail(f"shared artifact {artifact} is missing from a manifest")
        if left != right:
            fail(f"shared artifact {artifact} differs between guest runs")

    task2: dict[str, Any] = {"payloads": {}}
    for payload in ("64", "256", "1024"):
        left = linux["task2"]["payloads"][payload]
        right = starryos["task2"]["payloads"][payload]
        task2["payloads"][payload] = {
            "rtt_ms": {
                key: compare_values(left["rtt_ms"][key], right["rtt_ms"][key])
                for key in RTT_KEYS
            },
            "throughput_bytes_per_s": compare_values(
                left["throughput_bytes_per_s"], right["throughput_bytes_per_s"]
            ),
            "sent": compare_values(left["sent"], right["sent"]),
            "received": compare_values(left["received"], right["received"]),
            "application": {
                key: compare_values(left["application"][key], right["application"][key])
                for key in left["application"]
            },
            "transport": {
                key: compare_values(left["transport"][key], right["transport"][key])
                for key in left["transport"]
            },
        }

    task3: dict[str, Any] = {}
    for metric_name in ("inference_us", "round_trip_us", "rtos_processing_us"):
        task3[metric_name] = {
            key: compare_values(
                linux["task3"][metric_name][key], starryos["task3"][metric_name][key]
            )
            for key in linux["task3"][metric_name]
        }
    task3["success_rate"] = compare_values(
        linux["task3"]["success_rate"], starryos["task3"]["success_rate"]
    )

    rtbench: dict[str, Any] = {}
    for metric_name in sorted(set(linux["rtbench"]) & set(starryos["rtbench"])):
        rtbench[metric_name] = {
            output_field: compare_values(
                linux["rtbench"][metric_name][source_field],
                starryos["rtbench"][metric_name][source_field],
            )
            for output_field, source_field in {
                "p50": "p50_ns",
                "p95": "p95_ns",
                "p99": "p99_ns",
                "p99.9": "p99_9_ns",
                "max": "max_ns",
                "mean": "mean_ns",
                "miss_1ms": "miss_1ms",
            }.items()
        }

    host = {
        field: compare_values(linux["host"][field], starryos["host"][field])
        for field in ("elapsed_ms", "cpu_time_ms", "peak_rss_kb", "max_threads", "sample_count")
    }
    return {"task2": task2, "task3": task3, "rtbench": rtbench, "host": host}


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.4f}".rstrip("0").rstrip(".")
    return str(value)


def report(data: dict[str, Any]) -> str:
    linux = data["guests"]["linux"]
    starryos = data["guests"]["starryos"]
    comparison = data["comparison"]
    lines = [
        "# StarryOS 与 Linux 长时间稳定性与性能对比",
        "",
        "本报告基于同一 AxVisor/QEMU/RT-Thread 配置的两次独立运行。百分比为",
        "(StarryOS - Linux) / Linux * 100%；负值表示 StarryOS 数值更低。QEMU TCG",
        "结果用于工程对比，不是物理硬实时上界。",
        "",
        "## 运行输入",
        "",
        f"- Linux run: '{linux['run_dir']}'",
        f"- StarryOS run: '{starryos['run_dir']}'",
        f"- Linux mode: '{linux['manifest'].get('mode', 'unknown')}'",
        f"- StarryOS mode: '{starryos['manifest'].get('mode', 'unknown')}'",
        "",
        "## Task2 RTT",
        "",
        "| 载荷 | 指标 | Linux | StarryOS | StarryOS 相对 Linux |",
        "|---:|---|---:|---:|---:|",
    ]
    for payload in ("64", "256", "1024"):
        for metric_name in ("avg", "p95", "p99", "p99.9", "max"):
            value = comparison["task2"]["payloads"][payload]["rtt_ms"][metric_name]
            lines.append(
                f"| {payload} B | RTT {metric_name} (ms) | {fmt(value['linux'])} | "
                f"{fmt(value['starryos'])} | {fmt(value['starryos_vs_linux_percent'])}% |"
            )
    lines += [
        "",
        "## Task3 与 RTBench",
        "",
        "| 指标 | Linux | StarryOS | 相对变化 |",
        "|---|---:|---:|---:|",
    ]
    for metric_name in ("round_trip_us", "inference_us", "rtos_processing_us"):
        value = comparison["task3"][metric_name]["mean"]
        lines.append(
            f"| Task3 {metric_name} mean (us) | {fmt(value['linux'])} | "
            f"{fmt(value['starryos'])} | {fmt(value['starryos_vs_linux_percent'])}% |"
        )
    for metric_name in ("stability_jitter", "callback_exec"):
        value = comparison["rtbench"][metric_name]["p99"]
        lines.append(
            f"| RTBench {metric_name} P99 (ns) | {fmt(value['linux'])} | "
            f"{fmt(value['starryos'])} | {fmt(value['starryos_vs_linux_percent'])}% |"
        )
    lines += [
        "",
        "## 宿主 QEMU 资源",
        "",
        "| 指标 | Linux | StarryOS | 相对变化 |",
        "|---|---:|---:|---:|",
    ]
    for field in ("elapsed_ms", "cpu_time_ms", "peak_rss_kb", "max_threads", "sample_count"):
        value = comparison["host"][field]
        lines.append(
            f"| {field} | {fmt(value['linux'])} | {fmt(value['starryos'])} | "
            f"{fmt(value['starryos_vs_linux_percent'])}% |"
        )
    lines += [
        "",
        "## 解释边界",
        "",
        "- 两次运行顺序、宿主负载和 TCG 翻译缓存状态会引入误差。",
        "- miss_1ms、panic/assert/fatal 和请求完整性仍以各自 run 的结果门禁为准。",
        "- 本文件只汇总已通过门禁的原始结果，不把平均值替代最坏情况。",
        "",
    ]
    return "\n".join(lines)


def write_atomic(path: Path, content: str) -> None:
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux-run", type=Path, required=True)
    parser.add_argument("--starryos-run", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    linux = load_guest(args.linux_run, "linux")
    starryos = load_guest(args.starryos_run, "starryos")
    data = {
        "schema": 1,
        "guests": {"linux": linux, "starryos": starryos},
        "comparison": compare_guests(linux, starryos),
    }
    write_atomic(
        args.output / "comparison.json",
        json.dumps(data, ensure_ascii=True, sort_keys=True, indent=2) + "\n",
    )
    write_atomic(args.output / "comparison-report.md", report(data))
    print(args.output / "comparison.json")
    print(args.output / "comparison-report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
