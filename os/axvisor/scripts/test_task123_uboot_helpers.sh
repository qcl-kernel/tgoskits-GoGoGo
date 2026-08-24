#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

input="$tmp/input.toml"
output="$tmp/output.toml"
cat > "$input" <<'TOML'
serial = "/dev/ttyUSB0"
success_regex = [
  "TASK2_STARRY_END status=PASS",
  "TASK3_STARRY_END status=PASS",
  "TASK123_STARRY_END status=PASS",
  "TASK123_STARRY_EXIT status=0",
  "TASK123_LINUX_END status=PASS",
]
fail_regex = ["TASK123_STARRY_END status=FAIL"]
TOML

python3 "$ROOT/os/axvisor/scripts/prepare_task123_uboot_config.py" \
    "$input" "$output" >/dev/null
grep -Fxq \
    "success_regex = ['(?s:(?:(?:RTBENCH_STABILITY_END) status=PASS.*TASK123_STARRY_END status=PASS|TASK123_STARRY_END status=PASS.*(?:RTBENCH_STABILITY_END) status=PASS))']" \
    "$output"
grep -Fxq 'fail_regex = ["TASK123_STARRY_END status=FAIL"]' "$output"
grep -Fq 'TASK2_STARRY_END status=PASS' "$input"

zephyr_output="$tmp/zephyr.toml"
python3 "$ROOT/os/axvisor/scripts/prepare_task123_uboot_config.py" \
    --rtos zephyr --app-guest linux --rtbench-samples 10 "$input" "$zephyr_output" >/dev/null
grep -Fxq \
    "success_regex = ['(?s:(?:(?:RTBENCH_END|RTBENCH_STABILITY_END) status=PASS.*TASK123_LINUX_RTBENCH_END status=PASS|TASK123_LINUX_RTBENCH_END status=PASS.*(?:RTBENCH_END|RTBENCH_STABILITY_END) status=PASS))']" \
    "$zephyr_output"
grep -Fxq 'shell_prefix = "uart:~$ "' "$zephyr_output"
grep -Fxq 'shell_init_cmd = "benchmark 10"' "$zephyr_output"

echo "PASS: Task123 U-Boot helpers"
