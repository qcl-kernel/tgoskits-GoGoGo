# QEMU RTOS/App-Guest Matrix Plan B Test Report

Date: 2026-08-22

Branch/worktree: codex/qemu-rtos-matrix-plan-b in
.worktrees/axvisor-rtos-matrix-plan-b.

## 1. Scope and result

This run adds a selectable RTOS dimension to the existing Task 1/2/3 QEMU flow:

- RTOS: RT-Thread or Zephyr
- App guest: Linux or StarryOS
- Guest communication: IP over virtio-net

The four real-QEMU functional combinations all completed the Task 2/Task 3
application gates:

| RTOS | App guest | Task 2/3 gates | RTOS errors | Control steps | Retry behavior |
|---|---|---|---:|---:|---|
| RT-Thread | Linux | PASS | 0 | 3/3 | no retry/duplicate |
| RT-Thread | StarryOS | PASS | 0 | 3/3 | no retry/duplicate |
| Zephyr | Linux | PASS | 0 | 3/3 | retries 44, duplicates 3 |
| Zephyr | StarryOS | PASS | 0 | 3/3 | retries 55, duplicates 4 |

These are functionally complete results, but not native-hardware realtime
certification. All time-based values were collected under QEMU TCG and must be
read as emulator-relative evidence.

## 2. Versions and topology

| Component | Version/pin |
|---|---|
| QEMU | 11.0.2, qemu-system-aarch64 SHA-256 5b36544f...1afa9 |
| AxVisor host | worktree build recorded in each run manifest |
| Linux | Alpine Linux kernel 6.12.21, Alpine 3.23.0 rootfs artifacts |
| StarryOS | worktree starryos-task123.bin recorded in each run manifest |
| RT-Thread | commit ddf52e2cdd977f14fc04035c88672ac204aec713 |
| Zephyr | stable tag v4.4.2, peeled commit dccb09599635bdff17633fa7e9dab014b91dce90, board qemu_cortex_a53 |

The QEMU topology is one AxVisor instance per selected pair, never four guests
inside one emulator:

- QEMU machine: virt,virtualization=on,gic-version=3
- Physical CPUs: 4
- App guest: 2 vCPUs; each may run on pCPU 0, 1, or 3
- RTOS guest: 1 vCPU, fixed to pCPU 2
- Linux/StarryOS memory: 512 MiB at 0x8000_0000
- RT-Thread memory: 1 GiB at 0x4000_0000
- Zephyr memory: 128 MiB at 0x4000_0000

For realtime-suite and stability modes, QEMU uses TCG single-thread mode plus
-icount shift=3. Functional smoke runs use multi-thread TCG without forcing
icount.

## 3. Network and protocol

The main channel is virtio-net in a QEMU internal hub, not shared memory,
HyperCall, vsock, or raw MMIO:

| Guest | MAC | IPv4 |
|---|---|---|
| Linux/StarryOS | 52:54:00:77:00:01 | 192.168.77.11/24 |
| RT-Thread/Zephyr | 52:54:00:77:00:03 | 192.168.77.30/24 |

Task 2 uses RT-IPC over UDP port 9876. Task 3 uses the AI control protocol
over UDP port 9877. The RT-IPC v2 header contains protocol version, message
type, payload length, sequence number, session ID, error code, and CRC16.
It implements ACK, timeout, retransmission, duplicate/sequence tracking,
session reset, heartbeat, FIN, and reconnect actions.

Linux/StarryOS and both RTOS ports use the same protocol and Task 3 controller
state-machine code. Platform-specific RT-Thread and Zephyr layers provide UDP
sockets, timers, clocks, and console output.

## 4. Four-combination functional evidence

Application summary:

| Combination | Requests | Successes | App errors | Mean RTT | Max RTT | AI accuracy |
|---|---:|---:|---:|---:|---:|---:|
| RT-Thread + Linux | 6 | 6 | 0 | 3.54 ms | 8.99 ms | 100% |
| RT-Thread + StarryOS | 6 | 6 | 0 | 6.16 ms | 7.36 ms | 100% |
| Zephyr + Linux | 6 | 6 | 0 | 1.94 s | 6.31 s | 100% |
| Zephyr + StarryOS | 6 | 6 | 0 | 2.18 s | 6.33 s | 100% |

The Zephyr links eventually reached 100% application success but showed
substantial transport-layer timeout/retry activity in this short functional
run. The success gates prove protocol recovery and idempotency work; they do
not establish that Zephyr's current UDP path has low latency.

Raw evidence:

    tmp/planb-final-smoke/rtthread-linux-final2/
    tmp/planb-final-smoke/rtthread-starry-final2/
    tmp/planb-final-smoke/zephyr-linux-final2/
    tmp/planb-final-smoke/zephyr-starry-final2/

Each directory contains console.log, the app-guest log, RTOS log, Task 3
frames.csv, summary.json, QEMU resource samples, and image metadata.

## 4.1 Default quick-stability throughput check

The default `./run-task123.sh --quick` path selects RT-Thread + Linux with a
300-second stability window and 30000 requests for each of the three Task 2
payload sizes.

The first final default attempt was stopped by the runner's 900-second stage
guard after completing about 22380/30000 64-byte requests. Its host metrics
recorded 900.171 s wall time and 904.110 s QEMU CPU time. There were zero
application/protocol errors in the collected output; this was a throughput
timeout under single-thread TCG, not a network or RT-IPC functional failure.

A controlled real-QEMU comparison isolated the dominant cause:

| Run | QEMU mode | Outcome | Wall time | QEMU CPU time | Application gates |
|---|---|---|---:|---:|---|
| Default stability path | single-thread TCG + icount shift=3 | 64B stopped by 900 s guard at ~22380/30000 | 900.171 s | 904.110 s | incomplete by timeout |
| Same code/image/payload in smoke mode | multi-thread TCG, no icount | 30000/30000 for 64B, 256B, and 1024B | 237.071 s | 465.180 s | Task 2 PASS, Task 3 PASS, Task 123 PASS |

The multi-thread run used the same Plan B worktree and the current RT-Thread
image (SHA-256 beginning `06ecaae9`) built with the complete patch set. It
recorded seven QEMU threads, matching the older successful evidence. This
demonstrates that forced single-thread TCG plus icount is the primary reason
the current default stability workload cannot finish within the old guard.

This comparison intentionally does not mix performance claims: multi-thread
TCG is a functional/throughput check, while realtime stability data is still
collected in the configured single-thread/icount environment and remains
emulator-relative.

### Completed default stability measurement

To separate throughput workload size from the realtime stability measurement,
the default RT-Thread + Linux stability topology was rerun with the same 300 s
guest window but 1000 Task 2 requests per payload. The first attempt still hit
the old 900 s host guard while the RTOS sampling loop was active, proving that
the guard calculation—not the benchmark—was still too short. With an explicit
1800 s host budget the run completed:

| Item | Result |
|---|---:|
| Guest samples | 299999 / 299999, missing 0 |
| QEMU wall time | 1740.535 s |
| QEMU CPU time | 1747.620 s |
| QEMU threads | 4 (single-thread TCG form) |
| Task 2/Task 3 functional gates | PASS / PASS |
| RTOS Task 3 accounting | 9 requests, 0 errors, 0 duplicates, 3 control steps |

Stability-jitter time, cycle, and instruction data from that run:

| Metric | P50 | P95 | P99 | P99.9 | Max | Mean |
|---|---:|---:|---:|---:|---:|---:|
| Jitter ns | 1,872,192 | 6,160,880 | 7,388,880 | 8,930,096 | 15,901,408 | 2,316,817 |
| Jitter cycles | 56,624 | 311,472 | 571,880 | 698,544 | 2,240,008 | 122,975 |
| Jitter instructions | 7,078 | 38,934 | 71,485 | 87,318 | 280,001 | 15,371 |

Callback execution:

| Metric | P50 | P95 | P99 | P99.9 | Max | Mean |
|---|---:|---:|---:|---:|---:|---:|
| Execution ns | 1,088 | 1,088 | 2,944 | 14,368 | 3,799,984 | 1,297 |
| Execution cycles | 1,080 | 1,080 | 2,944 | 14,360 | 1,046,280 | 1,203 |
| Execution instructions | 135 | 135 | 367 | 1,795 | 130,785 | 150 |

There were 214693 jitter samples over 1 ms, so the stability gate correctly
reported FAIL even though all samples were collected. This is a measured
deadline-miss failure under single-thread TCG + icount, not an incomplete run
or protocol failure. The PMU counters are now nonzero for RT-Thread, but they
are virtual/emulator-relative counters; they remove neither TCG scheduling
delay nor icount virtual-time effects.

Artifacts:

    tmp/planb-default-adjusted-stability-timeout1800/console.log
    tmp/planb-default-adjusted-stability-timeout1800/host-metrics.txt

The runner's default stability host budget now scales conservatively for this
forced single-thread/icount mode. A complete guest run is allowed to outlive
its virtual duration; benchmark PASS/FAIL remains solely determined by the
guest-side deadline statistics.

## 5. Realtime results and limitations

### RT-Thread

The 2026-08-21 RT-Thread extended report remains the authoritative RT-Thread
realtime baseline. Its 300-second A/B/C stability run collected 299999/299999
samples in every scenario and had no missing sample or 1 ms stability miss.
The integrated Linux scenario had 1 ms timer-jitter P99 of about 422 us and
maximum about 827 us.

The same suite also showed non-timer long tails in the integrated scenario:
mutex_inversion maximum around 1.04 ms and net_event_latency maximum around
1.79 ms. Therefore the existing result is good for this TCG run but is not a
hard-realtime/WCET pass.

Reference report:

    comp-docs/task123/report/2026-08-21/tgoskits/rt-thread-realtime-extended-20260821-report.md

### Zephyr

After fixing the Zephyr stability estimator, a real-QEMU 1-second regression
run collected 999/999 timer samples:

| Metric | P50 | P95 | P99 | P99.9 | Max |
|---|---:|---:|---:|---:|---:|
| 1 ms timer jitter | 1.09 ms | 5.31 ms | 7.40 ms | 8.61 ms | 9.61 ms |
| Callback execution | 144 ns | 144 ns | 144 ns | 6.48 us | 6.48 us |

The older Zephyr jitter output was invalid because QEMU single-thread TCG can
pause the guest and then deliver multiple queued timer callbacks in a burst.
The old median-interval phase estimator interpreted those burst intervals as
the period. The fixed estimator uses the known 1 ms period and a linear fit
through the central sample window, while retaining late/catch-up delivery as
measured delay.

RTBENCH_STABILITY_END status=FAIL is expected for this 1 ms-deadline test
because 539 of 999 samples exceeded 1 ms in the collected TCG run. It is not a
crash or missing-sample failure.

Virtual PMU event 0x08 was unavailable in this QEMU virtualization setup.
The printed zero cycle/instruction counts are not valid workload values and
are reported as unavailable. They must not be interpreted as a zero-cycle path.

### Environment-wide caveat

The x86_64 host, QEMU TCG main loop, virtual timer/VGIC, virtio-net/NVMe
emulation, icount, and host thread scheduling can dominate time-based tails.
CPU affinity inside AxVisor cannot remove those emulator/host effects. These
numbers are useful for functional validation and relative diagnosis; hardware
or KVM measurements are required for deployment realtime claims.

## 6. Reproduction

From this worktree:

    # Default existing path: RT-Thread, Linux then StarryOS, quick stability mode
    ./run-task123.sh --quick

    # One selected pair
    ./run-task123.sh --rtos zephyr --app-guest linux --quick
    ./run-task123.sh --rtos zephyr --app-guest starryos --quick
    ./run-task123.sh --rtos rtthread --app-guest linux --quick
    ./run-task123.sh --rtos rtthread --app-guest starryos --quick

    # Four independent QEMU runs in sequence
    ./run-task123.sh --matrix all --quick

The first Zephyr build downloads and caches the pinned west workspace under
tmp/source-cache/zephyr/&lt;commit&gt;/workspace; subsequent builds reuse it. The
published image and metadata live under the same commit's current-image/.
External Git/CMake/Ninja progress is shown directly in the terminal.

Zephyr source pinning and cache behavior are covered by:

    os/axvisor/scripts/test_zephyr_build_contract.sh

## 7. Contract validation

The following contract checks passed:

    PASS: Zephyr pinned source and real-interrupt build contract
    test_axvisor_contract: PASS
    PASS: direct task123 entrypoint selects RTOS inputs and validates RT-Thread image
    PASS: StarryOS/Linux guest comparison orchestrator contract
    PASS: RTOS/app-guest matrix orchestrator contract

The lifecycle contract is run only with its generated fake QEMU executable.
It validates process ownership and cleanup; it is never used for performance
claims. Real performance and functional evidence comes only from
qemu-system-aarch64.

## 7.1 Post-report matrix rerun and log-normalization fix

After the original functional evidence was collected, an additional
`./run-task123.sh --matrix all --quick` rerun exposed two operational issues:

- The first StarryOS image rebuild in that rerun stopped after RT-IPC server
  startup; StarryOS did not enter Task 2. This was specific to the rerun's
  newly rebuilt StarryOS artifact and did not reproduce with the previously
  validated image.
- With the validated StarryOS image, both RT-Thread combinations completed
  Task 2/Task 3 and collected all 999/999 stability samples, but the run
  record was rejected during publishing because VM[1]'s PSCI shutdown record
  was interleaved into the middle of the RT-Thread
  `RTBENCH_STABILITY_BEGIN` line.

The second issue was a result-gate bug, not a guest benchmark failure. The
normalized log now removes the ANSI/kernel text that crossed the begin record
and restores the begin line before matching it. Replay against the rejected
console:

    PASS: RT benchmark stability completed (1s, 999 samples)

The fix is covered by `test_rtbench_stability_gate.sh`; its synthetic fixture
injects ANSI kernel output into the stability-begin record and requires the
gate to accept the normalized result.

Evidence:

    tmp/planb-matrix-final-r2/rtthread-linux/manifest.txt
    tmp/planb-matrix-final-r2/rtthread-starryos/console.log

The RT-Thread + StarryOS console in that rerun contains complete Task 2/Task 3
PASS markers, `TASK3_RTOS_FINAL requests=9 errors=0 duplicates=0`, 999/999
stability samples, and the previously rejected interleaved begin marker. The
Linux combination published normally. Zephyr combinations were not rerun in
this late pass; their authoritative functional evidence remains the four-run
real-QEMU matrix in section 4.

## 7.2 2026-08-23 result-gate replay and partial matrix rerun

The result gate was hardened again after a late matrix rerun exposed a
controlled-termination accounting bug. With `--allow-qemu-timer-limit`, the
marker watcher intentionally stops QEMU after `RTBENCH_STABILITY_DONE`; the
stability sub-verifier previously rejected the corresponding nonzero QEMU
exit before result parsing. The gate now accepts that controlled exit only
for `stability + allow-qemu-timer-limit`, passes exit 0 to its sub-verifiers,
and continues to reject nonzero exits in smoke, task3, realtime-suite, and
without explicit opt-in. Zephyr's `RTBENCH_PMU status=unavailable` is now
treated consistently as unavailable diagnostic data, not as a functional
failure; zero cycle/instruction counters remain non-results.

Contract coverage:

    PASS: Task 1/2/3 result gate rejects malformed evidence

Real-QEMU replay/rerun evidence:

| Combination | Outcome | Task 2/3 data | Stability samples | Notes |
|---|---|---|---:|---|
| RT-Thread + Linux | PASS_WITH_QEMU_TIMER_LIMIT | 6/6 successes, 0 app errors, 7 retries | 999/999 | manifest published |
| RT-Thread + StarryOS | PASS_WITH_QEMU_TIMER_LIMIT after verifier replay | 6/6 successes, 0 app errors, 25 retries | 999/999 | original run wrote all evidence; manifest publication was interrupted by the shell session |
| Zephyr + Linux | verifier PASS on complete real-QEMU log | 6/6 successes, 0 app errors, 90 retries, 3 duplicates | 999/999 | PMU cycle/instruction unavailable |
| Zephyr + StarryOS | not rerun in this pass | section 4 evidence remains authoritative | 999/999 in prior functional run | current rebuilt StarryOS branch stalled during startup |

A direct rerun attempt with the then-current StarryOS build stalled before
Task 2 and was terminated; no performance claim is made from that partial
log. This is consistent with the rebuilt-StarryOS instability noted above and
remains a pending reproducibility issue rather than an RT-IPC failure.

Representative 1-second jitter percentiles from the rerun (emulator-relative):

| Combination | P50 | P95 | P99 | P99.9 | Max |
|---|---:|---:|---:|---:|---:|
| RT-Thread + Linux | 1.99 ms | 6.37 ms | 7.48 ms | 10.26 ms | 10.26 ms |
| RT-Thread + StarryOS | 1.38 ms | 7.12 ms | 8.98 ms | 13.58 ms | 13.58 ms |
| Zephyr + Linux | 2.81 ms | 6.89 ms | 7.73 ms | 8.15 ms | 8.27 ms |

Artifacts:

    tmp/planb-fixed-matrix-resume/rtthread-linux/
    tmp/planb-fixed-matrix-resume/rtthread-starryos/
    tmp/planb-fixed-matrix-resume/rtthread-starryos-gate-replay/
    tmp/planb-fixed-matrix-resume/zephyr-linux/

## 8. Current status

Completed:

- selectable RT-Thread/Zephyr dimension;
- four real-QEMU functional combinations;
- shared RT-IPC and Task 3 protocol/controller code;
- pinned Zephyr source and persistent cache;
- Zephyr virtio-net static IP setup;
- corrected Zephyr timer-jitter estimator;
- throughput isolation for the default quick-stability timeout;
- matrix and entrypoint contract tests;
- this report.

Pending:

- a full ./run-task123.sh --matrix all --quick run if all four combinations
  must also be executed through the one-command matrix entrypoint rather than
  the equivalent individual real-QEMU commands.
- a decision on whether the default quick path should reduce its Task 2 request
  count under single-thread TCG or increase its stage timeout. Reducing the
  workload preserves the current timing configuration; increasing the timeout
  preserves the current request count but can make each quick run slower.
