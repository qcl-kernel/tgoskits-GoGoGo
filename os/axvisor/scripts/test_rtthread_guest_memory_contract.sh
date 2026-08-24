#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml"

python3 - "$CONFIG" <<'PY'
import sys
import tomllib
from pathlib import Path

config = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
kernel = config["kernel"]

if kernel.get("load_policy") != "keep_configured":
    raise SystemExit("FAIL: RT-Thread must preserve its configured image address")
if kernel.get("entry_point") != 0x4020_0000:
    raise SystemExit("FAIL: RT-Thread entry point must match its linked image")
if kernel.get("kernel_load_addr") != 0x4020_0000:
    raise SystemExit("FAIL: RT-Thread image must load at its linked address")
if kernel.get("memory_regions") != [[0x4000_0000, 0x4000_0000, 0x7, 0]]:
    raise SystemExit(
        "FAIL: RT-Thread RAM must use MapAlloc so GPA 0x40200000 does not alias AxVisor"
    )
PY

echo "PASS: RT-Thread guest memory is GPA-preserving and host-backed"
