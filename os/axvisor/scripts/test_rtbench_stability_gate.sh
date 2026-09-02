#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFY="$SCRIPT_DIR/verify_rtbench_stability.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

write_complete_log() {
    log=$1
    cat > "$log" <<'EOF'
[VM 3] RTBENCH_PMU status=ready event=0x8 cycles_delta=100 instructions_delta=100
[VM 3] RTBENCH_STABILITY_BEGIN seconds=300 expected=299999 frequency=62500000 pmu_event=0x8
[VM 3] RTBENCH metric=stability_jitter run=1 expected=299999 collected=299999 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH metric=callback_exec run=1 expected=299999 collected=299999 missing=0 p50_ns=1 p95_ns=2 p99_ns=3 p99_9_ns=4 max_ns=5 miss_100us=0 miss_500us=0 miss_1ms=0 mean_ns=1 p50_cycles=1 p95_cycles=2 p99_cycles=3 p99_9_cycles=4 max_cycles=5 mean_cycles=1 p50_instructions=1 p95_instructions=2 p99_instructions=3 p99_9_instructions=4 max_instructions=5 mean_instructions=1
[VM 3] RTBENCH_STABILITY_END status=PASS expected=299999 collected=299999 missing=0
[VM 3] RTBENCH_STABILITY_DONE
EOF
}

expect_pass() {
    name=$1
    shift
    if ! "$@" > "$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should pass" >&2
        cat "$TMP_DIR/$name.out" >&2
        exit 1
    fi
}

expect_fail() {
    name=$1
    shift
    if "$@" > "$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should fail" >&2
        cat "$TMP_DIR/$name.out" >&2
        exit 1
    fi
}

complete="$TMP_DIR/complete.log"
write_complete_log "$complete"
expect_pass complete "$VERIFY" "$complete" 300 0
expect_fail qemu_timeout "$VERIFY" "$complete" 300 124

unavailable_pmu="$TMP_DIR/unavailable-pmu.log"
sed 's/RTBENCH_PMU status=ready/RTBENCH_PMU status=unavailable/' "$complete" > "$unavailable_pmu"
expect_fail unavailable_pmu "$VERIFY" "$unavailable_pmu" 300 0

crlf="$TMP_DIR/crlf.log"
sed 's/$/\r/' "$complete" > "$crlf"
expect_pass crlf "$VERIFY" "$crlf" 300 0

cr_after_end="$TMP_DIR/cr-after-end.log"
python3 - "$complete" "$cr_after_end" <<'PY'
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
marker = b"RTBENCH_STABILITY_DONE\n"
if data.count(marker) != 1:
    raise SystemExit("stability done marker not found")
destination.write_bytes(
    data.replace(marker, marker[:-1] + b"\rqemu-system-aarch64: terminating on signal 15\n", 1)
)
PY
expect_pass cr_after_end "$VERIFY" "$cr_after_end" 300 0

interleaved_begin="$TMP_DIR/interleaved-begin.log"
python3 - "$complete" "$interleaved_begin" <<'PY'
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
needle = b"RTBENCH_STABILITY_BEGIN seconds=300 expected=299999 frequency="
if data.count(needle) != 1:
    raise SystemExit("stability begin marker not found")
data = data.replace(
    needle,
    b"RTBENCH_STABILITY_BEGIN seconds=300 expected=299999"
    b" \x1b[37m[ 79.977618 0:25 axvm::runtime::hvc:352] VM[1] PSCI_SYSTEM_OFF\x1b[m"
    b" frequency=",
    1,
)
destination.write_bytes(data)
PY
expect_pass interleaved_begin "$VERIFY" "$interleaved_begin" 300 0

missing="$TMP_DIR/missing.log"
write_complete_log "$missing"
sed -i 's/collected=299999 missing=0/collected=299998 missing=1/' "$missing"
expect_fail missing_sample "$VERIFY" "$missing" 300 0

deadline_miss="$TMP_DIR/deadline-miss.log"
write_complete_log "$deadline_miss"
sed -i '0,/miss_1ms=0/s//miss_1ms=1/' "$deadline_miss"
expect_fail deadline_miss "$VERIFY" "$deadline_miss" 300 0
sed -i 's/status=PASS/status=FAIL/' "$deadline_miss"
expect_pass deadline_miss_diagnostic "$VERIFY" "$deadline_miss" 300 0 allow-qemu-timer-limit

pass_with_tail="$TMP_DIR/pass-with-tail.log"
write_complete_log "$pass_with_tail"
sed -i '0,/miss_1ms=0/s//miss_1ms=1/' "$pass_with_tail"
expect_pass pass_with_tail_diagnostic "$VERIFY" "$pass_with_tail" 300 0 allow-qemu-timer-limit

wrong_duration="$TMP_DIR/wrong-duration.log"
write_complete_log "$wrong_duration"
sed -i 's/seconds=300/seconds=60/' "$wrong_duration"
expect_fail wrong_duration "$VERIFY" "$wrong_duration" 300 0

error_log="$TMP_DIR/error.log"
write_complete_log "$error_log"
printf '%s\n' 'RTBENCH_ERROR metric=stability reason=sample_conservation' >> "$error_log"
expect_fail explicit_error "$VERIFY" "$error_log" 300 0

conflicting_status="$TMP_DIR/conflicting-status.log"
write_complete_log "$conflicting_status"
printf '%s\n' \
    '[VM 3] RTBENCH_STABILITY_END status=FAIL expected=299999 collected=299999 missing=0' \
    >> "$conflicting_status"
expect_fail conflicting_status "$VERIFY" "$conflicting_status" 300 0

missing_done="$TMP_DIR/missing-done.log"
write_complete_log "$missing_done"
sed -i '/RTBENCH_STABILITY_DONE/d' "$missing_done"
expect_pass missing_done "$VERIFY" "$missing_done" 300 0

duplicate_done="$TMP_DIR/duplicate-done.log"
write_complete_log "$duplicate_done"
printf '%s\n' '[VM 3] RTBENCH_STABILITY_DONE' >> "$duplicate_done"
expect_fail duplicate_done "$VERIFY" "$duplicate_done" 300 0

done_before_end="$TMP_DIR/done-before-end.log"
write_complete_log "$done_before_end"
sed -i '/RTBENCH_STABILITY_DONE/d' "$done_before_end"
sed -i '/RTBENCH_STABILITY_END/i [VM 3] RTBENCH_STABILITY_DONE' "$done_before_end"
expect_fail done_before_end "$VERIFY" "$done_before_end" 300 0

panic_log="$TMP_DIR/panic.log"
write_complete_log "$panic_log"
printf '%s\n' 'kernel panic' >> "$panic_log"
expect_fail panic "$VERIFY" "$panic_log" 300 0

expect_fail qemu_failure "$VERIFY" "$complete" 300 1
for invalid_qemu_rc in '' abc 999999999999999999999; do
    set +e
    "$VERIFY" "$complete" 300 "$invalid_qemu_rc" \
        >"$TMP_DIR/invalid-qemu-rc.out" 2>&1
    invalid_status=$?
    set -e
    if [ "$invalid_status" -ne 2 ]; then
        echo "FAIL: invalid QEMU exit code '$invalid_qemu_rc' returned $invalid_status instead of 2" >&2
        exit 1
    fi
    set +e
    "$VERIFY" "$TMP_DIR/missing-invalid.log" 300 "$invalid_qemu_rc" \
        >"$TMP_DIR/missing-invalid-qemu-rc.out" 2>&1
    missing_invalid_status=$?
    set -e
    if [ "$missing_invalid_status" -ne 2 ]; then
        echo "FAIL: missing log with invalid QEMU exit code '$invalid_qemu_rc' returned $missing_invalid_status instead of 2" >&2
        exit 1
    fi
done

echo "PASS: RT benchmark stability result gate"
