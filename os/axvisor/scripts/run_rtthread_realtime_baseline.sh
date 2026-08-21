#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
NATIVE_RUNNER="$SCRIPT_DIR/run_rtthread_native_baseline.sh"
TASK123_RUNNER="$SCRIPT_DIR/run_task123.sh"
SUMMARIZER="$SCRIPT_DIR/summarize_rtthread_realtime.py"
IMAGE_METADATA="$SCRIPT_DIR/rtthread_image_metadata.py"
STATUS_FILE=
QEMU="${QEMU:-$(command -v qemu-system-aarch64 || true)}"

usage() {
    cat >&2 <<'EOF'
usage: run_rtthread_realtime_baseline.sh [--quick] --output DIR
  --quick                 10 suite samples and short stability runs
  --suite-samples N       Suite samples (default 100000)
  --stability-seconds N   Stability duration (default 300)
  --skip-suite            Run only stability comparisons
  --skip-stability        Run only suite comparisons
EOF
    exit 2
}

require_integer() {
    local label=$1 value=$2 minimum=$3 maximum=$4
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge "$minimum" && "$value" -le "$maximum" ]] ||
        { echo "$label must be an integer from $minimum to $maximum" >&2; exit 2; }
}

quick=0
suite_samples=100000
stability_seconds=300
skip_suite=0
skip_stability=0
explicit_suite_samples=0
explicit_stability_seconds=0
output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) quick=1; shift ;;
        --suite-samples|--stability-seconds|--output)
            [[ $# -ge 2 ]] || usage
            option=$1
            value=$2
            case "$option" in
                --suite-samples) suite_samples=$value; explicit_suite_samples=1 ;;
                --stability-seconds) stability_seconds=$value; explicit_stability_seconds=1 ;;
                --output) output=$value ;;
            esac
            shift 2 ;;
        --skip-suite) skip_suite=1; shift ;;
        --skip-stability) skip_stability=1; shift ;;
        *) usage ;;
    esac
done
[[ -n "$output" ]] || usage
[[ "$quick" -eq 0 || ( "$explicit_suite_samples" -eq 0 && "$explicit_stability_seconds" -eq 0 ) ]] || usage
[[ -n "$QEMU" && -x "$QEMU" ]] || {
    echo "qemu-system-aarch64 is not available: $QEMU" >&2
    exit 1
}
require_integer suite-samples "$suite_samples" 1 100000
require_integer stability-seconds "$stability_seconds" 1 3600
[[ "$skip_suite" -eq 0 || "$skip_stability" -eq 0 ]] || usage
if [[ "$quick" -eq 1 ]]; then
    suite_samples=10
    stability_seconds=10
fi

mkdir -p -- "$output"
output="$(cd -- "$output" && pwd)"
STATUS_FILE="$output/status.tsv"
: > "$STATUS_FILE"
default_task2_count="${TASK2_COUNT:-30000}"
native_src="${RTTHREAD_NATIVE_SRC:-$ROOT/tmp/rt-thread-5.2.2-native-current}"
rtthread_image="${RTTHREAD_IMAGE:-$native_src/bsp/qemu-virt64-aarch64/rtthread.bin}"
rtthread_image_explicit=0
[[ -n "${RTTHREAD_IMAGE:-}" ]] && rtthread_image_explicit=1
rtthread_metadata="${RTTHREAD_IMAGE_META:-$rtthread_image.meta.json}"
rootfs="${ROOTFS_IMAGE:-$ROOT/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img}"
[[ -f "$rootfs" ]] || { echo "rootfs image not found: $rootfs" >&2; exit 1; }

validate_rtthread_image() {
    python3 "$IMAGE_METADATA" check \
        --image "$rtthread_image" \
        --metadata "$rtthread_metadata" \
        --source "$native_src"
}

if [[ "$rtthread_image_explicit" -eq 1 ]]; then
    validate_rtthread_image
fi

run_suite() {
    echo "PHASE native-suite samples=$suite_samples"
    if RTBENCH_MODE=suite RTBENCH_SUITE_SAMPLES="$suite_samples" \
        QEMU="$QEMU" \
        RTTHREAD_NATIVE_SRC="$native_src" \
        NATIVE_GUEST_LOG="$output/native-suite.log" \
        NATIVE_QEMU_LOG="$output/native-suite.qemu.log" \
        "$NATIVE_RUNNER" | tee "$output/native-suite.runner.log"; then
        printf 'native-suite\tPASS\n' >> "$STATUS_FILE"
    else
        rc=$?
        printf 'native-suite\tFAIL\trc=%s\n' "$rc" >> "$STATUS_FILE"
        cat "$STATUS_FILE" >&2
        exit "$rc"
    fi
    validate_rtthread_image

    echo "PHASE axvisor-only-suite samples=$suite_samples"
    if QEMU="$QEMU" RTTHREAD_IMAGE_META="$rtthread_metadata" \
        "$SCRIPT_DIR/run_rtthread_axvisor_only.sh" \
        --image "$rtthread_image" --suite-samples "$suite_samples" \
        --core-suite \
        --output "$output/axvisor-only-suite" | tee "$output/axvisor-only-suite.runner.log"; then
        printf 'axvisor-only-suite\tPASS\n' >> "$STATUS_FILE"
    else
        rc=$?
        printf 'axvisor-only-suite\tFAIL-CONTINUE\trc=%s\n' "$rc" >> "$STATUS_FILE"
        echo "WARN: B suite failed; retain evidence and continue if data is complete" >&2
    fi

    echo "PHASE axvisor-linux-suite samples=$suite_samples"
    if QEMU="$QEMU" ROOTFS_IMAGE="$rootfs" RTTHREAD_IMAGE="$rtthread_image" \
        RTTHREAD_IMAGE_META="$rtthread_metadata" RTTHREAD_REQUIRE_IMAGE_METADATA=1 \
        TASK123_TIMEOUT_S="$((suite_samples / 100 + 900))" \
        "$TASK123_RUNNER" --app-guest linux --mode realtime-suite \
        --rtbench-samples "$suite_samples" --task2-count "$default_task2_count" \
        --output "$output/axvisor-linux-suite" | tee "$output/axvisor-linux-suite.runner.log"; then
        printf 'axvisor-linux-suite\tPASS\n' >> "$STATUS_FILE"
    else
        rc=$?
        printf 'axvisor-linux-suite\tFAIL-CONTINUE\trc=%s\n' "$rc" >> "$STATUS_FILE"
        echo "WARN: C suite failed; retain evidence and continue if data is complete" >&2
    fi

    echo "PHASE summarize-suite"
    python3 "$SUMMARIZER" \
        --native "$output/native-suite.log" \
        --axvisor-only "$output/axvisor-only-suite/console.log" \
        --axvisor-linux "$output/axvisor-linux-suite/console.log" \
        --axvisor-only-core \
        --suite-samples "$suite_samples" \
        --json-output "$output/realtime-suite.json" \
        --csv-output "$output/realtime-suite.csv" \
        --joint-csv-output "$output/realtime-suite-joint.csv" \
        --markdown-output "$output/realtime-suite.md" | tee "$output/realtime-suite.summary.log"
}

run_stability() {
    echo "PHASE native-stability seconds=$stability_seconds"
    if RTBENCH_STABILITY_SECONDS="$stability_seconds" \
        RTBENCH_ALLOW_QEMU_TIMER_LIMIT=1 \
        QEMU="$QEMU" \
        RTTHREAD_NATIVE_SRC="$native_src" \
        NATIVE_GUEST_LOG="$output/native-stability.log" \
        NATIVE_QEMU_LOG="$output/native-stability.qemu.log" \
        "$NATIVE_RUNNER" | tee "$output/native-stability.runner.log"; then
        if grep -aFq 'RTBENCH_STABILITY_END status=FAIL' "$output/native-stability.log"; then
            printf 'native-stability\tPASS_WITH_QEMU_TIMER_LIMIT\n' >> "$STATUS_FILE"
        else
            printf 'native-stability\tPASS\n' >> "$STATUS_FILE"
        fi
    else
        rc=$?
        printf 'native-stability\tFAIL\trc=%s\n' "$rc" >> "$STATUS_FILE"
        cat "$STATUS_FILE" >&2
        exit "$rc"
    fi
    validate_rtthread_image

    echo "PHASE axvisor-only-stability seconds=$stability_seconds"
    if QEMU="$QEMU" RTTHREAD_IMAGE_META="$rtthread_metadata" \
        "$SCRIPT_DIR/run_rtthread_axvisor_only.sh" \
        --image "$rtthread_image" --stability-seconds "$stability_seconds" \
        --output "$output/axvisor-only-stability" | tee "$output/axvisor-only-stability.runner.log"; then
        printf 'axvisor-only-stability\tPASS\n' >> "$STATUS_FILE"
    else
        rc=$?
        printf 'axvisor-only-stability\tFAIL-CONTINUE\trc=%s\n' "$rc" >> "$STATUS_FILE"
        echo "WARN: B stability failed; retain evidence and continue if data is complete" >&2
    fi

    echo "PHASE axvisor-linux-stability seconds=$stability_seconds"
    if QEMU="$QEMU" ROOTFS_IMAGE="$rootfs" RTTHREAD_IMAGE="$rtthread_image" \
        RTTHREAD_IMAGE_META="$rtthread_metadata" RTTHREAD_REQUIRE_IMAGE_METADATA=1 \
        TASK123_TIMEOUT_S="$((stability_seconds + 900))" \
        TASK123_ALLOW_QEMU_TIMER_LIMIT=1 \
        "$TASK123_RUNNER" --app-guest linux --mode stability \
        --seconds "$stability_seconds" --task2-count "$default_task2_count" \
        --output "$output/axvisor-linux-stability" | tee "$output/axvisor-linux-stability.runner.log"; then
        printf 'axvisor-linux-stability\tPASS\n' >> "$STATUS_FILE"
    else
        rc=$?
        printf 'axvisor-linux-stability\tFAIL-CONTINUE\trc=%s\n' "$rc" >> "$STATUS_FILE"
        echo "WARN: C stability failed; retain evidence and continue if data is complete" >&2
    fi

    echo "PHASE summarize-stability"
    python3 "$SUMMARIZER" --stability \
        --native "$output/native-stability.log" \
        --axvisor-only "$output/axvisor-only-stability/console.log" \
        --axvisor-linux "$output/axvisor-linux-stability/console.log" \
        --json-output "$output/realtime-stability.json" \
        --csv-output "$output/realtime-stability.csv" \
        --joint-csv-output "$output/realtime-stability-joint.csv" \
        --markdown-output "$output/realtime-stability.md" | tee "$output/realtime-stability.summary.log"
}

if [[ "$skip_suite" -eq 0 ]]; then run_suite; fi
if [[ "$skip_stability" -eq 0 ]]; then run_stability; fi
echo "STATUS"
cat "$STATUS_FILE"
echo "RT-Thread realtime baseline complete: $output"
