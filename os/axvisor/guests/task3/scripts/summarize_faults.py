#!/usr/bin/env python3
"""Validate fault evidence and emit a machine-readable suite summary."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

try:
    from scripts.summarize import write_json_atomic
except ModuleNotFoundError:
    from summarize import write_json_atomic


CASES = (
    "drop-control",
    "drop-status",
    "duplicate-frame",
    "delayed-server",
    "malformed",
)
FIELDS = (
    "case",
    "result",
    "transport_retries",
    "duplicates",
    "application_errors",
    "applied_delta",
)


def _integer(text: str, field: str) -> int:
    try:
        value = int(text, 10)
    except ValueError as error:
        raise ValueError(f"invalid integer: {field}") from error
    if value < 0:
        raise ValueError(f"negative integer: {field}")
    return value


def parse_events(path: Path) -> list[dict[str, object]]:
    with path.open(newline="", encoding="ascii") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("unexpected fault event columns")
        events: list[dict[str, object]] = []
        seen: set[str] = set()
        for row in reader:
            case_name = row["case"]
            if case_name not in CASES:
                raise ValueError(f"unknown fault case: {case_name}")
            if case_name in seen:
                raise ValueError(f"duplicate fault case: {case_name}")
            seen.add(case_name)
            result = row["result"]
            if result not in ("recovered", "rejected"):
                raise ValueError(f"invalid result: {case_name}")
            event: dict[str, object] = {"case": case_name, "result": result}
            for field in ("transport_retries", "duplicates", "application_errors"):
                event[field] = _integer(row[field], field)
            event["applied_delta"] = (
                None if row["applied_delta"] == "" else _integer(row["applied_delta"], "applied_delta")
            )
            events.append(event)
    missing = set(CASES) - seen
    if missing:
        raise ValueError(f"missing fault cases: {sorted(missing)}")
    return events


def summarize_events(events: list[dict[str, object]]) -> dict[str, object]:
    by_case = {str(event["case"]): dict(event) for event in events}
    if set(by_case) != set(CASES):
        raise ValueError("missing or duplicate fault cases")
    for case_name in ("duplicate-frame", "malformed"):
        if by_case[case_name]["applied_delta"] != 0:
            raise ValueError(f"unsafe applied delta: {case_name}")
    if by_case["drop-control"]["transport_retries"] < 1:
        raise ValueError("drop-control did not exercise retransmission")
    if by_case["drop-status"]["transport_retries"] < 1:
        raise ValueError("drop-status did not exercise retransmission")
    if by_case["duplicate-frame"]["duplicates"] < 1:
        raise ValueError("duplicate-frame was not observed")
    if by_case["malformed"]["application_errors"] < 2:
        raise ValueError("malformed application errors were not observed")
    return {
        "schema": 1,
        "all_passed": True,
        "cases": {
            name: {key: value for key, value in by_case[name].items() if key != "case"}
            for name in CASES
        },
    }


def _last_rtos_final(log: str) -> dict[str, int]:
    matches = re.findall(r"TASK3_RTOS_FINAL ([^\r\n]+)", log)
    if not matches:
        raise ValueError("missing TASK3_RTOS_FINAL")
    values = dict(re.findall(r"([a-z_]+)=(\d+)", matches[-1]))
    required = ("errors", "duplicates", "applied_steps", "retries")
    if any(name not in values for name in required):
        raise ValueError("incomplete TASK3_RTOS_FINAL")
    return {name: int(values[name], 10) for name in required}


def _marker_delta(log: str, marker: str) -> int:
    match = re.search(rf"^{marker} .*applied_delta=(\d+)$", log, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing {marker}")
    return int(match.group(1), 10)


def collect_event(case_name: str, case_dir: Path) -> dict[str, object]:
    summary = json.loads((case_dir / "summary.json").read_text(encoding="ascii"))
    raw_summary = json.loads(
        (case_dir / "summary.raw.json").read_text(encoding="ascii")
    )
    linux_log = (case_dir / "linux.log").read_text(encoding="ascii", errors="strict")
    rtos_log = (case_dir / "rtthread.log").read_text(encoding="ascii", errors="strict")
    if summary.get("success_rate") != 1.0:
        raise ValueError(f"fault run did not recover: {case_name}")
    final = _last_rtos_final(rtos_log)
    event: dict[str, object] = {
        "case": case_name,
        "result": "rejected" if case_name == "malformed" else "recovered",
        "transport_retries": int(summary["transport_retries"]),
        "duplicates": final["duplicates"],
        "application_errors": final["errors"],
        "applied_delta": None,
    }
    if case_name == "drop-control":
        if int(raw_summary.get("injected_drops", 0)) < 1:
            raise ValueError("drop-control marker/counter missing")
    elif case_name == "drop-status":
        if "TASK3_FAULT_DROP_STATUS dropped=1" not in rtos_log:
            raise ValueError("drop-status marker missing")
    elif case_name == "duplicate-frame":
        event["applied_delta"] = _marker_delta(linux_log, "TASK3_FAULT_DUPLICATE")
    elif case_name == "delayed-server":
        if "TASK3_FAULT_DELAYED_SERVER" not in linux_log:
            raise ValueError("delayed-server marker missing")
    elif case_name == "malformed":
        event["applied_delta"] = _marker_delta(linux_log, "TASK3_FAULT_MALFORMED")
        if "schema2=rejected short=rejected crc=rejected" not in linux_log:
            raise ValueError("malformed rejection marker incomplete")
    return event


def write_events(path: Path, events: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="ascii") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        for event in events:
            writer.writerow(event)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite-dir", type=Path, required=True)
    args = parser.parse_args()
    events = [collect_event(name, args.suite_dir / name) for name in CASES]
    events_path = args.suite_dir / "fault-events.csv"
    write_events(events_path, events)
    summary = summarize_events(parse_events(events_path))
    for name in CASES:
        summary["cases"][name]["run_dir"] = str((args.suite_dir / name).resolve())
    output = args.suite_dir / "fault-summary.json"
    write_json_atomic(output, summary)
    print(f"fault_summary={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
