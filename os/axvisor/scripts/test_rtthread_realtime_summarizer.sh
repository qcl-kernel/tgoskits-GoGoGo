#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SUMMARIZER="$SCRIPT_DIR/summarize_rtthread_realtime.py"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

metric_line() {
    local value=$1
    printf 'RTBENCH metric=%s run=1 expected=10 collected=10 missing=0 p50_ns=%s p95_ns=%s p99_ns=%s p99_9_ns=%s max_ns=%s miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=%s\n' \
        "$2" "$value" "$value" "$value" "$value" "$value" "$value"
}

write_complete_log() {
    local output=$1 p50=$2
    : > "$output"
    for metric in timer_jitter callback_exec preemption irq irq_to_task irq_disabled_duration mutex_inversion wake_under_load net_event_latency; do
        metric_line "$p50" "$metric" >> "$output"
    done
}

write_complete_log "$WORK/a.log" 10
write_complete_log "$WORK/b.log" 20
write_complete_log "$WORK/c.log" 40

python3 "$SUMMARIZER" \
    --native "$WORK/a.log" --axvisor-only "$WORK/b.log" --axvisor-linux "$WORK/c.log" \
    --suite-samples 10 --json-output "$WORK/result.json" --csv-output "$WORK/result.csv" \
    --markdown-output "$WORK/result.md" \
    > "$WORK/stdout.json"

grep -Fq '"schema": 1' "$WORK/result.json"
grep -Fq '"B_axvisor_rtthread"' "$WORK/result.json"
grep -Fq '"C_over_B"' "$WORK/result.json"
grep -Fq 'timer_jitter,A_native,10,10,10,10,10,10,0,0,0' "$WORK/result.csv"
grep -Fq '# RT-Thread realtime comparison' "$WORK/result.md"
grep -Fq '| timer_jitter |' "$WORK/result.md"
grep -Fq '| A_native |' "$WORK/result.md"
grep -Fq 'Strict tail pass' "$WORK/result.md"

cp "$WORK/c.log" "$WORK/host-log-interleaved.log"
python3 - "$WORK/host-log-interleaved.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b"mean_ns=40\n"
replacement = (
    b"mean_ns=\x1b[37m[ 1.000000 0:2 axvm::vm:1] \x1b[33mstop\x1b[m\r\n"
    b"40\x1b[37m[ 1.000001 0:2 axvm::vm:2] \x1b[32mdone\x1b[m\r\n\r\n"
)
if data.count(needle) != 9:
    raise SystemExit("host-log summarizer fixture marker not found")
path.write_bytes(data.replace(needle, replacement, 1))
PY
python3 "$SUMMARIZER" \
    --native "$WORK/a.log" --axvisor-only "$WORK/b.log" \
    --axvisor-linux "$WORK/host-log-interleaved.log" --suite-samples 10 >/dev/null

cp "$WORK/c.log" "$WORK/nul-interleaved.log"
python3 - "$WORK/nul-interleaved.log" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_bytes()
needle = b"RTBENCH metric=mutex_inversion run=1"
replacement = b"RTBENCH metric=mute\x1b[32m[I/rtipic.srv] client connected\x1b[0m\r\n \x00inversion run=1"
if data.count(needle) != 1:
    raise SystemExit("NUL-interleaved summarizer fixture marker not found")
path.write_bytes(data.replace(needle, replacement, 1))
PY
python3 "$SUMMARIZER" \
    --native "$WORK/a.log" --axvisor-only "$WORK/b.log" \
    --axvisor-linux "$WORK/nul-interleaved.log" --suite-samples 10 >/dev/null

sed '/metric=net_event_latency /d' "$WORK/b.log" > "$WORK/b-core.log"
python3 "$SUMMARIZER" \
    --native "$WORK/a.log" --axvisor-only "$WORK/b-core.log" \
    --axvisor-linux "$WORK/c.log" --axvisor-only-core \
    --suite-samples 10 --json-output "$WORK/core-result.json" \
    --csv-output "$WORK/core-result.csv" > "$WORK/core-stdout.json"
grep -Fq '"network_metric_status": "not_applicable_for_B"' "$WORK/core-result.json"
grep -Fq 'net_event_latency,A_native' "$WORK/core-result.csv"

cp "$WORK/b.log" "$WORK/duplicate.log"
metric_line 20 preemption >> "$WORK/duplicate.log"
if python3 "$SUMMARIZER" --native "$WORK/a.log" --axvisor-only "$WORK/duplicate.log" \
    --axvisor-linux "$WORK/c.log" --suite-samples 10 >/dev/null 2>"$WORK/duplicate.err"; then
    echo 'FAIL: duplicate metric was accepted' >&2
    exit 1
fi
grep -Fq 'duplicate metric' "$WORK/duplicate.err"

sed '/metric=preemption /d' "$WORK/b.log" > "$WORK/missing.log"
if python3 "$SUMMARIZER" --native "$WORK/a.log" --axvisor-only "$WORK/missing.log" \
    --axvisor-linux "$WORK/c.log" --suite-samples 10 >/dev/null 2>"$WORK/missing.err"; then
    echo 'FAIL: missing metric was accepted' >&2
    exit 1
fi
grep -Fq 'missing metrics: preemption' "$WORK/missing.err"

sed -E 's/collected=10/collected=9/; s/missing=0/missing=1/' "$WORK/b.log" > "$WORK/incomplete.log"
if python3 "$SUMMARIZER" --native "$WORK/a.log" --axvisor-only "$WORK/incomplete.log" \
    --axvisor-linux "$WORK/c.log" --suite-samples 10 >/dev/null 2>"$WORK/incomplete.err"; then
    echo 'FAIL: incomplete metric was accepted' >&2
    exit 1
fi
grep -Fq 'has missing samples: 1' "$WORK/incomplete.err"

echo 'PASS: RT-Thread realtime summarizer contract'
