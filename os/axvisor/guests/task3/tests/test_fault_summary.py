import csv
import json
import tempfile
import unittest
from pathlib import Path

from scripts.summarize_faults import (
    CASES,
    _last_rtos_final,
    collect_event,
    parse_events,
    summarize_events,
    validate_event,
)


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
        for event in events:
            with self.subTest(case=event["case"]):
                validate_event(event)
        summary = summarize_events(events)
        self.assertEqual(summary["schema"], 1)
        self.assertEqual(set(summary["cases"]), set(CASES))
        self.assertEqual(summary["cases"]["drop-control"]["transport_retries"], 1)
        self.assertEqual(summary["cases"]["duplicate-frame"]["applied_delta"], 0)
        self.assertEqual(summary["cases"]["malformed"]["application_errors"], 2)

    def test_delayed_server_requires_positive_rtos_delay_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            case_dir = Path(temporary)
            self._write_delayed_case(case_dir, "TASK3_FAULT_DELAYED_SERVER delay_ms=3000\n")
            event = collect_event("delayed-server", case_dir)
            self.assertEqual(event["result"], "recovered")

            invalid_markers = (
                "",
                "TASK3_FAULT_DELAYED_SERVER delay_ms=0\n",
                "TASK3_FAULT_DELAYED_SERVER delay_ms=-1\n",
                "TASK3_FAULT_DELAYED_SERVER delay_ms=three\n",
                "TASK3_FAULT_DELAYED_SERVER delay_ms=3000 forged=1\n",
            )
            for marker in invalid_markers:
                with self.subTest(marker=marker):
                    self._write_delayed_case(case_dir, marker)
                    with self.assertRaisesRegex(ValueError, "delayed-server"):
                        collect_event("delayed-server", case_dir)

    def test_delayed_server_rejects_linux_host_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            case_dir = Path(temporary)
            self._write_delayed_case(
                case_dir,
                "",
                linux_log="TASK3_FAULT_DELAYED_SERVER delay_ms=3000\n",
            )
            with self.assertRaisesRegex(ValueError, "delayed-server"):
                collect_event("delayed-server", case_dir)

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

    def test_unsafe_single_events_are_rejected(self):
        events = {
            event["case"]: event
            for event in parse_events(ROOT / "tests/fixtures/fault_events.csv")
        }
        unsafe_events = (
            (
                "drop-control retries",
                self._changed(events["drop-control"], transport_retries=0),
                "drop-control",
            ),
            (
                "drop-status retries",
                self._changed(events["drop-status"], transport_retries=0),
                "drop-status",
            ),
            (
                "duplicate count",
                self._changed(events["duplicate-frame"], duplicates=0),
                "duplicate-frame",
            ),
            (
                "duplicate applied delta",
                self._changed(events["duplicate-frame"], applied_delta=1),
                "applied",
            ),
            (
                "malformed errors",
                self._changed(events["malformed"], application_errors=1),
                "malformed",
            ),
            (
                "malformed applied delta",
                self._changed(events["malformed"], applied_delta=1),
                "applied",
            ),
            (
                "recovery result",
                self._changed(events["delayed-server"], result="rejected"),
                "result",
            ),
            (
                "rejection result",
                self._changed(events["malformed"], result="recovered"),
                "result",
            ),
        )
        for label, event, message in unsafe_events:
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, message):
                    validate_event(event)

    @staticmethod
    def _changed(event, **changes):
        changed = dict(event)
        changed.update(changes)
        return changed

    @staticmethod
    def _write(path, rows):
        with path.open("w", newline="", encoding="ascii") as stream:
            writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)

    @staticmethod
    def _write_delayed_case(case_dir, rtos_marker, linux_log="linux\n"):
        (case_dir / "summary.json").write_text(
            json.dumps({"success_rate": 1.0, "transport_retries": 0}),
            encoding="ascii",
        )
        (case_dir / "summary.raw.json").write_text("{}", encoding="ascii")
        (case_dir / "linux.log").write_text(linux_log, encoding="ascii")
        (case_dir / "rtthread.log").write_text(
            rtos_marker
            + "TASK3_RTOS_FINAL requests=6 errors=0 duplicates=0 "
            "applied_steps=6 retries=0\n",
            encoding="ascii",
        )


if __name__ == "__main__":
    unittest.main()
