#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
DESTINATION="${1:-$ROOT/tmp/rt-thread-5.2.2-full}"
RTTHREAD_REPOSITORY="${RTTHREAD_REPOSITORY:-https://github.com/RT-Thread/rt-thread.git}"
RTTHREAD_COMMIT="ddf52e2cdd977f14fc04035c88672ac204aec713"

if [[ -e "$DESTINATION" ]]; then
    if [[ ! -d "$DESTINATION/.git" ]]; then
        echo "RT-Thread destination exists but is not a Git repository: $DESTINATION" >&2
        exit 1
    fi

    actual_commit="$(git -C "$DESTINATION" rev-parse HEAD)"
    if [[ "$actual_commit" != "$RTTHREAD_COMMIT" ]]; then
        echo "RT-Thread source has unexpected commit: $actual_commit" >&2
        echo "Expected pinned commit: $RTTHREAD_COMMIT" >&2
        exit 1
    fi

    echo "Using existing RT-Thread source at $DESTINATION ($RTTHREAD_COMMIT)"
    exit 0
fi

destination_parent="$(dirname -- "$DESTINATION")"
mkdir -p -- "$destination_parent"
staging_root="$(mktemp -d "$destination_parent/.rtthread-source.XXXXXX")"

cleanup() {
    rm -rf -- "$staging_root"
}
trap cleanup EXIT

echo "Fetching RT-Thread source from $RTTHREAD_REPOSITORY"
git clone --quiet --no-checkout "$RTTHREAD_REPOSITORY" "$staging_root/source"
git -C "$staging_root/source" checkout --quiet --detach "$RTTHREAD_COMMIT"
mv -- "$staging_root/source" "$DESTINATION"
rmdir -- "$staging_root"
trap - EXIT

echo "Prepared RT-Thread source at $DESTINATION ($RTTHREAD_COMMIT)"
