import csv
import tempfile
import unittest
from pathlib import Path

from scripts.summarize_faults import CASES, _last_rtos_final, parse_events, summarize_events


ROOT = Path(__file__).resolve().parents[1]


class FaultSummaryTests(unittest.TestCase):
    def test_rtos_final_accepts_serial_shell_prompt_prefix(self):
        final = _last_rtos_final(
            "msh />TASK3_RTOS_FINAL requests=9 errors=0 duplicates=1 "
            "applied_steps=3 retries=2\r\n"
        )
        self.assertEqual(final["duplicates"], 1)
        self.assertEqual(final["retries"], 2)

    def test_known_events(self):
        events = parse_events(ROOT / "tests/fixtures/fault_events.csv")
        summary = summarize_events(events)
        self.assertEqual(summary["schema"], 1)
        self.assertEqual(set(summary["cases"]), set(CASES))
        self.assertEqual(summary["cases"]["drop-control"]["transport_retries"], 1)
        self.assertEqual(summary["cases"]["duplicate-frame"]["applied_delta"], 0)
        self.assertEqual(summary["cases"]["malformed"]["application_errors"], 2)

    def test_missing_duplicate_and_unsafe_application_are_rejected(self):
        source = ROOT / "tests/fixtures/fault_events.csv"
        with source.open(encoding="ascii") as stream:
            rows = list(csv.DictReader(stream))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.csv"
            self._write(path, rows[:-1])
            with self.assertRaisesRegex(ValueError, "missing"):
                parse_events(path)
            self._write(path, rows + [rows[0]])
            with self.assertRaisesRegex(ValueError, "duplicate"):
                parse_events(path)
            bad = [dict(row) for row in rows]
            bad[2]["applied_delta"] = "1"
            self._write(path, bad)
            with self.assertRaisesRegex(ValueError, "applied"):
                summarize_events(parse_events(path))

    @staticmethod
    def _write(path, rows):
        with path.open("w", newline="", encoding="ascii") as stream:
            writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)


if __name__ == "__main__":
    unittest.main()
