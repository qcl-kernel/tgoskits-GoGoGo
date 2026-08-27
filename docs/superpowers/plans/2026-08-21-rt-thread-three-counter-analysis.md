# RT-Thread Three-Counter Real-Time Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and compare virtual time, virtual CPU cycles, and retired-instruction counts for every RT-Thread real-time benchmark metric.

**Architecture:** Keep one sample boundary for all three counters. `CNTVCT_EL0` remains the primary latency metric in nanoseconds; `PMCCNTR_EL0` and the programmable event counter for ARM event `0x08` are parallel explanatory metrics. The guest emits one backward-compatible RTBENCH record containing the existing nanosecond fields plus cycle and instruction distributions, while host parsers validate and export all three units.

**Tech Stack:** RT-Thread AArch64 C, ARMv8 PMUv3 system registers, QEMU AArch64 TCG, Bash result gates, Python JSON/CSV/Markdown summarizer.

---

### Task 1: Define the three-counter result contract

**Files:**
- Modify: `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`
- Modify: `os/axvisor/scripts/verify_rtbench_suite.sh`
- Modify: `os/axvisor/scripts/verify_rtbench_stability.sh`
- Modify: `os/axvisor/scripts/summarize_rtthread_realtime.py`
- Test: `os/axvisor/scripts/test_rtbench_suite_gate.sh`
- Test: `os/axvisor/scripts/test_rtbench_stability_gate.sh`

- [x] Add a `rtbench_counter_sample` with `time_ticks`, `cycles`, and `instructions`, and a result structure for each unit. Keep `p50_ns`, `p95_ns`, `p99_ns`, `p99_9_ns`, `max_ns`, `mean_ns`, and the existing miss counters unchanged.
- [x] Define additional fields with the exact names `p50_cycles`, `p95_cycles`, `p99_cycles`, `p99_9_cycles`, `max_cycles`, `mean_cycles`, `p50_instructions`, `p95_instructions`, `p99_instructions`, `p99_9_instructions`, `max_instructions`, and `mean_instructions`.
- [x] Extend synthetic gate fixtures with all additional fields and make the gate require them exactly once for every metric record.
- [x] Extend the parser required-field list and CSV/JSON/Markdown output; preserve old logs as rejected for this new three-counter mode rather than silently filling missing PMU fields.
- [x] Run the gate tests before implementation and confirm they fail because the new fields are absent.

### Task 2: Add guest PMU initialization and capability reporting

**Files:**
- Modify: `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/run_rtipc_test.sh`
- Modify: `os/axvisor/scripts/run_rtthread_native_baseline.sh`
- Test: `os/axvisor/scripts/test_task123_topology.sh`

- [x] Read `PMCR_EL0`, configure event counter 0 for ARM event `0x08` (`INST_RETIRED`), reset and enable `PMCCNTR_EL0` and counter 0, and issue `isb` after control-register writes.
- [x] Read the initial counter values twice around a small volatile instruction sequence. Emit `RTBENCH_PMU status=ready cycles_delta=... instructions_delta=...` only when both counters advance; otherwise emit `RTBENCH_PMU status=unavailable reason=...` and fail the three-counter benchmark mode.
- [x] Use `-cpu cortex-a72,pmu=on` in real QEMU commands. Record the CPU/PMU and whether precise icount is enabled in the run manifest.
- [x] Do not call an unavailable PMU counter and report its zero value as data. The result gate must distinguish `unavailable` from a valid zero delta.

### Task 3: Capture all counters at existing benchmark boundaries

**Files:**
- Modify: `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`

- [x] Replace each direct `rtbench_read_counter()` start/end pair with `rtbench_read_sample()` and store all three deltas for `timer_jitter`, `callback_exec`, `preemption`, `irq`, `irq_to_task`, `irq_disabled_duration`, `mutex_inversion`, `wake_under_load`, `net_event_latency`, and `stability_jitter`.
- [x] Use unsigned wrap-safe subtraction for the cycle and instruction counters; document the counter width used by the guest PMU.
- [x] Summarize each unit with the existing percentile implementation. Keep nanosecond threshold counters only on the nanosecond distribution because the 100 us/500 us/1 ms limits are time requirements, not cycle requirements.
- [x] Print all three distributions on the same metric line so the host normalizer cannot pair different samples from different runs.
- [x] Keep `RTBENCH_END` and stability sample conservation semantics unchanged.

### Task 4: Update host analysis and reproducibility metadata

**Files:**
- Modify: `os/axvisor/scripts/summarize_rtthread_realtime.py`
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/run_rtthread_realtime_baseline.sh`
- Modify: `docs/docs/build/axvisor/task123-reproduction-cn.md`

- [x] Add per-unit ratios for B/A and C/B to JSON and CSV, and add separate Markdown tables for nanoseconds, cycles, and instructions.
- [x] Make the assessment state that nanoseconds are the latency result, cycles are QEMU virtual-cycle work, and instructions are precise-icount work when enabled; do not combine them into one score.
- [x] Record `qemu_cpu`, `qemu_pmu`, `qemu_icount`, guest PMU status, guest PMU event, and counter frequency in the manifest.
- [x] Document that default QEMU TCG cycle values are virtual and that instruction values require precise icount; hardware-cycle conclusions require a real AArch64/KVM run.

### Task 5: Test, build, and run a short real-QEMU validation

**Files:**
- Test: all touched shell and Python tests
- Evidence: `tmp/task123-*` output selected by the user

- [x] Run the contract tests in the red state before code changes and in the green state afterward.
- [x] Run `bash -n` on all touched shell scripts and `python3 -m py_compile` on the summarizer.
- [x] Build the single RT-Thread benchmark image and run a short real-QEMU suite with three-counter output visible in the terminal.
- [x] Confirm every metric contains complete nanosecond, cycle, and instruction fields, PMU status is `ready`, and the parser produces JSON/CSV/Markdown without dropping any unit.
- [x] Run `git diff --check` and inspect the final diff for unrelated changes.

## Verification snapshot

The native real-QEMU suite used `QEMU_ICOUNT=shift=3`, `-cpu cortex-a72,pmu=on`,
and `tcg,thread=single`. It produced `RTBENCH_PMU status=ready` with
`cycles_delta=12392 instructions_delta=1549`, and passed the two-sample suite
gate. The default was changed from `shift=auto` because QEMU's adaptive icount
mode does not advertise `INST_RETIRED`; using it would silently turn the third
metric into zero.

The RT-Thread console buffer was raised from 256 to 1024 bytes in the AxVisor
port configuration. Without that change, the long three-counter record was
truncated before the cycle and instruction fields reached the host parser.
