#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/plot_rtos_realtime_iterations.py"
BEHAVIOR_TEST="$SCRIPT_DIR/test_plot_rtos_realtime_iterations.py"
rg -q --fixed-strings 'tail_ax.set_yscale("symlog"' "$SCRIPT" || {
  echo "[rtbench-plot] tail-latency axis must preserve high outliers" >&2
  exit 1
}
rg -q --fixed-strings 'max_limit = max(' "$SCRIPT" || {
  echo "[rtbench-plot] maximum-latency axis must preserve high outliers" >&2
  exit 1
}
rg -q --fixed-strings 'p99_99_ns' "$SCRIPT" || {
  echo "[rtbench-plot] plot must include p99.99 measurements" >&2
  exit 1
}
rg -q --fixed-strings 'one_linux_one_rtos' "$SCRIPT" || {
  echo "[rtbench-plot] plot must recognize the one-Linux one-RTOS layer" >&2
  exit 1
}
rg -q --fixed-strings 'MaxNLocator(integer=True, nbins=12)' "$SCRIPT" || {
  echo "[rtbench-plot] iteration axis must use a bounded integer tick locator" >&2
  exit 1
}
rg -q --fixed-strings 'max_ax.set_yscale("symlog"' "$SCRIPT" || {
  echo "[rtbench-plot] maximum-latency axis must keep low values visible beside outliers" >&2
  exit 1
}

python3 "$BEHAVIOR_TEST"
python3 "$SCRIPT_DIR/test_rtos_realtime_report.py"

echo "[rtbench-plot] source contract passed"
