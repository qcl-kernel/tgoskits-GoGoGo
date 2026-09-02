import json
import shutil
import tempfile
import unittest
from pathlib import Path

from scripts.summarize import parse_frames, summarize, write_json_atomic


ROOT = Path(__file__).resolve().parents[1]


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.run_dir = Path(self.temporary.name)
        shutil.copy(ROOT / "tests/fixtures/normal_frames.csv", self.run_dir / "frames.csv")
        (self.run_dir / "linux.log").write_text("linux\n", encoding="ascii")
        (self.run_dir / "rtthread.log").write_text(
            "msh />TASK3_RTOS_FINAL requests=9 errors=0 duplicates=0 "
            "applied_steps=3 retries=2\n",
            encoding="ascii",
        )
        (self.run_dir / "summary.raw.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "frames_per_mode": 3,
                    "records": 6,
                    "requests": 6,
                    "successes": 6,
                    "success_rate": 1.0,
                    "application_errors": 0,
                    "application_timeouts": 2,
                    "reconnects": 1,
                    "injected_drops": 1,
                    "elapsed_us": 750000,
                    "settling": {
                        "fixed": {"direction_changes": 2, "successes": 1, "mean_frames": 4, "max_frames": 4},
                        "ai": {"direction_changes": 2, "successes": 2, "mean_frames": 2, "max_frames": 3},
                    },
                }
            ),
            encoding="ascii",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_known_metrics_and_nearest_rank(self):
        summary = summarize(self.run_dir, 3, smoke=True)
        self.assertEqual(summary["schema"], 1)
        self.assertEqual(summary["requests"], 6)
        self.assertEqual(summary["success_rate"], 1.0)
        self.assertEqual(summary["transport_retries"], 3)
        self.assertEqual(
            summary["transport_retries_by_side"], {"linux": 1, "rtthread": 2}
        )
        self.assertEqual(summary["duplicates"], 0)
        self.assertEqual(summary["recoveries"], 1)
        self.assertEqual(summary["timeouts"], 2)
        self.assertEqual(summary["reconnects"], 1)
        self.assertEqual(summary["injected_drops"], 1)
        self.assertEqual(summary["elapsed_us"], 750000)
        self.assertEqual(summary["effective_payload_bytes_per_second"], 192)
        self.assertEqual(summary["settling"]["ai"]["successes"], 2)
        self.assertEqual(summary["classification"]["confusion_matrix"], [[1, 0, 0], [0, 0, 1], [0, 0, 1]])
        self.assertEqual(summary["round_trip_us"]["p50"], 20)
        self.assertEqual(summary["round_trip_us"]["p95"], 35)
        self.assertEqual(summary["tracking_error_q15"]["fixed"]["mean"], 666)
        self.assertEqual(summary["tracking_error_q15"]["ai"]["mean"], 66)
        self.assertFalse(summary["gates_enforced"])

    def test_duplicate_and_missing_rows_are_rejected(self):
        original = (self.run_dir / "frames.csv").read_text(encoding="ascii")
        line = original.splitlines()[-1]
        (self.run_dir / "frames.csv").write_text(original + line + "\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            parse_frames(self.run_dir / "frames.csv", 3)
        (self.run_dir / "frames.csv").write_text(
            "\n".join(original.splitlines()[:-1]) + "\n", encoding="ascii"
        )
        with self.assertRaisesRegex(ValueError, "missing"):
            parse_frames(self.run_dir / "frames.csv", 3)

    def test_json_is_written_atomically(self):
        summary = summarize(self.run_dir, 3, smoke=True)
        output = self.run_dir / "summary.json"
        write_json_atomic(output, summary)
        self.assertEqual(json.loads(output.read_text())["schema"], 1)


if __name__ == "__main__":
    unittest.main()
