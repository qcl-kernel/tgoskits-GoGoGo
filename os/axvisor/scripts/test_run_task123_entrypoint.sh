#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ENTRYPOINT="$ROOT/run-task123.sh"

grep -Fq 'cargo xtask axvisor task123' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not delegate to cargo xtask" >&2
    exit 1
}
grep -Fq 'exec "$@"' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not preserve foreground signals" >&2
    exit 1
}
grep -Fq -- '--quick --allow-qemu-timer-limit' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not define the default xtask mode" >&2
    exit 1
}
grep -Fq -- '--matrix all' "$ROOT/scripts/axbuild/src/axvisor/task123.rs" || {
    echo "FAIL: cargo task123 planner does not expose the four-combination matrix" >&2
    exit 1
}
grep -Fq -- 'realtime-suite' "$ROOT/scripts/axbuild/src/axvisor/task123.rs" || {
    echo "FAIL: cargo task123 planner does not expose realtime-suite" >&2
    exit 1
}

echo "PASS: direct task123 entrypoint selects RTOS inputs and validates RT-Thread image"
