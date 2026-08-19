#!/bin/sh

# Shared persistent source/toolchain cache helpers. The cache stores clean,
# pinned inputs; derived build output remains under BUILD_DIR.

source_cache_root() {
    printf '%s\n' "${TGOS_SOURCE_CACHE:-$TASK3_ROOT/../../../../tmp/source-cache}"
}

source_cache_lock() {
    key=$1
    root=$(source_cache_root)
    printf '%s/.locks/%s.lock\n' "$root" "$key"
}
