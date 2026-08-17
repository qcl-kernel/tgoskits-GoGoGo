#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
DESTINATION="${1:-$ROOT/tmp/rt-thread-5.2.2-full}"
RTTHREAD_REPOSITORY="${RTTHREAD_REPOSITORY:-https://github.com/RT-Thread/rt-thread.git}"
RTTHREAD_COMMIT="ddf52e2cdd977f14fc04035c88672ac204aec713"

validate_existing_source() {
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

    dirty="$(git -C "$DESTINATION" status --porcelain=v1 --untracked-files=all)"
    if [[ -n "$dirty" ]]; then
        echo "RT-Thread source tree is dirty: $DESTINATION" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    fi

    echo "Using existing RT-Thread source at $DESTINATION ($RTTHREAD_COMMIT)"
}

destination_parent="$(dirname -- "$DESTINATION")"
mkdir -p -- "$destination_parent"
if ! command -v flock >/dev/null 2>&1; then
    echo "RT-Thread source preparation requires flock" >&2
    exit 1
fi
lock_path="$destination_parent/.$(basename -- "$DESTINATION").prepare.lock"
exec {lock_fd}>"$lock_path"
flock "$lock_fd"

if [[ -e "$DESTINATION" ]]; then
    validate_existing_source
    exit 0
fi

staging_root="$(mktemp -d "$destination_parent/.rtthread-source.XXXXXX")"

cleanup() {
    rm -rf -- "$staging_root"
}
trap cleanup EXIT

echo "Fetching RT-Thread source from $RTTHREAD_REPOSITORY"
git init --quiet "$staging_root/source"
git -C "$staging_root/source" remote add origin "$RTTHREAD_REPOSITORY"
git -C "$staging_root/source" sparse-checkout init --cone
git -C "$staging_root/source" sparse-checkout set \
    bsp/qemu-virt64-aarch64 \
    components \
    include \
    libcpu/aarch64 \
    src \
    tools
git -C "$staging_root/source" fetch --quiet --depth=1 --filter=blob:none \
    origin "$RTTHREAD_COMMIT"
git -C "$staging_root/source" checkout --quiet --detach FETCH_HEAD
mv -- "$staging_root/source" "$DESTINATION"
rmdir -- "$staging_root"
trap - EXIT

echo "Prepared RT-Thread source at $DESTINATION ($RTTHREAD_COMMIT)"
