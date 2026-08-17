import shutil
import tempfile
import unittest
from pathlib import Path

from scripts.render_report import render_report
from scripts.summarize import summarize, write_json_atomic


ROOT = Path(__file__).resolve().parents[1]


class ReportTests(unittest.TestCase):
    def test_report_contains_reproducibility_and_evidence_sections(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            shutil.copy(
                ROOT / "tests/fixtures/normal_frames.csv", run_dir / "frames.csv"
            )
            (run_dir / "linux.log").write_text("TASK3_LINUX_READY\n", encoding="ascii")
            (run_dir / "rtthread.log").write_text(
                "TASK3_RTOS_READY\nTASK3_RTOS_FINAL requests=9 errors=0 "
                "duplicates=0 applied_steps=3 retries=0\n",
                encoding="ascii",
            )
            (run_dir / "commands.txt").write_text(
                "qemu-system-aarch64 -smp 2\nqemu-system-aarch64 -smp 1\n",
                encoding="ascii",
            )
            (run_dir / "versions.txt").write_text(
                "QEMU emulator version 11.0\nframes=3\n", encoding="ascii"
            )
            (run_dir / "summary.raw.json").write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "frames_per_mode": 3,
                        "records": 6,
                        "requests": 6,
                        "successes": 6,
                        "success_rate": 1.0,
                        "application_errors": 0,
                        "application_timeouts": 0,
                        "reconnects": 0,
                        "injected_drops": 0,
                        "elapsed_us": 600000,
                        "settling": {
                            "fixed": {"direction_changes": 0, "successes": 0, "mean_frames": 0, "max_frames": 0},
                            "ai": {"direction_changes": 0, "successes": 0, "mean_frames": 0, "max_frames": 0},
                        },
                    }
                ),
                encoding="ascii",
            )
            summary = summarize(run_dir, 3, smoke=True)
            write_json_atomic(run_dir / "summary.json", summary)
            fault_summary = run_dir / "fault-summary.json"
            fault_summary.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "all_passed": True,
                        "cases": {
                            name: {
                                "result": "rejected" if name == "malformed" else "recovered",
                                "transport_retries": 1,
                                "duplicates": 1 if name == "duplicate-frame" else 0,
                                "application_errors": 2 if name == "malformed" else 0,
                                "applied_delta": 0 if name in ("duplicate-frame", "malformed") else None,
                                "run_dir": str(run_dir),
                            }
                            for name in (
                                "drop-control",
                                "drop-status",
                                "duplicate-frame",
                                "delayed-server",
                                "malformed",
                            )
                        },
                    }
                ),
                encoding="ascii",
            )
            report = render_report(run_dir, fault_summary)
            for text in (
                "网络拓扑",
                "构建与启动命令",
                "版本与运行配置",
                "CPU 负载分工",
                "计时方法与误差",
                "固定基线与 AI 对比",
                "可靠性",
                "原始证据",
                "192.168.77.11",
                "192.168.77.30",
                "UDP/9876",
                "frames.csv",
                "linux.log",
                "rtthread.log",
                "fault-summary.json",
                "drop-control",
                "drop-status",
                "duplicate-frame",
                "delayed-server",
                "malformed",
            ):
                self.assertIn(text, report)
            self.assertNotIn("TBD", report)
            self.assertNotIn("PLACEHOLDER", report)


if __name__ == "__main__":
    unittest.main()
import json
