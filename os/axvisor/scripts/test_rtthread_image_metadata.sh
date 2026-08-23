#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
META_TOOL="$SCRIPT_DIR/rtthread_image_metadata.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

source_dir="$TMP_ROOT/source"
mkdir -p -- "$source_dir"
printf '%s\n' 'ddf52e2cdd977f14fc04035c88672ac204aec713' \
    >"$source_dir/.axvisor-rtthread-source-commit"
printf '%s\n' 'patch-set-test-digest' \
    >"$source_dir/.axvisor-rtthread-patch-state"
image="$TMP_ROOT/rtthread.bin"
printf '%s\n' 'current RT-Thread image' >"$image"
metadata="$image.meta.json"

python3 "$META_TOOL" write \
    --image "$image" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest \
    --output "$metadata"
python3 "$META_TOOL" check \
    --image "$image" \
    --metadata "$metadata" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest

printf '%s\n' 'stale image contents' >"$image"
if python3 "$META_TOOL" check \
    --image "$image" \
    --metadata "$metadata" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest >/dev/null 2>&1; then
    echo 'FAIL: changed RT-Thread image passed metadata validation' >&2
    exit 1
fi
printf '%s\n' 'current RT-Thread image' >"$image"

python3 - "$metadata" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["virtio"]["vendor_id"] = "0x1af4"
path.write_text(json.dumps(data, indent=2) + "\n")
PY
if python3 "$META_TOOL" check \
    --image "$image" \
    --metadata "$metadata" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest >/dev/null 2>&1; then
    echo 'FAIL: incompatible virtio vendor ID passed metadata validation' >&2
    exit 1
fi

echo 'PASS: RT-Thread image metadata contract'
