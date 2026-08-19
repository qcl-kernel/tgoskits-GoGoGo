#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
HELPERS="$ROOT/os/axvisor/patches/rtthread/patch_helpers.sh"
TEST_ROOT="$(mktemp -d /tmp/tgoskits-patch-helper.XXXXXX)"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$HELPERS" ]]; then
    echo "FAIL: RT-Thread patch helper is missing: $HELPERS" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$HELPERS"

if (
    git() {
        if [[ " $* " == *' apply --check '* ]]; then
            return 0
        fi
        return 42
    }
    apply_patch_exactly "$TEST_ROOT" "$TEST_ROOT/failing.patch" \
        "failing apply fixture"
) >"$TEST_ROOT/apply-failure.out" 2>&1; then
    echo "FAIL: helper hid a git apply failure" >&2
    exit 1
fi
if grep -q '^Applied failing apply fixture$' "$TEST_ROOT/apply-failure.out"; then
    echo "FAIL: helper reported a failed git apply as applied" >&2
    exit 1
fi

REPOSITORY="$TEST_ROOT/repository"
PATCH_FILE="$TEST_ROOT/two-hunk.patch"
mkdir -p -- "$REPOSITORY"
git -C "$REPOSITORY" init --quiet
git -C "$REPOSITORY" config user.name test
git -C "$REPOSITORY" config user.email test@example.invalid
printf 'alpha\nbeta\nseparator-1\nseparator-2\nseparator-3\nseparator-4\nseparator-5\nseparator-6\nseparator-7\nseparator-8\nseparator-9\nseparator-10\ngamma\ndelta\n' \
    >"$REPOSITORY/sample.txt"
git -C "$REPOSITORY" add sample.txt
git -C "$REPOSITORY" commit --quiet -m baseline
sed -i 's/^alpha$/ALPHA/; s/^gamma$/GAMMA/' "$REPOSITORY/sample.txt"
git -C "$REPOSITORY" diff --binary >"$PATCH_FILE"
git -C "$REPOSITORY" restore sample.txt
if [[ "$(grep -c '^@@ ' "$PATCH_FILE")" -ne 2 ]]; then
    echo "FAIL: partial-application fixture must contain exactly two hunks" >&2
    exit 1
fi

apply_patch_exactly "$REPOSITORY" "$PATCH_FILE" "two-hunk fixture"
grep -qx ALPHA "$REPOSITORY/sample.txt"
grep -qx GAMMA "$REPOSITORY/sample.txt"

apply_patch_exactly "$REPOSITORY" "$PATCH_FILE" "two-hunk fixture"

sed -i 's/^GAMMA$/gamma/' "$REPOSITORY/sample.txt"
if apply_patch_exactly "$REPOSITORY" "$PATCH_FILE" "partial fixture" \
    >"$TEST_ROOT/partial.out" 2>&1; then
    echo "FAIL: helper accepted a partially applied patch" >&2
    exit 1
fi
if ! grep -q 'partially applied or source has drifted' "$TEST_ROOT/partial.out"; then
    echo "FAIL: partial-patch rejection did not explain the source mismatch" >&2
    exit 1
fi

echo "RT-Thread exact patch helper test: PASS"
