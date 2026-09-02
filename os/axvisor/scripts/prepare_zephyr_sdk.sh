#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/network_env.sh"
DESTINATION="${1:-}"
ZEPHYR_SDK_VERSION=1.0.1
ZEPHYR_SDK_ASSET=toolchain_gnu_linux-x86_64_aarch64-zephyr-elf.tar.xz
ZEPHYR_SDK_SHA256=01c0cfe1daaab2d2a0f71165f11a066d983ef97e51c4a3753186afa6ae55c24b
ZEPHYR_SDK_URL="${ZEPHYR_SDK_URL:-https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v$ZEPHYR_SDK_VERSION/$ZEPHYR_SDK_ASSET}"
SOURCE_CACHE="${TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache}"
VERSION_ROOT="$SOURCE_CACHE/zephyr-sdk"
TARBALL="$VERSION_ROOT/$ZEPHYR_SDK_ASSET"
CACHE="$VERSION_ROOT/zephyr-sdk-$ZEPHYR_SDK_VERSION"

die() { echo "prepare-zephyr-sdk: $*" >&2; exit 1; }
[[ -n "$DESTINATION" ]] || die "destination argument is required"
mkdir -p -- "$VERSION_ROOT"

if [[ ! -f "$CACHE/bin/aarch64-zephyr-elf-gcc" ]]; then
    if [[ ! -f "$TARBALL" ]]; then
        echo "Fetching Zephyr SDK $ZEPHYR_SDK_VERSION AArch64 toolchain"
        curl --proxy "$TGOS_HTTP_PROXY" --http1.1 --fail --location \
            --retry 10 --retry-all-errors --retry-delay 2 --progress-bar \
            --output "$TARBALL.download" "$ZEPHYR_SDK_URL"
        mv -- "$TARBALL.download" "$TARBALL"
    fi
    [[ "$(sha256sum -- "$TARBALL" | cut -d' ' -f1)" == "$ZEPHYR_SDK_SHA256" ]] ||
        die "Zephyr SDK digest mismatch"
    staging="$(mktemp -d "$VERSION_ROOT/.sdk.XXXXXX")"
    trap 'rm -rf -- "$staging"' EXIT
    mkdir -- "$staging/sdk"
    tar -xJf "$TARBALL" -C "$staging/sdk" --strip-components=1
    rm -rf -- "$CACHE"
    mv -- "$staging/sdk" "$CACHE"
    trap - EXIT
fi

[[ -x "$CACHE/bin/aarch64-zephyr-elf-gcc" ]] || die "cached Zephyr SDK compiler is missing"
[[ ! -e "$DESTINATION" ]] || rm -rf -- "$DESTINATION"
ln -s -- "$CACHE" "$DESTINATION"
echo "Prepared Zephyr SDK at $DESTINATION ($ZEPHYR_SDK_VERSION)"
