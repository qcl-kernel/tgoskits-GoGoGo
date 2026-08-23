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
input_digest_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
input_digest_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

digest_root="$TMP_ROOT/digest-root"
for relative in \
    os/axvisor/patches/rtthread \
    os/axvisor/guests/rt-ipc/common \
    os/axvisor/guests/rt-ipc/rtthread \
    os/axvisor/guests/task3/src/common \
    os/axvisor/guests/task3/src/rtthread \
    os/axvisor/guests/rt-benchmark/rtthread; do
    mkdir -p -- "$digest_root/$relative"
    printf 'fixture for %s\n' "$relative" > "$digest_root/$relative/input.c"
done
computed_before="$(python3 "$META_TOOL" input-digest --root "$digest_root")"
printf '%s\n' 'changed Task 3 server input' \
    >> "$digest_root/os/axvisor/guests/task3/src/common/input.c"
computed_after="$(python3 "$META_TOOL" input-digest --root "$digest_root")"
[[ "$computed_before" =~ ^[0-9a-f]{64}$ && "$computed_after" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'FAIL: computed RT-Thread build input digest is not SHA-256' >&2
    exit 1
}
[[ "$computed_before" != "$computed_after" ]] || {
    echo 'FAIL: Task 3 source change did not invalidate RT-Thread build inputs' >&2
    exit 1
}

python3 "$META_TOOL" write \
    --image "$image" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest \
    --input-digest "$input_digest_a" \
    --output "$metadata"
python3 "$META_TOOL" check \
    --image "$image" \
    --metadata "$metadata" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest \
    --input-digest "$input_digest_a"

if python3 "$META_TOOL" check \
    --image "$image" \
    --metadata "$metadata" \
    --source "$source_dir" \
    --patch-digest patch-set-test-digest \
    --input-digest "$input_digest_b" >/dev/null 2>&1; then
    echo 'FAIL: changed RT-Thread build inputs passed metadata validation' >&2
    exit 1
fi

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
