#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

SOURCE_DIR="$BUILD_DIR/sources"
DOWNLOAD_DIR="$BUILD_DIR/downloads"
TOOLCHAIN_DIR="$BUILD_DIR/toolchains/arm-gnu-toolchain-$ARM_TOOLCHAIN_VERSION"
mode=all

case "${1:-}" in
    "") ;;
    --sources-only) mode=sources ;;
    --toolchain-only) mode=toolchain ;;
    *) die "usage: $0 [--sources-only|--toolchain-only]" ;;
esac

clone_locked() {
    name=$1
    url=$2
    commit=$3
    destination=$4

    if [ -e "$destination" ]; then
        [ -d "$destination/.git" ] ||
            die "$name destination exists but is not a git checkout: $destination"
        actual_origin=$(git -C "$destination" remote get-url origin)
        [ "$actual_origin" = "$url" ] ||
            die "$name origin mismatch: $actual_origin"
        actual_commit=$(git -C "$destination" rev-parse HEAD)
        [ "$actual_commit" = "$commit" ] ||
            die "$name commit mismatch: expected $commit, got $actual_commit"
        [ -z "$(git -C "$destination" symbolic-ref -q HEAD)" ] ||
            die "$name checkout is not detached: $destination"
        [ -z "$(git -C "$destination" status --porcelain)" ] ||
            die "$name checkout has local changes: $destination"
        printf '%s=%s\n' "$name" "$actual_commit"
        return
    fi
    git init --quiet "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth=1 --filter=blob:none origin "$commit"
    git -C "$destination" checkout --quiet --detach FETCH_HEAD
    actual_commit=$(git -C "$destination" rev-parse HEAD)
    [ "$actual_commit" = "$commit" ] ||
        die "$name checkout failed: expected $commit, got $actual_commit"
    [ -z "$(git -C "$destination" symbolic-ref -q HEAD)" ] ||
        die "$name checkout is not detached: $destination"
    printf '%s=%s\n' "$name" "$actual_commit"
}

fetch_sources() {
    require_command git
    mkdir -p "$SOURCE_DIR"
    clone_locked rt-thread https://github.com/RT-Thread/rt-thread.git \
        "$RTTHREAD_COMMIT" "$SOURCE_DIR/rt-thread"
    clone_locked buildroot "$BUILDROOT_URL" \
        "$BUILDROOT_COMMIT" "$SOURCE_DIR/buildroot"
}

fetch_toolchain() {
    archive="$DOWNLOAD_DIR/arm-gnu-toolchain-$ARM_TOOLCHAIN_VERSION.tar.xz"
    compiler="$TOOLCHAIN_DIR/bin/aarch64-none-elf-gcc"

    require_command curl
    require_command tar
    require_command xz
    mkdir -p "$DOWNLOAD_DIR" "$BUILD_DIR/toolchains"
    if [ ! -f "$archive" ]; then
        curl --fail --location --retry 3 --output "$archive.part" \
            "$ARM_TOOLCHAIN_URL"
        mv "$archive.part" "$archive"
    fi
    verify_sha256 "$archive" "$ARM_TOOLCHAIN_SHA256"
    if [ ! -x "$compiler" ]; then
        temporary="$BUILD_DIR/toolchains/.extract-$ARM_TOOLCHAIN_VERSION"
        rm -rf "$temporary"
        mkdir -p "$temporary"
        tar -xJf "$archive" -C "$temporary" --strip-components=1
        rm -rf "$TOOLCHAIN_DIR"
        mv "$temporary" "$TOOLCHAIN_DIR"
    fi
    "$compiler" --version | sed -n '1p'
}

case "$mode" in
    all)
        fetch_sources
        fetch_toolchain
        ;;
    sources) fetch_sources ;;
    toolchain) fetch_toolchain ;;
esac
