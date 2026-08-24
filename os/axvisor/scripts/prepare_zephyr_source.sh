#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/network_env.sh"
DESTINATION="${1:-}"
ZEPHYR_VERSION=v4.4.2
ZEPHYR_COMMIT=dccb09599635bdff17633fa7e9dab014b91dce90
ZEPHYR_TARBALL_SHA256=f4c6bc6ad9f741759ac6bebbd5e378f827fe73cee851a0c35950fd0c0da0d909
ZEPHYR_URL="${ZEPHYR_URL:-https://codeload.github.com/zephyrproject-rtos/zephyr/tar.gz/$ZEPHYR_COMMIT}"
SOURCE_CACHE="${TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache}"
VERSION_ROOT="$SOURCE_CACHE/zephyr/$ZEPHYR_COMMIT"
TARBALL="$VERSION_ROOT/source.tar.gz"
CACHE="$VERSION_ROOT/source"

die() { echo "prepare-zephyr: $*" >&2; exit 1; }
[[ -n "$DESTINATION" ]] || die "destination argument is required"
mkdir -p -- "$VERSION_ROOT" "$(dirname -- "$DESTINATION")"

if [[ ! -f "$TARBALL" ]]; then
    echo "Fetching Zephyr source $ZEPHYR_VERSION ($ZEPHYR_COMMIT)"
    curl --proxy "$TGOS_HTTP_PROXY" --http1.1 --fail --location --retry 10 \
        --retry-all-errors --retry-delay 2 --progress-bar \
        --output "$TARBALL.download" "$ZEPHYR_URL"
    [[ "$(sha256sum -- "$TARBALL.download" | cut -d' ' -f1)" == "$ZEPHYR_TARBALL_SHA256" ]] ||
        die "Zephyr source digest mismatch"
    mv -- "$TARBALL.download" "$TARBALL"
fi

[[ "$(sha256sum -- "$TARBALL" | cut -d' ' -f1)" == "$ZEPHYR_TARBALL_SHA256" ]] ||
    die "cached Zephyr source digest mismatch: $TARBALL"

if [[ ! -f "$CACHE/.prepared" ]]; then
    staging="$(mktemp -d "$VERSION_ROOT/.prepare.XXXXXX")"
    trap 'rm -rf -- "$staging"' EXIT
    tar -xzf "$TARBALL" --strip-components=1 -C "$staging"
    printf '%s %s %s\n' "$ZEPHYR_VERSION" "$ZEPHYR_COMMIT" "$ZEPHYR_TARBALL_SHA256" \
        > "$staging/.prepared"
    mv -- "$staging" "$CACHE"
    trap - EXIT
else
    read -r cached_version cached_commit cached_digest < "$CACHE/.prepared"
    [[ "$cached_version $cached_commit $cached_digest" == "$ZEPHYR_VERSION $ZEPHYR_COMMIT $ZEPHYR_TARBALL_SHA256" ]] ||
        die "cached Zephyr metadata does not match the pin"
fi

if [[ "$DESTINATION" == "$CACHE" ]]; then
    echo "Using persistent Zephyr source in place at $CACHE"
else
    [[ ! -e "$DESTINATION" ]] || rm -rf -- "$DESTINATION"
    cp -a -- "$CACHE" "$DESTINATION"
fi
echo "Prepared Zephyr source at $DESTINATION ($ZEPHYR_VERSION $ZEPHYR_COMMIT)"
