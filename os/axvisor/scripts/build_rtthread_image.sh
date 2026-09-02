#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
PREPARE="$ROOT/os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
METADATA="$ROOT/os/axvisor/scripts/rtthread_image_metadata.py"

vm_config=
rock4d=0

usage() {
    echo "usage: $0 --vm-config CONFIG [--rock4d]" >&2
    return 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-config)
            [[ $# -ge 2 && -z "$vm_config" ]] || usage
            vm_config=$2
            shift 2
            ;;
        --rock4d)
            [[ "$rock4d" -eq 0 ]] || usage
            rock4d=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$vm_config" ]] || usage
vm_config="$(realpath -e -- "$vm_config")"

kernel_path="$(python3 - "$vm_config" <<'PY'
import pathlib
import sys
import tomllib

config_path = pathlib.Path(sys.argv[1])
config = tomllib.loads(config_path.read_text(encoding="utf-8"))
kernel = config.get("kernel", {})
if kernel.get("image_location") != "memory":
    raise SystemExit("RT-Thread VM config must use kernel.image_location=memory")
value = kernel.get("kernel_path")
if not isinstance(value, str) or pathlib.Path(value).name != "rtthread.bin":
    raise SystemExit("RT-Thread VM config must reference a kernel_path named rtthread.bin")
path = pathlib.Path(value)
if not path.is_absolute():
    path = config_path.parent / path
print(path)
PY
)"
kernel_path="$(realpath -m -- "$kernel_path")"
metadata_path="$kernel_path.meta.json"
mkdir -p -- "$(dirname -- "$kernel_path")"

source_tree="${RTTHREAD_UBOOT_SOURCE:-$ROOT/tmp/source-cache/task123-rtthread-uboot}"
input_digest="$(python3 "$METADATA" input-digest --root "$ROOT")"

echo "RTTHREAD_UBOOT_PREPARE vm_config=$vm_config image=$kernel_path rock4d=$rock4d"
bash "$PREPARE" "$source_tree"
if [[ "$rock4d" -eq 1 ]]; then
    TGOSKITS_ROCK4D_BOARD_PORT=1 bash "$APPLY" "$source_tree"
else
    bash "$APPLY" "$source_tree"
fi

if [[ -s "$kernel_path" && -s "$metadata_path" ]] &&
    python3 "$METADATA" check \
        --image "$kernel_path" \
        --metadata "$metadata_path" \
        --source "$source_tree" \
        --input-digest "$input_digest" >/dev/null; then
    echo "RTTHREAD_UBOOT_IMAGE_REUSED $kernel_path"
    exit 0
fi

command -v uv >/dev/null || {
    echo "RT-Thread U-Boot build requires uv" >&2
    exit 1
}
bsp="$source_tree/bsp/qemu-virt64-aarch64"
jobs="${RTTHREAD_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
uv run --with scons scons -C "$bsp" -c
uv run --with scons scons -C "$bsp" -j"$jobs"

temporary_image="$kernel_path.tmp.$$"
temporary_metadata="$metadata_path.tmp.$$"
cleanup() {
    rm -f -- "$temporary_image" "$temporary_metadata"
}
trap cleanup EXIT
cp -- "$bsp/rtthread.bin" "$temporary_image"
python3 "$METADATA" write \
    --image "$temporary_image" \
    --source "$source_tree" \
    --input-digest "$input_digest" \
    --output "$temporary_metadata"
mv -- "$temporary_image" "$kernel_path"
mv -- "$temporary_metadata" "$metadata_path"
trap - EXIT
echo "RTTHREAD_UBOOT_IMAGE_BUILT $kernel_path"
