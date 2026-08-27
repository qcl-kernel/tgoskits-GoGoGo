#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/source_cache.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

SOURCE_CACHE=$(source_cache_root)
RTTHREAD_CACHE="$SOURCE_CACHE/rt-thread/$RTTHREAD_COMMIT"
BUILDROOT_CACHE="$SOURCE_CACHE/buildroot/$BUILDROOT_COMMIT"
TOOLCHAIN_CACHE="$SOURCE_CACHE/arm-gnu-toolchain/$ARM_TOOLCHAIN_VERSION"
RTTHREAD_URL="https://github.com/RT-Thread/rt-thread.git"
SOURCE_DIR="$BUILD_DIR/sources"
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
    cache=$5
    lock=$6
    source=$cache/source

    mkdir -p "$(dirname "$lock")" "$cache" "$(dirname "$destination")"
    exec 8>"$lock"
    flock 8

    if [ -e "$source" ]; then
        [ -d "$source/.git" ] ||
            die "$name cached source exists but is not a git checkout: $source"
        actual_origin=$(git -C "$source" remote get-url origin)
        [ "$actual_origin" = "$url" ] ||
            die "$name cache origin mismatch: $actual_origin"
        actual_commit=$(git -C "$source" rev-parse HEAD)
        [ "$actual_commit" = "$commit" ] ||
            die "$name cache commit mismatch: expected $commit, got $actual_commit"
        [ -z "$(git -C "$source" symbolic-ref -q HEAD)" ] ||
            die "$name cached checkout is not detached: $source"
        [ -z "$(git -C "$source" status --porcelain)" ] ||
            die "$name cached source has local changes: $source"
        echo "Using cached $name source $source ($commit)"
    else
        staging=$(mktemp -d "$cache/.source.XXXXXX")
        cleanup_source_staging() {
            rm -rf -- "${staging:?}"
        }
        trap cleanup_source_staging EXIT HUP INT TERM
        git init "$staging/source"
        git -C "$staging/source" remote add origin "$url"
        git -C "$staging/source" fetch --progress --depth=1 --filter=blob:none origin "$commit"
        git -C "$staging/source" checkout --progress --detach FETCH_HEAD
        actual_commit=$(git -C "$staging/source" rev-parse HEAD)
        [ "$actual_commit" = "$commit" ] ||
            die "$name checkout failed: expected $commit, got $actual_commit"
        mv "$staging/source" "$source"
        rmdir "$staging"
        trap - EXIT HUP INT TERM
        echo "Fetched $name source into $source ($commit)"
    fi

    [ ! -e "$destination" ] || rm -rf -- "$destination"
    ln -s "$source" "$destination"
}

fetch_sources() {
    require_command git
    mkdir -p "$SOURCE_DIR"
    clone_locked rt-thread "$RTTHREAD_URL" \
        "$RTTHREAD_COMMIT" "$SOURCE_DIR/rt-thread" \
        "$RTTHREAD_CACHE" "$(source_cache_lock rtthread-$RTTHREAD_COMMIT)"
    clone_locked buildroot "$BUILDROOT_URL" \
        "$BUILDROOT_COMMIT" "$SOURCE_DIR/buildroot" \
        "$BUILDROOT_CACHE" "$(source_cache_lock buildroot-$BUILDROOT_COMMIT)"
}

fetch_toolchain() {
    archive="$TOOLCHAIN_CACHE/archive.tar.xz"
    compiler="$TOOLCHAIN_CACHE/extracted/bin/aarch64-none-elf-gcc"

    require_command curl
    require_command tar
    require_command xz
    lock=$(source_cache_lock "arm-gnu-toolchain-$ARM_TOOLCHAIN_VERSION")
    mkdir -p "$(dirname "$lock")" "$TOOLCHAIN_CACHE" "$BUILD_DIR/toolchains"
    exec 8>"$lock"
    flock 8

    if [ ! -f "$archive" ]; then
        curl --fail --location --retry 3 --output "$archive.part" \
            "$ARM_TOOLCHAIN_URL"
        mv "$archive.part" "$archive"
    fi
    verify_sha256 "$archive" "$ARM_TOOLCHAIN_SHA256"
    if [ ! -x "$compiler" ]; then
        temporary="$TOOLCHAIN_CACHE/.extract-$ARM_TOOLCHAIN_VERSION"
        rm -rf "$temporary" "$TOOLCHAIN_CACHE/extracted"
        mkdir -p "$temporary"
        tar -xJf "$archive" -C "$temporary" --strip-components=1
        mv "$temporary" "$TOOLCHAIN_CACHE/extracted"
    fi
    "$compiler" --version | sed -n '1p'
    [ ! -e "$TOOLCHAIN_DIR" ] || rm -rf -- "$TOOLCHAIN_DIR"
    ln -s "$TOOLCHAIN_CACHE/extracted" "$TOOLCHAIN_DIR"
}

case "$mode" in
    all)
        fetch_sources
        fetch_toolchain
        ;;
    sources) fetch_sources ;;
    toolchain) fetch_toolchain ;;
esac
