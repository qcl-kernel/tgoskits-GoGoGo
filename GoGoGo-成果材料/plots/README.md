# Task123 Test Logs

完整复现命令见 [`../docs/复现指南.md`](../docs/复现指南.md)。

## ROCK 4D

The `rock4d/` directory contains the final physical-board captures:

- `fixed-task123-rock4d-rtthread-linux.log`
- `fixed-task123-rock4d-rtthread-starryos.log`
- `fixed-task123-rock4d-zephyr-linux.log`
- `fixed-task123-rock4d-zephyr-starryos.log`
- `retry-<combo>-s*.log`：各组合的补充采集。物理串口偶发把单条 benchmark
  记录从字段中间截断（mux 输出交错），一份日志可能缺个别完整记录；解析器
  将主日志与 retry 日志合并、只收完整记录并按字段值去重。

Captures were normalized from the serial retries (2026-08-27 batch, rebased
`upstream/pr-new` baseline). The parser keeps only complete rows and
de-duplicates identical records. All four ROCK 4D combinations provide the same
16 nanosecond probes.

## QEMU

The `qemu/` directory contains the final four-combination QEMU matrix:

- `matrix/matrix-summary.json`
- `matrix/matrix-report.md`
- `matrix/comparison-manifest.txt`

The matrix manifest records `status=COMPLETE` and `stability_gate=PASS`.

## Comparisons

Run `python3 plot_task123.py` to regenerate the charts from the saved logs.
The generated files are SVGs under `plots/`:

- `task2-latency`: min/avg/max/P50/P95/P99/P99.9 RTT for 64B, 256B, and 1024B payloads.
- `task2-throughput`: throughput for all three payload sizes.
- `task3-inference` and `task3-roundtrip`: min/mean/P50/P95/P99/max latency.
- `task3-reliability`: success, classification, throughput, request, error, retry, and reconnect data.
- `task3-control`: fixed/AI tracking error and recovery counters.
- `rtbench-nanoseconds`: every recorded RTBench metric across mean/P95/P99/max ns.
- `rtbench-miss-counts`: missing, 100 us, 500 us, and 1 ms miss counts.
- `host-resources`: QEMU CPU time, RSS, and thread samples; Rock-4D host samples are `NA`.

RTBench charts include all eight QEMU/ROCK 4D combinations. Every combination has
16 complete nanosecond metrics with `expected=10`, `collected=10`, and `missing=0`.
No missing value is replaced with `16`, zero, or another synthetic default; a visible
`16` is a measured 16 ns value. PMU cycles/instructions are intentionally excluded
from the cross-platform completeness contract. ROCK 4D host-resource cells are `NA`
because there is no QEMU process sampler on the physical board, not because RTBench
data is missing.

The detailed conclusion is in
`../../docs/验证报告.md`.

The complete parsed data is in `parsed-data.json` and the normalized tables are
`task2-metrics.csv`, `task3-metrics.csv`, `rtbench-metrics.csv`, and
`host-metrics.csv`.
