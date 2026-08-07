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

SUMMARY_HEADER_PREFIX = "| 轮次 | 场景 |"
SUMMARY_COLUMN_COUNT = 9


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


def load_report_percentile(
    column_index: int,
    percentile_name: str,
    report_path: Path = REPORT,
) -> dict[int, Optional[float]]:
    """Read one percentile column from the report's iteration summary table."""
    lines = report_path.read_text(encoding="utf-8").splitlines()
    summary_headers = [
        index for index, line in enumerate(lines) if line.startswith(SUMMARY_HEADER_PREFIX)
    ]
    if not summary_headers:
        raise ValueError("summary table not found")
    if len(summary_headers) != 1:
        raise ValueError("multiple summary tables found")

    header_index = summary_headers[0]
    header_cells = lines[header_index].strip().split("|")[1:-1]
    if len(header_cells) != SUMMARY_COLUMN_COUNT:
        raise ValueError(
            f"summary table header: expected {SUMMARY_COLUMN_COUNT} columns, "
            f"found {len(header_cells)}"
        )

    values = {}
    data_rows = 0
    for line in lines[header_index + 1 :]:
        if not line.startswith("|"):
            break

        cells = [cell.strip() for cell in line.strip().split("|")[1:-1]]
        if len(cells) != SUMMARY_COLUMN_COUNT:
            raise ValueError(
                f"summary table row: expected {SUMMARY_COLUMN_COUNT} columns, "
                f"found {len(cells)}"
            )
        if cells[0].startswith("---"):
            continue
        data_rows += 1
        iterations = parse_iterations(cells[0])
        percentile_values = parse_p99_9_values(cells[column_index], len(iterations))
        for iteration, percentile_value in zip(iterations, percentile_values):
            if iteration in values:
                raise ValueError(f"duplicate iteration {iteration} in summary table")
            values[iteration] = percentile_value
    if data_rows == 0:
        raise ValueError("summary table contains no data rows")
    return values


def load_report_p99_9(report_path: Path = REPORT) -> dict[int, Optional[float]]:
    """Read p99.9 values from the report's iteration summary table."""
    return load_report_percentile(4, "p99.9", report_path)


def load_report_p99(report_path: Path = REPORT) -> dict[int, Optional[float]]:
    """Read p99 values from the report's iteration summary table."""
    return load_report_percentile(3, "p99", report_path)


class ReportParserValidationTests(unittest.TestCase):
    HEADER = (
        "| 轮次 | 场景 | 回调/预期 | p99 | p99.9 | 最大延迟 | "
        ">100 us | >500 us | >1 ms |"
    )
    RULE = "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"

    def load_report_text(self, report_text: str) -> dict[int, Optional[float]]:
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "report.md"
            report_path.write_text(report_text, encoding="utf-8")
            return load_report_p99_9(report_path)

    def test_rejects_missing_summary_table(self) -> None:
        with self.assertRaisesRegex(ValueError, "summary table not found"):
            self.load_report_text("# Report without an iteration summary\n")

    def test_rejects_multiple_summary_tables(self) -> None:
        report = "\n".join(
            (
                self.HEADER,
                self.RULE,
                "| 1 | first | 1/1 | 0 us | 0 us | 0 us | 0 | 0 | 0 |",
                "",
                self.HEADER,
                self.RULE,
                "| 2 | second | 1/1 | 0 us | 0 us | 0 us | 0 | 0 | 0 |",
            )
        )
        with self.assertRaisesRegex(ValueError, "multiple summary tables"):
            self.load_report_text(report)

    def test_rejects_empty_summary_table(self) -> None:
        report = "\n".join((self.HEADER, self.RULE, ""))
        with self.assertRaisesRegex(ValueError, "summary table contains no data rows"):
            self.load_report_text(report)

    def test_rejects_malformed_summary_row(self) -> None:
        report = "\n".join(
            (self.HEADER, self.RULE, "| 1 | truncated | 1/1 | 0 us | 0 us |")
        )
        with self.assertRaisesRegex(ValueError, "expected 9 columns"):
            self.load_report_text(report)

    def test_rejects_duplicate_iteration_coverage(self) -> None:
        report = "\n".join(
            (
                self.HEADER,
                self.RULE,
                "| 1--2 | range | 1/1 | 0 us | 0 us | 0 us | 0 | 0 | 0 |",
                "| 2 | overlap | 1/1 | 0 us | 1 us | 1 us | 0 | 0 | 0 |",
            )
        )
        with self.assertRaisesRegex(ValueError, "duplicate iteration 2"):
            self.load_report_text(report)

    def test_rejects_descending_iteration_range(self) -> None:
        with self.assertRaisesRegex(ValueError, "descending iteration range"):
            parse_iterations("3--1")

    def test_rejects_p99_9_count_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not match 3 iterations"):
            parse_p99_9_values("1/2 us", 3)

    def test_preserves_valid_p99_9_semantics(self) -> None:
        report = "\n".join(
            (
                self.HEADER,
                self.RULE,
                "| 1 | missing | 1/1 | NA | NA | NA | 0 | 0 | 0 |",
                "| 2--3 | repeated | 1/1 | 0 us | 5 us | 5 us | 0 | 0 | 0 |",
                "| 4--5 | split | 1/1 | 0/0 us | 6/7 us | 7/8 us | 0 | 0 | 0 |",
            )
        )
        self.assertEqual(
            self.load_report_text(report),
            {1: None, 2: 5.0, 3: 5.0, 4: 6.0, 5: 7.0},
        )


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

    def test_report_p99_matches_csv(self) -> None:
        rows = PLOT.load_rows(CSV)
        csv_values = {
            int(row["iteration"]): PLOT.parse_number(row["p99_us"])
            for row in rows
        }
        for iteration, report_value in load_report_p99().items():
            with self.subTest(iteration=iteration):
                self.assertIn(iteration, csv_values)
                self.assertEqual(
                    report_value,
                    csv_values[iteration],
                    f"iteration {iteration} p99 drift",
                )

if __name__ == "__main__":
    unittest.main()
