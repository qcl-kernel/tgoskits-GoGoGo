# RT-Thread Extended Real-Time Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add the missing RTOS latency metrics, validate them across native/AxVisor-only/AxVisor-plus-Linux baselines, and produce a comparable real-time assessment.

**Architecture:** Extend the existing canonical RT-Thread guest benchmark with deterministic synthetic workloads for IRQ-to-thread wake, interrupt-disabled sections, mutex priority inheritance, and wake-under-load. Keep the stable RTBENCH key=value output schema so host gates and reports can validate every metric. Run the same guest image/command in A/B/C scenarios and summarize virtualization and coexistence degradation.

**Tech Stack:** C on RT-Thread AArch64, cntvct_el0, RT-Thread IPC/timer APIs, Bash verifier/gates, existing QEMU/AxVisor runners.

---

## Scope and metric definitions

Metrics already present and retained:

- timer_jitter (3 suite runs)
- callback_exec (3 suite runs)
- preemption
- irq
- stability_jitter (long stability run)

New suite metrics:

- irq_to_task: timestamp immediately before pending SGI to the first high-priority task instruction after the ISR releases a semaphore.
- irq_disabled_duration: duration of a controlled interrupt-disabled workload with a fixed synthetic spin count.
- mutex_inversion: high-priority mutex acquisition latency while a low-priority owner runs and a medium-priority CPU load thread competes.
- wake_under_load: semaphore release-to-high-priority-thread wake latency while multiple load threads run.

The first implementation intentionally measures controlled synthetic paths. It does not instrument every kernel interrupt-disabled region and is not a global WCET proof. Network-event instrumentation is retained as a later trace-level task because the active RT-IPC path does not currently expose a safe benchmark-only IRQ-to-application hook.

- Quick suite: 1000 samples/metric (existing default).
- Evaluation suite: 100000 samples/metric, the current guest limit.
- Long stability: stability_jitter 300 seconds.
- Baselines:
  - A: native RT-Thread on QEMU.
  - B: AxVisor with RT-Thread VM only.
  - C: AxVisor with 2-vCPU Linux and RT-Thread while Task 2/3 traffic is active.
- Every metric outputs expected/collected/missing, P50/P95/P99/P99.9/max/mean and miss_100us/500us/1ms counters.

## Files

- Modify: os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c
- Modify: os/axvisor/scripts/verify_rtbench_suite.sh
- Modify: os/axvisor/scripts/test_rtbench_suite_gate.sh
- Modify: os/axvisor/scripts/run_rtthread_native_baseline.sh
- Modify: os/axvisor/scripts/run_task123.sh
- Create: os/axvisor/scripts/run_rtthread_realtime_baseline.sh
- Create: os/axvisor/scripts/summarize_rtthread_realtime.py
- Create: os/axvisor/scripts/test_rtthread_realtime_baseline.sh
- Create: os/axvisor/scripts/test_rtthread_realtime_summarizer.sh
- Docs/evidence destination after runs: /home/yfblock/Code/hyper-rtos/history-docs/task123/

## Task 1: suite gate accepts the extended metric contract

- [x] Add new complete-log lines to test_rtbench_suite_gate.sh for irq_to_task, irq_disabled_duration, mutex_inversion, and wake_under_load.
- [x] Run os/axvisor/scripts/test_rtbench_suite_gate.sh.
- [x] Verify it fails because verify_rtbench_suite.sh does not require those metrics.
- [x] Modify verify_rtbench_suite.sh so exactly one complete line is required for each new metric.
- [x] Run the gate test again and verify PASS.
- [x] Run bash -n on both scripts.

## Task 2: irq_to_task benchmark

- [x] Add a shared SGI benchmark context that records trigger_ticks and handler arrival.
- [x] Add a high-priority irq_to_task worker waiting on a semaphore.
- [x] In the SGI ISR, release the semaphore after recording arrival.
- [x] In the worker first instruction after rt_sem_take, compute cntvct delta from trigger_ticks.
- [x] Collect the requested sample count and reuse rtbench_summarize/print_result.
- [x] Emit RTBENCH metric=irq_to_task run=1 ...
- [x] Build with the RT-Thread toolchain and run a short guest suite in the existing native path.
- [x] Verify missing=0 and no benchmark error.

## Task 3: irq_disabled_duration benchmark

- [x] Add a synthetic critical-section loop with a deterministic iteration count.
- [x] For each sample: read cntvct, disable local IRQs, execute the loop, re-enable, read cntvct, and store elapsed duration.
- [x] Use a bounded iteration count calibrated in source (64 iterations) so the measurement remains below the suite timeout.
- [x] Reuse summarize/print and emit metric=irq_disabled_duration.
- [x] Run a short native suite and verify missing=0.

## Task 4: mutex_inversion benchmark

- [x] Create low, medium-load, and high threads with priorities 20, 12, and 5.
- [x] Low thread owns a static rt_mutex.
- [x] High thread records cntvct before rt_mutex_take, blocks on the mutex, and records elapsed after acquisition.
- [x] While high waits, medium load performs deterministic arithmetic so priority inheritance must boost low to prevent unbounded inversion.
- [x] Low releases the mutex after a bounded spin/delay window.
- [x] Reuse summarize/print and emit metric=mutex_inversion.
- [x] Run a short native suite and verify missing=0.

## Task 5: wake_under_load benchmark

- [x] Create four load threads at lower priority than the measured high thread.
- [x] Each load thread performs deterministic arithmetic and periodically yields.
- [x] A controller records cntvct, releases the high thread semaphore, and waits for completion.
- [x] High thread records wake latency at first instruction after rt_sem_take.
- [x] Reuse summarize/print and emit metric=wake_under_load.
- [x] Run a short native suite and verify missing=0.

## Task 6: suite integration and native baseline entry point

- [x] Call the four new benchmark functions from rtbench_run_suite after the existing preemption/irq tests.
- [x] Ensure RTBENCH_END remains FAIL if any metric misses samples or returns an error.
- [x] Extend run_rtthread_native_baseline.sh with an optional suite mode that builds and runs benchmark 1000 or benchmark 100000 and verifies the resulting log with verify_rtbench_suite.sh.
- [x] Add contract tests for the native baseline suite option.
- [x] Run script syntax and contract tests.

## Task 7: AxVisor and coexistence runner integration

- [x] Add realtime-suite sample count 100000 to the evaluation mode.
- [x] Ensure run_task123.sh sends the extended benchmark command to VM 3 while the Linux guest's Task 2/3 traffic remains active.
- [x] Keep allow-qemu-timer-limit behavior scoped to stability_jitter; extended suite metrics remain strict for data completeness but are reported by percentile rather than an unconditional 1ms hard gate.
- [x] Add run_rtthread_realtime_baseline.sh to orchestrate native suite/stability, AxVisor-only suite/stability, and AxVisor+Linux coexistence suite/stability.
- [x] Store logs and manifests under a single output directory.
- [x] Add a contract test that validates command construction and artifact layout without fake-QEMU success claims.

## Task 8: comparable summarizer and assessment

- [x] Create summarize_rtthread_realtime.py to parse all RTBENCH metric lines.
- [x] Require every expected metric and reject duplicate/incomplete records.
- [x] Compute A ratios for B/A and C/B per percentile and max.
- [x] Classify data completeness, strict tail pass (max <= 1ms), tail degradation (C/B max ratio > 2), and baseline gap (B/A P99 ratio > 2).
- [x] Output Markdown and JSON reports.
- [x] Add failing shell contract tests for complete, missing-metric, duplicate-metric, and malformed-input cases.
- [x] Implement until all tests pass.

## Task 9: execution and evidence

- [x] Build one RT-Thread image and reuse it for A/B/C.
- [x] Run quick 1000-sample A/B/C suite as a smoke gate.
- [x] Run 100000-sample A/B/C evaluation suite.
- [x] Run 300-second stability_jitter in A/B/C.
- [x] Save all raw logs, manifests, QEMU settings, hashes, CSV/JSON, and Markdown report under history-docs/task123/evidence/2026-08-21/tgoskits/rt-thread-realtime-extended/.
- [x] Update history-docs/report-v2.md and INDEX.md with the final assessment.
- [x] Explicitly distinguish native QEMU measurements from hardware WCET and state the synthetic-scope limitation of irq_disabled_duration.

## Task 10: final verification

- [x] bash -n all touched shell scripts.
- [x] Run test_rtbench_suite_gate.sh.
- [x] Run the new summarizer contract tests.
- [x] Run the new baseline runner contract tests.
- [x] Run existing test_task123_runner_lifecycle.sh and test_task123_result_gate.sh.
- [x] Run git diff --check.
- [x] Inspect git status and report all modified files without committing unless requested.
