#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ENTRYPOINT="$ROOT/run-task123.sh"

grep -Fq 'RTTHREAD_REQUIRE_IMAGE_METADATA' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not enforce RT-Thread image metadata" >&2
    exit 1
}
grep -Fq 'RTTHREAD_IMAGE_META' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not propagate RT-Thread metadata" >&2
    exit 1
}
grep -Fq 'rt-thread-5.2.2-native-current' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not prefer the persistent RT-Thread image" >&2
    exit 1
}
grep -Fq 'env "${runner_environment[@]}"' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not pass resolved inputs to the runner" >&2
    exit 1
}

echo "PASS: direct task123 entrypoint selects and validates RT-Thread image"
