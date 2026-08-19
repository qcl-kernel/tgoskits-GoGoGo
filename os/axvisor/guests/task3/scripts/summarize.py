#!/usr/bin/env python3
"""Validate raw task-three CSV evidence and derive a strict JSON summary."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import tempfile
from pathlib import Path


FIELDS = [
    "mode",
    "frame_id",
    "target_q15",
    "truth_class",
    "predicted_class",
    "confidence_q15",
    "inference_us",
    "transport_retries",
    "rtos_status",
    "pwm",
    "actuator_q15",
    "rtos_processing_us",
    "round_trip_us",
    "error_code",
    "duplicate",
    "recovered",
]
INTEGER_FIELDS = FIELDS[1:]


def nearest_rank(values: list[int], percentile: int) -> int:
    if not values:
        raise ValueError("metric has no samples")
    ordered = sorted(values)
    rank = math.ceil(len(ordered) * percentile / 100)
    return ordered[max(0, rank - 1)]


def metric(values: list[int]) -> dict[str, int]:
    if not values:
        raise ValueError("metric has no samples")
    return {
        "min": min(values),
        "mean": sum(values) // len(values),
        "p50": nearest_rank(values, 50),
        "p95": nearest_rank(values, 95),
        "p99": nearest_rank(values, 99),
        "max": max(values),
    }


def parse_rtos_final(path: Path) -> dict[str, int]:
    log = path.read_text(encoding="ascii")
    matches = re.findall(r"TASK3_RTOS_FINAL ([^\r\n]+)", log)
    if not matches:
        raise ValueError("missing TASK3_RTOS_FINAL")
    values = dict(re.findall(r"([a-z_]+)=(\d+)", matches[-1]))
    required = ("requests", "errors", "duplicates", "applied_steps", "retries")
    if any(name not in values for name in required):
        raise ValueError("incomplete TASK3_RTOS_FINAL")
    return {name: int(values[name], 10) for name in required}


def parse_raw_summary(path: Path, frames_per_mode: int) -> dict[str, object]:
    raw = json.loads(path.read_text(encoding="ascii"))
    expected_records = frames_per_mode * 2
    if (
        raw.get("schema") != 1
        or raw.get("frames_per_mode") != frames_per_mode
        or raw.get("records") != expected_records
        or raw.get("requests") != expected_records
        or raw.get("successes") != expected_records
        or raw.get("success_rate") != 1.0
        or raw.get("application_errors") != 0
    ):
        raise ValueError("raw guest summary does not match frame evidence")
    for field in ("application_timeouts", "reconnects", "injected_drops", "elapsed_us"):
        if not isinstance(raw.get(field), int) or raw[field] < 0:
            raise ValueError(f"invalid raw summary field: {field}")
    if raw["elapsed_us"] == 0:
        raise ValueError("raw elapsed time is zero")
    settling = raw.get("settling")
    if not isinstance(settling, dict) or set(settling) != {"fixed", "ai"}:
        raise ValueError("invalid raw settling summary")
    return raw


def parse_frames(path: Path, frames_per_mode: int) -> list[dict[str, int | str]]:
    with path.open("r", newline="", encoding="ascii") as stream:
        if stream.readline().rstrip("\r\n") != "# task3_csv_schema=1":
            raise ValueError("missing task3 CSV schema header")
        reader = csv.DictReader(stream)
        if reader.fieldnames != FIELDS:
            raise ValueError("unexpected frame CSV columns")
        rows: list[dict[str, int | str]] = []
        seen: set[tuple[str, int]] = set()
        for raw in reader:
            row: dict[str, int | str] = {"mode": raw["mode"]}
            if row["mode"] not in ("FIXED", "AI"):
                raise ValueError("invalid mode")
            for field in INTEGER_FIELDS:
                try:
                    row[field] = int(raw[field], 10)
                except (TypeError, ValueError) as error:
                    raise ValueError(f"invalid integer field: {field}") from error
            frame_id = int(row["frame_id"])
            if not 0 <= frame_id < frames_per_mode:
                raise ValueError("frame id out of range")
            if not -32768 <= int(row["target_q15"]) <= 32767:
                raise ValueError("target_q15 out of range")
            if not -32768 <= int(row["actuator_q15"]) <= 32767:
                raise ValueError("actuator_q15 out of range")
            if not 1 <= int(row["truth_class"]) <= 3:
                raise ValueError("truth class out of range")
            if not 1 <= int(row["predicted_class"]) <= 3:
                raise ValueError("predicted class out of range")
            key = (str(row["mode"]), frame_id)
            if key in seen:
                raise ValueError(f"duplicate frame row: {key}")
            seen.add(key)
            rows.append(row)
    expected = {(mode, frame) for mode in ("FIXED", "AI") for frame in range(frames_per_mode)}
    if seen != expected:
        raise ValueError("missing frame rows")
    return rows


def summarize(run_dir: Path, frames_per_mode: int, smoke: bool) -> dict[str, object]:
    rows = parse_frames(run_dir / "frames.csv", frames_per_mode)
    rtos_final = parse_rtos_final(run_dir / "rtthread.log")
    raw_summary = parse_raw_summary(run_dir / "summary.raw.json", frames_per_mode)
    fixed = [row for row in rows if row["mode"] == "FIXED"]
    ai = [row for row in rows if row["mode"] == "AI"]
    successful = [row for row in rows if int(row["error_code"]) == 0]
    correct = sum(int(row["truth_class"]) == int(row["predicted_class"]) for row in ai)
    confusion = [[0, 0, 0] for _ in range(3)]
    for row in ai:
        confusion[int(row["truth_class"]) - 1][int(row["predicted_class"]) - 1] += 1
    fixed_error = [
        abs(int(row["target_q15"]) - int(row["actuator_q15"])) for row in fixed
    ]
    ai_error = [
        abs(int(row["target_q15"]) - int(row["actuator_q15"])) for row in ai
    ]
    elapsed_us = int(raw_summary["elapsed_us"])
    success_rate = len(successful) / len(rows)
    accuracy = correct / len(ai)
    linux_retries = sum(int(row["transport_retries"]) for row in rows)
    summary: dict[str, object] = {
        "schema": 1,
        "frames_per_mode": frames_per_mode,
        "requests": len(rows),
        "successes": len(successful),
        "success_rate": success_rate,
        "application_errors": len(rows) - len(successful),
        "timeouts": int(raw_summary["application_timeouts"]),
        "reconnects": int(raw_summary["reconnects"]),
        "injected_drops": int(raw_summary["injected_drops"]),
        "elapsed_us": elapsed_us,
        "transport_retries": linux_retries + rtos_final["retries"],
        "transport_retries_by_side": {
            "linux": linux_retries,
            "rtthread": rtos_final["retries"],
        },
        "duplicates": sum(int(row["duplicate"]) for row in rows),
        "recoveries": sum(int(row["recovered"]) for row in rows),
        "classification": {
            "correct": correct,
            "total": len(ai),
            "accuracy": accuracy,
            "confusion_matrix": confusion,
        },
        "inference_us": metric([int(row["inference_us"]) for row in successful]),
        "round_trip_us": metric([int(row["round_trip_us"]) for row in successful]),
        "rtos_processing_us": metric(
            [int(row["rtos_processing_us"]) for row in successful]
        ),
        "tracking_error_q15": {
            "fixed": metric(fixed_error),
            "ai": metric(ai_error),
        },
        "settling": raw_summary["settling"],
        "effective_payload_bytes_per_second": int(
            len(successful) * 24 * 1_000_000 / elapsed_us
        ),
        "sources": {
            "frames_csv": str((run_dir / "frames.csv").resolve()),
            "linux_log": str((run_dir / "linux.log").resolve()),
            "rtthread_log": str((run_dir / "rtthread.log").resolve()),
        },
        "gates_enforced": frames_per_mode == 600 and not smoke,
    }
    gates = {
        "success_rate_at_least_99_5_percent": success_rate >= 0.995,
        "classification_accuracy_at_least_95_percent": accuracy >= 0.95,
        "ai_tracking_mae_improves_at_least_30_percent": (
            metric(ai_error)["mean"] <= metric(fixed_error)["mean"] * 0.70
        ),
    }
    summary["gates"] = gates
    if summary["gates_enforced"] and not all(gates.values()):
        raise ValueError(f"normal-run quality gate failed: {gates}")
    return summary


def write_json_atomic(path: Path, value: object) -> None:
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--frames-per-mode", type=int, required=True)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    summary = summarize(args.run_dir, args.frames_per_mode, args.smoke)
    write_json_atomic(args.run_dir / "summary.json", summary)
    print(f"summary={args.run_dir / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
