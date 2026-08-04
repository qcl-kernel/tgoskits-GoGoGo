#!/usr/bin/env python3
"""Keep the RTOS real-time report and plot synchronized with the CSV."""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Optional


SCRIPT_DIR = Path(__file__).resolve().parent
CSV = SCRIPT_DIR / "rtos-realtime-iterations.csv"
REPORT = SCRIPT_DIR / "rtos-realtime-report.md"
RUNNER = SCRIPT_DIR / "test_rtos_realtime_plot.sh"
MODULE_PATH = SCRIPT_DIR / "plot_rtos_realtime_iterations.py"
SPEC = importlib.util.spec_from_file_location("rtos_realtime_plot", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load plot module: {MODULE_PATH}")
PLOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLOT)


def parse_iterations(cell: str) -> list[int]:
    """Expand one Markdown iteration cell into its CSV iteration numbers."""
    match = re.fullmatch(r"(\d+)(?:--(\d+))?", cell.strip())
    if match is None:
        raise ValueError(f"invalid iteration cell: {cell!r}")
    first = int(match.group(1))
    last = int(match.group(2) or first)
    if last < first:
        raise ValueError(f"descending iteration range: {cell!r}")
    return list(range(first, last + 1))


def parse_p99_9_values(cell: str, count: int) -> list[Optional[float]]:
    """Parse a report p99.9 cell and repeat a singleton across a range."""
    values = []
    for token in cell.strip().split("/"):
        value = token.strip()
        if value.endswith(" us"):
            value = value[:-3].strip()
        values.append(None if value == "NA" else float(value))
    if len(values) == 1:
        values *= count
    if len(values) != count:
        raise ValueError(
            f"p99.9 value count {len(values)} does not match {count} iterations: {cell!r}"
        )
    return values


def load_report_p99_9() -> dict[int, Optional[float]]:
    """Read p99.9 values from the report's iteration summary table."""
    values = {}
    in_summary = False
    for line in REPORT.read_text(encoding="utf-8").splitlines():
        if line.startswith("| 轮次 | 场景 |"):
            in_summary = True
            continue
        if not in_summary:
            continue
        if not line.startswith("|"):
            break

        cells = [cell.strip() for cell in line.strip().split("|")[1:-1]]
        if not cells or cells[0].startswith("---"):
            continue
        iterations = parse_iterations(cells[0])
        p99_9_values = parse_p99_9_values(cells[4], len(iterations))
        values.update(zip(iterations, p99_9_values))
    return values


class ReportArtifactTests(unittest.TestCase):
    @unittest.skipIf(
        os.environ.get("RTBENCH_HOSTILE_SCRIPT_DIR_CHILD") == "1",
        "avoid recursively invoking the plot test runner",
    )
    def test_runner_ignores_inherited_script_dir(self) -> None:
        with tempfile.TemporaryDirectory() as hostile_script_dir:
            environment = os.environ.copy()
            environment["SCRIPT_DIR"] = hostile_script_dir
            environment["RTBENCH_HOSTILE_SCRIPT_DIR_CHILD"] = "1"
            result = subprocess.run(
                ["bash", str(RUNNER)],
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[rtbench-plot] source contract passed", result.stdout)

    def test_report_p99_9_matches_csv(self) -> None:
        rows = PLOT.load_rows(CSV)
        csv_values = {
            int(row["iteration"]): PLOT.parse_number(row["p99_9_us"])
            for row in rows
        }
        for iteration, report_value in load_report_p99_9().items():
            with self.subTest(iteration=iteration):
                self.assertIn(iteration, csv_values)
                self.assertEqual(
                    report_value,
                    csv_values[iteration],
                    f"iteration {iteration} p99.9 drift",
                )

    def test_checked_in_plot_matches_complete_csv(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fresh = Path(temp_dir) / "rtos-realtime-iterations.png"
            PLOT.plot_rtos_realtime_iterations(CSV, fresh)
            self.assertEqual(
                fresh.read_bytes(),
                PLOT.DEFAULT_OUTPUT.read_bytes(),
                "checked-in PNG is stale",
            )


if __name__ == "__main__":
    unittest.main()
