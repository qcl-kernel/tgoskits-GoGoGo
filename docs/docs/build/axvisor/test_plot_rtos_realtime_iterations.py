#!/usr/bin/env python3
"""Behavior tests for the RTOS real-time iteration plot."""

from __future__ import annotations

import hashlib
import importlib.util
import struct
import tempfile
import unittest
import zlib
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "plot_rtos_realtime_iterations.py"
SPEC = importlib.util.spec_from_file_location("rtos_realtime_plot", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load plot module: {MODULE_PATH}")
PLOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLOT)


def read_png_text_metadata(path: Path) -> dict[str, str]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a PNG file")

    metadata = {}
    offset = 8
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError("truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise ValueError("PNG chunk exceeds file size")
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : chunk_end])[0]
        actual_crc = zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError("PNG chunk CRC mismatch")
        if chunk_type == b"tEXt":
            keyword, separator, value = chunk_data.partition(b"\0")
            if not separator:
                raise ValueError("invalid PNG text chunk")
            metadata[keyword.decode("latin-1")] = value.decode("latin-1")
        offset = chunk_end
        if chunk_type == b"IEND":
            break
    return metadata


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

    def test_plot_embeds_source_csv_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "iterations.png"
            PLOT.plot_rtos_realtime_iterations(PLOT.DEFAULT_CSV, output)

            metadata = read_png_text_metadata(output)
            expected = hashlib.sha256(PLOT.DEFAULT_CSV.read_bytes()).hexdigest()
            self.assertEqual(metadata.get("rtos-realtime-csv-sha256"), expected)

    def test_checked_in_plot_digest_matches_complete_csv(self) -> None:
        metadata = read_png_text_metadata(PLOT.DEFAULT_OUTPUT)
        expected = hashlib.sha256(PLOT.DEFAULT_CSV.read_bytes()).hexdigest()
        self.assertEqual(metadata.get("rtos-realtime-csv-sha256"), expected)


if __name__ == "__main__":
    unittest.main()
