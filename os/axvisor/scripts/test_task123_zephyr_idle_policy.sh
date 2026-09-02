#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/zephyr-task123.toml"

python3 - "$CONFIG" <<'PY'
import sys
import tomllib
from pathlib import Path

with Path(sys.argv[1]).open("rb") as config_file:
    config = tomllib.load(config_file)

policy = config["base"].get("host_vcpu_idle_policy")
if policy != "halt":
    raise SystemExit(
        "FAIL: Zephyr Task123 must halt the host vCPU on guest WFI under TCG; "
        f"got {policy!r}"
    )
print("PASS: Zephyr Task123 uses halt-on-WFI host idle policy")
PY
