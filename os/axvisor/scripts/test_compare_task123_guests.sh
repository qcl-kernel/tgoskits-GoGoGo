#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ANALYZER="$ROOT/os/axvisor/scripts/compare_task123_guests.py"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[[ -x "$ANALYZER" ]] || fail "Task123 comparison analyzer is missing or not executable"

python3 - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])


def write_guest(name: str, avg: int, app_guest: str) -> None:
    run = root / name
    run.mkdir()
    (run / "manifest.txt").write_text(
        f"schema=1\napp_guest={app_guest}\nmode=stability\nseconds=1\n",
        encoding="ascii",
    )
    sections = []
    for payload in (64, 256, 1024):
        sections.extend(
            [
                f"--- Payload {payload}B ---",
                "sent=10 recv=10",
                f"RTT: min=1ms avg={avg}ms max=4ms P50={avg}ms P95=3ms P99=4ms P99.9=4ms",
                "throughput=10.00KiB/s",
                "request_timeouts=0 protocol_errors=0 reconnects=0",
                "transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0",
            ]
        )
    (run / f"{app_guest}.log").write_text("\n".join(sections) + "\n", encoding="ascii")
    (run / "rtthread.log").write_text(
        "RTBENCH_STABILITY_BEGIN seconds=1 expected=999\n"
        "RTBENCH metric=stability_jitter run=1 expected=999 collected=999 missing=0 "
        f"p50_ns={avg} p95_ns={max(avg, 2)} p99_ns={max(avg, 3)} "
        f"p99_9_ns={max(avg, 4)} max_ns={max(avg, 5)} "
        "miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n"
        "RTBENCH metric=callback_exec run=1 expected=999 collected=999 missing=0 "
        "p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=2\n"
        "RTBENCH_STABILITY_END status=PASS expected=999 collected=999 missing=0\n",
        encoding="ascii",
    )
    (run / "summary.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "success_rate": 1.0,
                "inference_us": {"mean": avg, "p95": avg + 1, "p99": avg + 2, "max": avg + 3},
                "round_trip_us": {"mean": avg + 10, "p95": avg + 11, "p99": avg + 12, "max": avg + 13},
                "rtos_processing_us": {"mean": 2, "p95": 3, "p99": 4, "max": 5},
            }
        ),
        encoding="ascii",
    )
    (run / "host-metrics.txt").write_text(
        "schema=1\nqemu_pid=1\nelapsed_ms=1000\ncpu_time_ms=500\n"
        "peak_rss_kb=100\nmax_threads=4\nsample_count=10\n",
        encoding="ascii",
    )
    (run / "manifest.txt").write_text(
        (run / "manifest.txt").read_text(encoding="ascii")
        + "result_gate=PASS\n"
        + "ARTIFACT name=qemu path=/tmp/qemu sha256=" + "a" * 64 + "\n"
        + "ARTIFACT name=rtthread-normal path=/tmp/rt-normal sha256=" + "b" * 64 + "\n"
        + "ARTIFACT name=rtthread-drop-status path=/tmp/rt-drop sha256=" + "c" * 64 + "\n"
        + "ARTIFACT name=rtthread-delayed-server path=/tmp/rt-delay sha256=" + "d" * 64 + "\n"
        + "ARTIFACT name=rootfs path=/tmp/rootfs sha256=" + "e" * 64 + "\n"
        + "ARTIFACT name=model path=/tmp/model sha256=" + "f" * 64 + "\n"
        + "ARTIFACT name=protocol-source path=/tmp/protocol.c sha256=" + "1" * 64 + "\n"
        + "ARTIFACT name=protocol-header path=/tmp/protocol.h sha256=" + "2" * 64 + "\n",
        encoding="ascii",
    )


write_guest("linux", 2, "linux")
write_guest("starryos", 3, "starryos")
PY

output="$tmp/comparison"
"$ANALYZER" --linux-run "$tmp/linux" --starryos-run "$tmp/starryos" --output "$output" >/dev/null

python3 - "$output/comparison.json" "$output/comparison-report.md" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
if data["schema"] != 1:
    raise SystemExit("wrong comparison schema")
if data["guests"]["linux"]["task2"]["payloads"]["64"]["rtt_ms"]["avg"] != 2:
    raise SystemExit("Linux RTT was not parsed")
relative = data["comparison"]["task2"]["payloads"]["64"]["rtt_ms"]["avg"]["starryos_vs_linux_percent"]
if relative != 50.0:
    raise SystemExit(f"unexpected relative RTT: {relative}")
if data["comparison"]["rtbench"]["stability_jitter"]["p99"]["starryos"] != 3:
    raise SystemExit("StarryOS RTBench data was not parsed")
report = Path(sys.argv[2]).read_text(encoding="utf-8")
if "StarryOS 与 Linux" not in report or "Task2 RTT" not in report:
    raise SystemExit("comparison report is missing required sections")
PY

for guest in linux starryos; do
    sed -i 's/^result_gate=PASS$/result_gate=PASS_WITH_QEMU_TIMER_LIMIT/' \
        "$tmp/$guest/manifest.txt"
done
if "$ANALYZER" --linux-run "$tmp/linux" --starryos-run "$tmp/starryos" \
    --output "$tmp/diagnostic-rejected" >/dev/null 2>&1; then
    fail "analyzer accepted diagnostic gate without explicit opt-in"
fi
"$ANALYZER" --linux-run "$tmp/linux" --starryos-run "$tmp/starryos" \
    --allow-qemu-timer-limit --output "$tmp/diagnostic-accepted" >/dev/null ||
    fail "analyzer rejected explicit diagnostic gate"

python3 - "$tmp/linux/linux.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="ascii")
path.write_text(text.replace("P95=3ms", "P95=1ms", 1), encoding="ascii")
PY

if "$ANALYZER" --linux-run "$tmp/linux" --starryos-run "$tmp/starryos" \
    --output "$tmp/invalid-percentiles" >/dev/null 2>&1; then
    fail "analyzer accepted descending RTT percentiles"
fi

python3 - "$tmp/starryos/manifest.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="ascii")
path.write_text(text.replace("sha256=" + "e" * 64, "sha256=" + "9" * 64), encoding="ascii")
PY

if "$ANALYZER" --linux-run "$tmp/linux" --starryos-run "$tmp/starryos" \
    --output "$tmp/mismatched" >/dev/null 2>&1; then
    fail "analyzer accepted mismatched shared artifact hashes"
fi

echo "PASS: StarryOS/Linux comparison analyzer contract"
