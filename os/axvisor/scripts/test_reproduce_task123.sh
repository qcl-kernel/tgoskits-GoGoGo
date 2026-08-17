#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
REPRODUCER="$ROOT/os/axvisor/scripts/reproduce_task123.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

tools="$tmp/tools"
mkdir -p -- "$tools"

cat > "$tools/run-task123" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$FAKE_CALL_LOG"
printf '\n' >> "$FAKE_CALL_LOG"
printf 'FAKE_RUNNER_PROGRESS pid=%s\n' "$$"

mode=
output=
fault=normal
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) mode=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --task3-fault) fault=$2; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p -- "$output"
printf 'mode=%s\ntask3_fault=%s\nresult_gate=PASS\n' "$mode" "$fault" \
    > "$output/manifest.txt"
cat > "$output/console.log" <<'LOG'
TASK2_LINUX_END status=PASS
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
LOG
printf '{}\n' > "$output/summary.json"
printf '{}\n' > "$output/summary.raw.json"
printf 'mode,frame\n' > "$output/frames.csv"
printf 'linux\n' > "$output/linux.log"
printf 'rtthread\n' > "$output/rtthread.log"
printf 'runner\n' > "$output/runner.log"
printf 'axvisor\n' > "$output/axvisor.bin"

if [[ "${FAKE_MALFORMED_MODE:-}" == "$mode" ]]; then
    rm -- "$output/summary.json"
fi

if [[ "${FAKE_FAIL_MODE:-}" == "$mode" ]]; then
    echo 'fatal: injected runner failure' >> "$output/console.log"
    exit 42
fi

if [[ "$mode" == stability && "${FAKE_STABILITY_LIMIT:-0}" == 1 ]]; then
    cat >> "$output/console.log" <<'LOG'
RTBENCH_STABILITY_END status=FAIL expected=299999 collected=299999 missing=0 miss_1ms=1
RTBENCH_STABILITY_DONE
LOG
    exit 1
fi
EOF

cat > "$tools/summarize-faults" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --suite-dir ]]
printf '{"status":"PASS"}\n' > "$2/fault-summary.json"
EOF
chmod +x "$tools/run-task123" "$tools/summarize-faults"

run_reproducer() {
    local output=$1
    shift
    FAKE_CALL_LOG="$tmp/calls.log" \
    TASK123_RUNNER="$tools/run-task123" \
    TASK123_FAULT_SUMMARIZER="$tools/summarize-faults" \
        "$REPRODUCER" "$@" --output "$output"
}

expect_failure() {
    local description=$1
    shift
    if "$@" > "$tmp/failure.out" 2>&1; then
        fail "$description"
    fi
}

[[ -x "$REPRODUCER" ]] || fail "reproduce_task123.sh is missing or not executable"

: > "$tmp/calls.log"
quick="$tmp/quick"
run_reproducer "$quick" > "$tmp/quick.stdout"
grep -Fxq "[task123] OUTPUT $quick" "$tmp/quick.stdout" ||
    fail "reproducer did not print the output directory"
grep -Fxq "[task123] LOG    $quick/reproduction.log" "$tmp/quick.stdout" ||
    fail "reproducer did not print the live log path"
grep -Fq 'FAKE_RUNNER_PROGRESS' "$tmp/quick.stdout" ||
    fail "reproducer did not stream runner progress to stdout"
printf '%s \n' \
    "--mode smoke --task2-count 100 --task3-frames 3 --output $quick/smoke" \
    "--mode realtime-suite --rtbench-samples 100 --task2-count 100 --output $quick/realtime-suite" \
    "--mode task3 --task3-frames 30 --output $quick/task3-normal" \
    > "$tmp/quick.expected"
cmp -s "$tmp/quick.expected" "$tmp/calls.log" || {
    diff -u "$tmp/quick.expected" "$tmp/calls.log" >&2 || true
    fail "default quick mode invoked an unexpected phase sequence"
}
grep -Fxq 'profile=quick' "$quick/reproduction-summary.txt" ||
    fail "quick summary did not record the selected profile"
grep -Fxq 'overall_status=PASS' "$quick/reproduction-summary.txt" ||
    fail "quick summary did not pass"
[[ -s "$quick/task123-quick-evidence.tar.gz" ]] ||
    fail "quick evidence archive is missing"
[[ -s "$quick/task123-quick-evidence.tar.gz.sha256" ]] ||
    fail "quick archive digest is missing"
gzip -t "$quick/task123-quick-evidence.tar.gz"
(cd "$quick" && sha256sum -c task123-quick-evidence.tar.gz.sha256 >/dev/null) ||
    fail "quick archive digest does not verify"
tar -tzf "$quick/task123-quick-evidence.tar.gz" | grep -Fxq './task3-normal/manifest.txt' ||
    fail "quick archive is missing Task 3 evidence"

: > "$tmp/calls.log"
full="$tmp/full"
FAKE_STABILITY_LIMIT=1 run_reproducer "$full" --full >/dev/null
[[ "$(wc -l < "$tmp/calls.log")" -eq 8 ]] ||
    fail "full mode did not invoke exactly eight phases"
sed -n '1p' "$tmp/calls.log" | grep -Fxq -- \
    "--mode realtime-suite --rtbench-samples 1000 --task2-count 1000 --output $full/realtime-suite " ||
    fail "full mode realtime suite arguments are incorrect"
sed -n '2p' "$tmp/calls.log" | grep -Fxq -- \
    "--mode stability --seconds 300 --task2-count 30000 --output $full/stability-300s " ||
    fail "full mode stability arguments are incorrect"
sed -n '3p' "$tmp/calls.log" | grep -Fxq -- \
    "--mode task3 --task3-frames 600 --output $full/task3-normal " ||
    fail "full mode Task 3 arguments are incorrect"
for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
    grep -Fxq -- \
        "--mode task3-fault --task3-fault $profile --task3-frames 3 --output $full/task3-faults/$profile " \
        "$tmp/calls.log" || fail "full mode omitted fault profile $profile"
done
grep -Fxq 'stability_status=QEMU_TIMER_LIMIT' "$full/reproduction-summary.txt" ||
    fail "full summary did not preserve the accepted QEMU timer limit"
grep -Fxq 'overall_status=PASS_WITH_QEMU_TIMER_LIMIT' \
    "$full/reproduction-summary.txt" || fail "full summary has the wrong limited status"
[[ -s "$full/task3-faults/fault-summary.json" ]] ||
    fail "full mode did not summarize fault evidence"
tar -tzf "$full/task123-full-evidence.tar.gz" | grep -Fxq \
    './task3-faults/malformed/manifest.txt' ||
    fail "full archive is missing fault evidence"

: > "$tmp/calls.log"
failed="$tmp/failed"
expect_failure "a non-realtime phase failure was accepted" \
    env FAKE_FAIL_MODE=task3 FAKE_CALL_LOG="$tmp/calls.log" \
        TASK123_RUNNER="$tools/run-task123" \
        TASK123_FAULT_SUMMARIZER="$tools/summarize-faults" \
        "$REPRODUCER" --quick --output "$failed"
[[ "$(wc -l < "$tmp/calls.log")" -eq 3 ]] ||
    fail "reproducer continued after a hard phase failure"
[[ ! -e "$failed/task123-quick-evidence.tar.gz" ]] ||
    fail "reproducer archived a failed hard run as evidence"

: > "$tmp/calls.log"
malformed="$tmp/malformed"
expect_failure "malformed phase evidence was accepted" \
    env FAKE_MALFORMED_MODE=task3 FAKE_CALL_LOG="$tmp/calls.log" \
        TASK123_RUNNER="$tools/run-task123" \
        TASK123_FAULT_SUMMARIZER="$tools/summarize-faults" \
        "$REPRODUCER" --quick --output "$malformed"
[[ ! -e "$malformed/task123-quick-evidence.tar.gz" ]] ||
    fail "reproducer archived malformed evidence"

expect_failure "quick and full were accepted together" \
    "$REPRODUCER" --quick --full --output "$tmp/conflicting"
mkdir -p -- "$tmp/nonempty"
printf 'owned\n' > "$tmp/nonempty/file"
expect_failure "non-empty output directory was accepted" \
    "$REPRODUCER" --output "$tmp/nonempty"

echo "reproduce_task123 contract tests: PASS"
