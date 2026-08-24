# Task123 Test Logs

## ROCK 4D

The `rock4d/` directory contains the previous physical-board captures:

- `fixed-task123-rock4d-rtthread-linux.log`
- `fixed-task123-rock4d-rtthread-starryos.log`
- `fixed-task123-rock4d-zephyr-linux.log`
- `fixed-task123-rock4d-zephyr-starryos.log`

Those captures predate the unified 16-metric realtime suite. The current ROCK 4D
rerun is blocked before guest boot by U-Boot TFTP/PHY timeout (`phy_startup() failed:
-110`), so these files must not be treated as current PASS evidence.

## QEMU

The `qemu/` directory contains the current four-combination matrix from
`tmp/task123-qemu-ns-all-2`:

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

RTBench charts include only captures that satisfy the complete 16-metric nanosecond
contract. Incomplete ROCK 4D captures remain in the raw tables for diagnosis but are
excluded from heatmap cells instead of being rendered as fabricated zeros.

The complete parsed data is in `parsed-data.json` and the normalized tables are
`task2-metrics.csv`, `task3-metrics.csv`, `rtbench-metrics.csv`, and
`host-metrics.csv`.
