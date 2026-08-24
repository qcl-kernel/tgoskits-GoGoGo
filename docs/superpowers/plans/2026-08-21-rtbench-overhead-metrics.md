# RTBench Overhead Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add seven RT-Thread real-time overhead metrics to the existing RTBench suite, preserving current metrics and producing ns/cycles/instructions evidence under real QEMU.

**Architecture:** Keep the guest benchmark in the existing `rt_benchmark.c` installation path. Reuse `rtbench_sample`, `rtbench_result`, PMU snapshots, and the stable `RTBENCH metric=...` schema. Add isolated measurement contexts with explicit teardown, then extend the shell verifier, Python summarizer, fixtures, and report.

**Tech Stack:** RT-Thread C APIs, AArch64 PMUv3/CNTVCT, Bash result gates, Python log summarizer, real QEMU AArch64 TCG.

---

### Task 1: Extend result contracts first

**Files:** `os/axvisor/scripts/test_rtbench_suite_gate.sh`, `os/axvisor/scripts/verify_rtbench_suite.sh`

- [ ] Add `context_switch`, `scheduler_decision`, `sync_sem`, `sync_mutex`, `sync_mailbox`, `irq_handler_exec`, and `deadline_miss_under_load` records to the complete synthetic suite fixture using the existing full `metric_suffix`.
- [ ] Add the seven names to the verifier's required guest-local metric loop; keep `net_event_latency` conditional on `full` mode.
- [ ] Add a negative fixture that removes `context_switch` and assert the gate fails naming that metric.
- [ ] Run `os/axvisor/scripts/test_rtbench_suite_gate.sh`. It must fail at this stage because the guest source does not emit the new metrics; this is the required RED test.

### Task 2: Add reusable measurement helpers, context switching, and scheduler decision

**Files:** `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`, `os/axvisor/scripts/test_rtbench_suite_gate.sh`

- [ ] Add a bounded local-microbenchmark helper that allocates samples, executes a measurement loop, calls `rtbench_summarize`, prints the supplied metric name, frees samples, and returns an error unless `collected == expected`.
- [ ] Implement `context_switch` with two same-priority threads alternating through `rt_thread_yield()`. Use a shared stop flag, per-thread completion semaphores, and teardown that wakes and waits for both workers.
- [ ] Implement `scheduler_decision` by measuring `rt_schedule()` while the current thread remains the highest-priority runnable thread. This is the no-switch scheduler path.
- [ ] Add source-contract checks for the new functions, `rt_thread_yield`, `rt_schedule`, worker completion, and cleanup.
- [ ] Rebuild the RT-Thread image with `os/axvisor/patches/rtthread/apply-rtthread-patches.sh tmp/source-cache/rt-thread/ddf52e2cdd977f14fc04035c88672ac204aec713/source` and `uv run --with scons scons -C tmp/source-cache/rt-thread/ddf52e2cdd977f14fc04035c88672ac204aec713/source/bsp/qemu-virt64-aarch64 -j"$(getconf _NPROCESSORS_ONLN)"`; run the focused suite gate.

### Task 3: Add synchronization and IRQ handler metrics

**Files:** `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`, `os/axvisor/scripts/test_rtbench_suite_gate.sh`

- [ ] Implement `sync_sem` as uncontended `rt_sem_take` plus `rt_sem_release`, requiring both operations to return `RT_EOK` before storing a sample.
- [ ] Implement `sync_mutex` as uncontended `rt_mutex_take` plus `rt_mutex_release`, detaching the mutex only after summarization.
- [ ] Implement `sync_mailbox` with a one-slot mailbox and fixed `rt_ubase_t` value; require send, receive, and value verification for every sample.
- [ ] Implement `irq_handler_exec` by reusing the SGI installation path and measuring from the first handler snapshot to the final handler snapshot before completion release. Restore the original ISR descriptor and interrupt-enable state.
- [ ] Extend source contracts for semaphore/mutex/mailbox cleanup, ISR restoration, and all new metric names; run the focused suite gate and compile checks.

### Task 4: Add deadline miss under load and integrate the suite

**Files:** `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`, `os/axvisor/scripts/verify_rtbench_suite.sh`, `os/axvisor/scripts/test_rtbench_suite_gate.sh`, `os/axvisor/scripts/summarize_rtthread_realtime.py`

- [ ] Create exactly four bounded CPU-load workers with a shared stop flag and completion synchronization; ensure every worker is stopped and joined or deleted before return.
- [ ] Implement `deadline_miss_under_load` using the existing 1 ms hard timer while the four load workers run. Store period deviation samples and preserve `miss_100us`, `miss_500us`, and `miss_1ms` as observational counts.
- [ ] Invoke all seven new guest-local metrics from `rtbench_run_suite_metrics`; `benchmark_core` includes them and only full `benchmark` includes `net_event_latency`.
- [ ] Add the names to the Python summarizer metric catalog and preserve all ns/cycles/instructions fields in JSON, CSV, Markdown, and A/B/C comparison outputs.
- [ ] Run `test_rtbench_suite_gate.sh`, `test_rtbench_linux_probe_contract.sh`, `test_rtthread_realtime_summarizer.sh`, and `test_task123_result_gate.sh`.

### Task 5: Build, run real QEMU, and update reports

**Files:** `comp-docs/task123/report/2026-08-21/tgoskits/c-scenario-fix-regression-report.md`, `comp-docs/task123/report/2026-08-21/tgoskits/rt-thread-realtime-extended-20260821-report.md`

- [ ] Reapply the RT-Thread patch set and build the single cached RT-Thread image with the existing `uv`/SCons command.
- [ ] Run real QEMU `run_task123.sh --mode realtime-suite --rtbench-samples 10 --task2-count 10`; confirm every new metric has `expected == collected`, `missing=0`, all three counter units, and `RTBENCH_END status=PASS`.
- [ ] Run the A/B/C comparison with `--suite-samples 1000 --stability-seconds 30`, retaining native, AxVisor-only, and AxVisor+Linux evidence.
- [ ] Update the reports with raw ns/cycles/instructions values, `miss_1ms`, sample counts, and the limitation that TCG PMU values are virtual and do not prove physical WCET.
- [ ] Run `git diff --check`, all RTBench/result-gate tests, and record the real QEMU output directory.
