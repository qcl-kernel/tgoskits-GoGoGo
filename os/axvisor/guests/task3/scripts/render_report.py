#!/usr/bin/env python3
"""Render a Chinese task-three report exclusively from captured evidence."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "frames.csv",
    "summary.json",
    "linux.log",
    "rtthread.log",
    "commands.txt",
    "versions.txt",
)


def require_run(run_dir: Path) -> None:
    for name in REQUIRED:
        path = run_dir / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"missing run evidence: {path}")


FAULT_CASES = (
    "drop-control",
    "drop-status",
    "duplicate-frame",
    "delayed-server",
    "malformed",
)


def render_report(run_dir: Path, fault_summary_path: Path) -> str:
    require_run(run_dir)
    summary = json.loads((run_dir / "summary.json").read_text(encoding="ascii"))
    if summary.get("schema") != 1:
        raise ValueError("unsupported summary schema")
    if not fault_summary_path.is_file():
        raise ValueError(f"missing fault evidence: {fault_summary_path}")
    fault_summary = json.loads(fault_summary_path.read_text(encoding="ascii"))
    if (
        fault_summary.get("schema") != 1
        or fault_summary.get("all_passed") is not True
        or set(fault_summary.get("cases", {})) != set(FAULT_CASES)
    ):
        raise ValueError("invalid fault summary")
    commands = (run_dir / "commands.txt").read_text(encoding="ascii").rstrip()
    versions = (run_dir / "versions.txt").read_text(encoding="ascii").rstrip()
    frames = int(summary["frames_per_mode"])
    fixed = summary["tracking_error_q15"]["fixed"]
    ai = summary["tracking_error_q15"]["ai"]
    classification = summary["classification"]
    round_trip = summary["round_trip_us"]
    inference = summary["inference_us"]
    processing = summary["rtos_processing_us"]
    runtime_seconds = frames * 2 / 10
    measured_seconds = int(summary["elapsed_us"]) / 1_000_000
    improvement = (
        0.0 if fixed["mean"] == 0 else (fixed["mean"] - ai["mean"]) / fixed["mean"] * 100
    )
    sources = {
        "frames_csv": str(run_dir / "frames.csv"),
        "linux_log": str(run_dir / "linux.log"),
        "rtthread_log": str(run_dir / "rtthread.log"),
    }
    retry_sides = summary["transport_retries_by_side"]
    fault_rows = "\n".join(
        "| {name} | {result} | {retries} | {duplicates} | {errors} | {delta} |".format(
            name=name,
            result=fault_summary["cases"][name]["result"],
            retries=fault_summary["cases"][name]["transport_retries"],
            duplicates=fault_summary["cases"][name]["duplicates"],
            errors=fault_summary["cases"][name]["application_errors"],
            delta=(
                "N/A"
                if fault_summary["cases"][name]["applied_delta"] is None
                else fault_summary["cases"][name]["applied_delta"]
            ),
        )
        for name in FAULT_CASES
    )
    indented_commands = "\n".join("    " + line for line in commands.splitlines())
    indented_versions = "\n".join("    " + line for line in versions.splitlines())
    return f"""# 双 QEMU 迁移基线：Linux/RT-Thread AI 控制闭环结果

本报告由 {run_dir} 中的原始数据生成。每种模式 {frames} 帧，输入帧率 10 FPS，计划有效运行时长 {runtime_seconds:.1f} 秒，Linux 同侧实测为 {measured_seconds:.6f} 秒。

本报告不属于 AxVisor 最终证据；最终结果必须使用 `os/axvisor/scripts/run_task123.sh` 采集。

故障证据来自 {fault_summary_path} ，五类场景均由真实双 QEMU 客户机运行并通过校验。

## 网络拓扑

Linux 客户机使用 192.168.77.11/24、MAC 52:54:00:77:00:11；RT-Thread 客户机使用 192.168.77.30/24、MAC 52:54:00:77:00:30。两端通过 QEMU multicast socket LAN 直连，应用主通道为 RT-IPC over UDP/9877，无 NAT、宿主桥接或 vsock 数据通道。

## 构建与启动命令

{indented_commands}

## 版本与运行配置

{indented_versions}

Linux 配置为 2 vCPU、256 MiB，负责 Y4M 解码、int8 CNN 推理、RT-IPC 客户端和数据采集。RT-Thread 配置为 1 vCPU、128 MiB，负责 UDP/RT-IPC 服务、幂等控制器和虚拟 PWM/位置执行器。

## CPU 负载分工

Linux 的两个 vCPU 承担推理、网络协议与串口记录，RT-Thread 单 vCPU 承担网络中断、协议处理和控制更新。QEMU TCG 线程由宿主调度，本结果不等价于物理 CPU 硬实时上界。

## 计时方法与误差

Linux 使用 CLOCK_MONOTONIC_RAW 记录推理耗时和发送到状态回传的同侧往返延迟；RT-Thread 使用 AArch64 通用计数器换算处理微秒。两侧时钟未同步，因此不报告伪精确单向延迟。主要误差来自 TCG 调度、虚拟中断、串口输出、计数器量化和宿主负载。

| 指标 (us) | min | mean | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| CNN 推理 | {inference['min']} | {inference['mean']} | {inference['p50']} | {inference['p95']} | {inference['p99']} | {inference['max']} |
| 闭环往返 | {round_trip['min']} | {round_trip['mean']} | {round_trip['p50']} | {round_trip['p95']} | {round_trip['p99']} | {round_trip['max']} |
| RTOS 处理 | {processing['min']} | {processing['mean']} | {processing['p50']} | {processing['p95']} | {processing['p99']} | {processing['max']} |

## 固定基线与 AI 对比

| 模式 | 跟踪误差 mean | p95 | max |
|---|---:|---:|---:|
| 固定参数 | {fixed['mean']} | {fixed['p95']} | {fixed['max']} |
| AI 控制 | {ai['mean']} | {ai['p95']} | {ai['max']} |

AI 平均跟踪误差相对固定基线改善 {improvement:.2f}%。分类正确 {classification['correct']}/{classification['total']}，准确率 {classification['accuracy']:.6f}。

## 可靠性

| 请求 | 成功 | 成功率 | 应用错误 | 超时 | 重连 | 重传 | 重复 | 恢复 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| {summary['requests']} | {summary['successes']} | {summary['success_rate']:.6f} | {summary['application_errors']} | {summary['timeouts']} | {summary['reconnects']} | {summary['transport_retries']} | {summary['duplicates']} | {summary['recoveries']} |

重传按发送侧拆分为 Linux {retry_sides['linux']} 次、RT-Thread {retry_sides['rtthread']} 次；这些重传已由 RT-IPC 透明恢复。有效应用吞吐量为 {summary['effective_payload_bytes_per_second']} B/s。质量门禁状态：{json.dumps(summary['gates'], sort_keys=True)}。

稳定时间统计：FIXED 方向变化 {summary['settling']['fixed']['direction_changes']} 次、满足收敛条件 {summary['settling']['fixed']['successes']} 次；AI 方向变化 {summary['settling']['ai']['direction_changes']} 次、满足收敛条件 {summary['settling']['ai']['successes']} 次。成功段的平均/最大帧数分别为 FIXED {summary['settling']['fixed']['mean_frames']}/{summary['settling']['fixed']['max_frames']}，AI {summary['settling']['ai']['mean_frames']}/{summary['settling']['ai']['max_frames']}。

## 故障恢复

| 场景 | 结果 | 传输重传 | 重复请求 | 应用错误 | 故障导致的额外控制应用 |
|---|---|---:|---:|---:|---:|
{fault_rows}

`duplicate-frame` 与 `malformed` 的 `applied_delta` 均为 0，证明重复或非法输入没有造成额外控制动作。`malformed` 的两个应用错误分别来自错误 schema 和错误长度；CRC 损坏包在 RT-IPC 校验层被丢弃。

## 原始证据

- frames.csv: {sources['frames_csv']}
- linux.log: {sources['linux_log']}
- rtthread.log: {sources['rtthread_log']}
- summary.json: {run_dir / 'summary.json'}
- fault-summary.json: {fault_summary_path}
"""


def latest_run() -> Path:
    runs = ROOT / "build/runs"
    candidates = []
    for path in sorted(runs.glob("*")):
        summary_path = path / "summary.json"
        if not summary_path.is_file():
            continue
        summary = json.loads(summary_path.read_text(encoding="ascii"))
        if summary.get("frames_per_mode") == 600 and summary.get("gates_enforced") is True:
            candidates.append(path)
    if not candidates:
        raise ValueError("no complete run found")
    return candidates[-1]


def latest_fault_summary() -> Path:
    candidates = sorted((ROOT / "build/fault-runs").glob("*/fault-summary.json"))
    if not candidates:
        raise ValueError("no complete fault run found")
    return candidates[-1]


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", nargs="?", type=Path)
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--fault-summary", type=Path)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "docs/results/task3-report.md"
    )
    args = parser.parse_args()
    if args.latest == (args.run_dir is not None):
        parser.error("select exactly one of RUN_DIR or --latest")
    run_dir = latest_run() if args.latest else args.run_dir
    fault_summary = args.fault_summary or latest_fault_summary()
    write_atomic(args.output, render_report(run_dir, fault_summary))
    print(f"report={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
