#!/usr/bin/env python3
"""Behavior tests for the RTOS real-time iteration plot."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "plot_rtos_realtime_iterations.py"
SPEC = importlib.util.spec_from_file_location("rtos_realtime_plot", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load plot module: {MODULE_PATH}")
PLOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLOT)


class PlotBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rows = PLOT.load_rows(PLOT.DEFAULT_CSV)
        cls.by_iteration = {int(row["iteration"]): row for row in cls.rows}

    def test_missing_values_are_not_interpreted_as_zero(self) -> None:
        self.assertIsNone(PLOT.parse_number("NA"))
        self.assertIsNone(PLOT.parse_number(""))
        self.assertEqual(PLOT.parse_number("0"), 0.0)

    def test_latest_confirmation_rows_keep_csv_metrics(self) -> None:
        expected = {
            140: (569.0, 0.0, 74112.0),
            141: (4996.0, 5.0, 3998752.0),
            142: (2678.0, 2.0, 1682560.0),
        }
        for iteration, (maximum, misses, p99_99_ns) in expected.items():
            row = self.by_iteration[iteration]
            self.assertEqual(PLOT.parse_number(row["max_us"]), maximum)
            self.assertEqual(PLOT.parse_number(row["miss_gt1ms"]), misses)
            self.assertEqual(PLOT.parse_number(row["p99_99_ns"]), p99_99_ns)

    def test_nanosecond_tail_metric_is_converted_to_microseconds(self) -> None:
        value = PLOT._metric_ns_to_us("p99_99_ns")(self.by_iteration[141])
        self.assertEqual(value, 3998.752)

    def test_plot_function_writes_a_png(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "iterations.png"
            result = PLOT.plot_rtos_realtime_iterations(PLOT.DEFAULT_CSV, output)
            self.assertEqual(result, output)
            self.assertGreater(output.stat().st_size, 10_000)
            self.assertEqual(output.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")


if __name__ == "__main__":
    unittest.main()
