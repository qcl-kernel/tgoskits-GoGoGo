#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
SEED_REPOSITORY="${RTTHREAD_TEST_REPOSITORY:-$ROOT/tmp/rt-thread-5.2.2-full}"
EXPECTED_COMMIT="ddf52e2cdd977f14fc04035c88672ac204aec713"
TEST_ROOT="$(mktemp -d /tmp/tgoskits-rtthread-prepare.XXXXXX)"
DESTINATION="$TEST_ROOT/rt-thread"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

if [[ ! -x "$PREPARE" ]]; then
    echo "FAIL: RT-Thread source preparation script is missing or not executable" >&2
    exit 1
fi
if [[ ! -d "$SEED_REPOSITORY/.git" ]]; then
    echo "FAIL: test seed repository is unavailable: $SEED_REPOSITORY" >&2
    exit 1
fi

RTTHREAD_REPOSITORY="$SEED_REPOSITORY" "$PREPARE" "$DESTINATION"

actual_commit="$(git -C "$DESTINATION" rev-parse HEAD)"
if [[ "$actual_commit" != "$EXPECTED_COMMIT" ]]; then
    echo "FAIL: expected RT-Thread commit $EXPECTED_COMMIT, got $actual_commit" >&2
    exit 1
fi
if [[ -n "$(git -C "$DESTINATION" status --short)" ]]; then
    echo "FAIL: freshly prepared RT-Thread source is dirty" >&2
    exit 1
fi

touch "$DESTINATION/.prepare-idempotence-marker"
RTTHREAD_REPOSITORY="$SEED_REPOSITORY" "$PREPARE" "$DESTINATION"
if [[ ! -f "$DESTINATION/.prepare-idempotence-marker" ]]; then
    echo "FAIL: repeated preparation replaced the existing source tree" >&2
    exit 1
fi

echo "RT-Thread source preparation test: PASS"
