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
if ! grep -Eq 'git[[:space:]]+-C[[:space:]].*fetch.*--depth=1' "$PREPARE"; then
    echo "FAIL: RT-Thread source preparation must shallow-fetch the pinned commit" >&2
    exit 1
fi
if ! grep -Eq 'fetch.*--filter=blob:none' "$PREPARE"; then
    echo "FAIL: RT-Thread source preparation must omit unneeded blobs" >&2
    exit 1
fi
if ! grep -Eq 'sparse-checkout[[:space:]]+set' "$PREPARE"; then
    echo "FAIL: RT-Thread source preparation must select the AArch64 virt build tree" >&2
    exit 1
fi
if grep -Eq 'git[[:space:]]+clone' "$PREPARE"; then
    echo "FAIL: RT-Thread source preparation must not clone complete history" >&2
    exit 1
fi
if ! grep -Eq 'flock[[:space:]]+"?\$lock_fd"?' "$PREPARE"; then
    echo "FAIL: RT-Thread source preparation must serialize destination publication" >&2
    exit 1
fi
if [[ ! -d "$SEED_REPOSITORY/.git" ]]; then
    echo "FAIL: test seed repository is unavailable: $SEED_REPOSITORY" >&2
    exit 1
fi

prepare_source() {
    local destination="$1"
    RTTHREAD_REPOSITORY="$SEED_REPOSITORY" "$PREPARE" "$destination"
}

expect_dirty_rejected() {
    local label="$1"
    local destination="$2"
    local expected_status="$3"

    if prepare_source "$destination" >"$TEST_ROOT/$label.out" 2>&1; then
        echo "FAIL: preparation accepted a $label RT-Thread source tree" >&2
        exit 1
    fi
    if ! git -C "$destination" status --porcelain=v1 --untracked-files=all \
        | grep -Fq -- "$expected_status"; then
        echo "FAIL: preparation replaced or cleaned a $label RT-Thread source tree" >&2
        exit 1
    fi
    if ! grep -q 'RT-Thread source tree is dirty' "$TEST_ROOT/$label.out"; then
        echo "FAIL: $label rejection did not explain that the source tree is dirty" >&2
        exit 1
    fi
}

prepare_source "$DESTINATION"

actual_commit="$(git -C "$DESTINATION" rev-parse HEAD)"
if [[ "$actual_commit" != "$EXPECTED_COMMIT" ]]; then
    echo "FAIL: expected RT-Thread commit $EXPECTED_COMMIT, got $actual_commit" >&2
    exit 1
fi
if [[ -n "$(git -C "$DESTINATION" status --short)" ]]; then
    echo "FAIL: freshly prepared RT-Thread source is dirty" >&2
    exit 1
fi
if [[ "$(git -C "$DESTINATION" rev-list --count --all)" != 1 ]]; then
    echo "FAIL: freshly prepared RT-Thread source is not a one-commit shallow checkout" >&2
    exit 1
fi
if [[ ! -f "$DESTINATION/.git/shallow" ]] ||
   ! grep -Fxq "$EXPECTED_COMMIT" "$DESTINATION/.git/shallow"; then
    echo "FAIL: freshly prepared RT-Thread source does not record the pinned shallow boundary" >&2
    exit 1
fi
for required_path in \
    bsp/qemu-virt64-aarch64 components include libcpu/aarch64 src tools; do
    if [[ ! -e "$DESTINATION/$required_path" ]]; then
        echo "FAIL: sparse RT-Thread source is missing $required_path" >&2
        exit 1
    fi
done
if [[ -e "$DESTINATION/bsp/stm32" ]]; then
    echo "FAIL: sparse RT-Thread source contains unrelated board support" >&2
    exit 1
fi

prepare_source "$DESTINATION"

CONCURRENT_DESTINATION="$TEST_ROOT/rt-thread-concurrent"
prepare_source "$CONCURRENT_DESTINATION" &
first_pid=$!
prepare_source "$CONCURRENT_DESTINATION" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
if [[ -e "$CONCURRENT_DESTINATION/source" ]]; then
    echo "FAIL: concurrent preparation nested a source tree in the destination" >&2
    exit 1
fi
if [[ "$(git -C "$CONCURRENT_DESTINATION" rev-parse HEAD)" != "$EXPECTED_COMMIT" ]] ||
   [[ -n "$(git -C "$CONCURRENT_DESTINATION" status --short)" ]]; then
    echo "FAIL: concurrent preparation did not publish one clean pinned checkout" >&2
    exit 1
fi

TRACKED_DESTINATION="$TEST_ROOT/rt-thread-tracked"
prepare_source "$TRACKED_DESTINATION"
printf '\ntracked dirty fixture\n' >>"$TRACKED_DESTINATION/README.md"
expect_dirty_rejected tracked "$TRACKED_DESTINATION" ' M README.md'

STAGED_DESTINATION="$TEST_ROOT/rt-thread-staged"
prepare_source "$STAGED_DESTINATION"
printf '\nstaged dirty fixture\n' >>"$STAGED_DESTINATION/README.md"
git -C "$STAGED_DESTINATION" add README.md
expect_dirty_rejected staged "$STAGED_DESTINATION" 'M  README.md'

UNTRACKED_DESTINATION="$TEST_ROOT/rt-thread-untracked"
prepare_source "$UNTRACKED_DESTINATION"
touch "$UNTRACKED_DESTINATION/.tree-must-not-be-replaced"
expect_dirty_rejected untracked "$UNTRACKED_DESTINATION" '?? .tree-must-not-be-replaced'

echo "RT-Thread source preparation test: PASS"
