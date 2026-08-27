#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 5 || $# -gt 6 ]]; then
    echo "usage: $0 ROOT TEMPLATE ZEPHYR_KERNEL METADATA RUNTIME_DIR [GUEST_CMDLINE]" >&2
    exit 2
fi

root="$1"
template="$2"
kernel="$3"
metadata="$4"
runtime_dir="$5"
root="$(realpath -e -- "$root")"
template="$(realpath -e -- "$template")"
kernel="$(realpath -e -- "$kernel")"
metadata="$(realpath -e -- "$metadata")"
runtime_dir="$(realpath -e -- "$runtime_dir")"
runtime_rel="${runtime_dir#"$root"/}"
if [[ ! "$runtime_rel" =~ ^tmp/zephyr-runtime\.[A-Za-z0-9]+$ ]]; then
    echo "unsafe Zephyr runtime directory: $runtime_rel" >&2
    exit 2
fi
if [[ "$(grep -c '^kernel_path[[:space:]]*=' "$template" || true)" -ne 1 ]]; then
    echo "template must contain exactly one kernel_path: $template" >&2
    exit 2
fi
guest_cmdline="${6:-}"
if printf '%s' "$guest_cmdline" | LC_ALL=C grep -q '[^[:print:]]' ||
   printf '%s' "$guest_cmdline" | grep -Fq '"' ||
   printf '%s' "$guest_cmdline" | grep -Fq '\\'; then
    echo "GUEST_CMDLINE must be printable TOML without quotes or backslashes" >&2
    exit 2
fi
ln -s -- "$kernel" "$runtime_dir/zephyr.bin"
python3 - "$template" "$runtime_dir/zephyr-task123.toml" "$metadata" "$guest_cmdline" <<'PYCODE'
import json
import re
import sys
import tomllib
from pathlib import Path

template, output, metadata_path, cmdline = sys.argv[1:]
metadata = json.loads(Path(metadata_path).read_text(encoding="utf-8"))
text = Path(template).read_text(encoding="utf-8")
lines = []
for line in text.splitlines(keepends=True):
    if re.match(r"^kernel_path\s*=", line):
        line = 'kernel_path = "zephyr.bin"\n'
    elif re.match(r"^entry_point\s*=", line):
        line = f'entry_point = 0x{metadata["entry_point"]:x}\n'
    elif re.match(r"^\s*cmdline\s*=", line):
        line = f'cmdline = "{cmdline}"\n'
    lines.append(line)
generated = "".join(lines)
parsed = tomllib.loads(generated)
if parsed["kernel"]["kernel_path"] != "zephyr.bin" or parsed["kernel"]["cmdline"] != cmdline:
    raise SystemExit("generated Zephyr VM config did not preserve kernel and cmdline")
kernel = parsed["kernel"]
regions = kernel["memory_regions"]
if not regions:
    raise SystemExit("generated Zephyr VM config has no guest memory region")

def contains(region, address):
    base, size = region[0], region[1]
    return base <= address and address < base + size

memory = regions[0]
kernel_size = Path(output).with_name(kernel["kernel_path"]).stat().st_size
kernel_start = kernel["kernel_load_addr"]
kernel_end = kernel_start + kernel_size
dtb_start = kernel["dtb_load_addr"]
dtb_end = dtb_start + 0x10000
entry = metadata["entry_point"]
for field, address in (
    ("kernel_load_addr", kernel_start),
    ("entry_point", entry),
    ("dtb_load_addr", dtb_start),
):
    if not any(contains(region, address) for region in regions):
        region = memory
        raise SystemExit(
            f"Zephyr {field} 0x{address:x} is outside guest RAM "
            f"[0x{region[0]:x}, 0x{region[0] + region[1]:x})"
        )
if kernel_end > memory[0] + memory[1]:
    raise SystemExit(
        f"Zephyr kernel image end 0x{kernel_end:x} is outside guest RAM "
        f"[0x{memory[0]:x}, 0x{memory[0] + memory[1]:x})"
    )
if dtb_end > memory[0] + memory[1] or max(kernel_start, dtb_start) < min(kernel_end, dtb_end):
    raise SystemExit(
        "Zephyr DTB must stay in RAM and must not overlap the kernel: "
        f"kernel=[0x{kernel_start:x}, 0x{kernel_end:x}), "
        f"dtb=[0x{dtb_start:x}, 0x{dtb_end:x})"
    )
Path(output).write_text(generated, encoding="utf-8")
print(output)
PYCODE
