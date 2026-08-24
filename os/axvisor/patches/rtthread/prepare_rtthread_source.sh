#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
DESTINATION="${1:-$ROOT/tmp/rt-thread-5.2.2-full}"
RTTHREAD_REPOSITORY="${RTTHREAD_REPOSITORY:-https://github.com/RT-Thread/rt-thread.git}"
RTTHREAD_COMMIT="ddf52e2cdd977f14fc04035c88672ac204aec713"
RTTHREAD_REF="${RTTHREAD_REF:-v5.2.2}"
SOURCE_CACHE="${TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache}"
RTTHREAD_CACHE="$SOURCE_CACHE/rt-thread/$RTTHREAD_COMMIT"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ -f "$SCRIPT_DIR/../../scripts/network_env.sh" ]]; then
    source "$SCRIPT_DIR/../../scripts/network_env.sh"
fi

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
mkdir -p -- "$RTTHREAD_CACHE" "$SOURCE_CACHE/.locks"
if ! command -v flock >/dev/null 2>&1; then
    echo "RT-Thread source preparation requires flock" >&2
    exit 1
fi
lock_path="$SOURCE_CACHE/.locks/rtthread-$RTTHREAD_COMMIT.lock"
exec {lock_fd}>"$lock_path"
flock "$lock_fd"

if [[ -d "$RTTHREAD_CACHE/source/.git" ]]; then
    actual_commit="$(git -C "$RTTHREAD_CACHE/source" rev-parse HEAD)"
    [[ "$actual_commit" == "$RTTHREAD_COMMIT" ]] || {
        echo "RT-Thread source cache has unexpected commit: $actual_commit" >&2
        echo "Expected pinned commit: $RTTHREAD_COMMIT" >&2
        exit 1
    }
    dirty="$(git -C "$RTTHREAD_CACHE/source" status --porcelain=v1 --untracked-files=all)"
    [[ -z "$dirty" ]] || {
        echo "RT-Thread source cache is dirty: $RTTHREAD_CACHE/source" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    }
    echo "Using cached RT-Thread source at $RTTHREAD_CACHE/source ($RTTHREAD_COMMIT)"
else
    staging_root="$(mktemp -d "$RTTHREAD_CACHE/.prepare.XXXXXX")"

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
        origin "$RTTHREAD_REF"
    git -C "$staging_root/source" checkout --quiet --detach FETCH_HEAD
    actual_commit="$(git -C "$staging_root/source" rev-parse HEAD)"
    [[ "$actual_commit" == "$RTTHREAD_COMMIT" ]] || {
        echo "RT-Thread checkout failed: expected $RTTHREAD_COMMIT, got $actual_commit" >&2
        exit 1
    }
    mv -- "$staging_root/source" "$RTTHREAD_CACHE/source"
    rmdir -- "$staging_root"
    trap - EXIT
    echo "Fetched RT-Thread source into $RTTHREAD_CACHE/source ($RTTHREAD_COMMIT)"
fi

[[ ! -e "$DESTINATION" ]] || rm -rf -- "$DESTINATION"
cp -a -- "$RTTHREAD_CACHE/source" "$DESTINATION"

echo "Prepared RT-Thread source at $DESTINATION ($RTTHREAD_COMMIT)"
