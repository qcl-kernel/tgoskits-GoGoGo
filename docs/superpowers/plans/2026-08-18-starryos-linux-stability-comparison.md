# StarryOS/Linux Stability Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reproducible 300-second and 3600-second StarryOS/Linux stability comparisons under identical AxVisor/QEMU/RT-Thread conditions.

**Architecture:** Generalize the existing Task123 runner and result gate with an application-guest selector while preserving Linux defaults. Add a comparison orchestrator and a focused Python analyzer that consume two accepted run directories and emit JSON plus a Chinese Markdown report.

**Tech Stack:** Bash, Python 3 standard library, TOML VM configurations, AxVisor xtask, QEMU AArch64, RT-Thread, StarryOS.

---

### Task 1: Generic StarryOS VM Configuration

**Files:**
- Create: `os/axvisor/scripts/generate_starryos_vmconfig.sh`
- Create: `os/axvisor/scripts/test_generate_starryos_vmconfig.sh`

- [ ] Write contract tests for an immutable runtime StarryOS config with a replaced kernel path and guest cmdline.
- [ ] Run `bash os/axvisor/scripts/test_generate_starryos_vmconfig.sh` and verify it fails because the generator is missing.
- [ ] Implement the generator with canonical path, runtime-directory and TOML semantic validation.
- [ ] Re-run the test and expect `PASS`.

### Task 2: Application Guest Selection

**Files:**
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/test_task123_runner_lifecycle.sh`
- Modify: `os/axvisor/scripts/test_task123_topology.sh`

- [ ] Extend fake-runner fixtures with StarryOS markers and VM config assertions.
- [ ] Run lifecycle and topology tests and verify the new StarryOS cases fail.
- [ ] Add `--app-guest`, conditional image preparation, generic markers, manifest fields and StarryOS VM config generation.
- [ ] Re-run both tests and preserve all existing Linux cases.

### Task 3: Generic Result Authentication

**Files:**
- Modify: `os/axvisor/scripts/verify_task123_results.sh`
- Modify: `os/axvisor/scripts/verify_rtipc_results.sh`
- Modify: `os/axvisor/scripts/test_task123_result_gate.sh`
- Modify: `os/axvisor/guests/task3/scripts/summarize.py`

- [ ] Add StarryOS fixture cases that require StarryOS markers and reject mixed Linux markers.
- [ ] Run the result-gate tests and verify failure before implementation.
- [ ] Parameterize markers and authenticated log names while retaining `linux.log` for Linux compatibility.
- [ ] Re-run result-gate and Task3 summary tests.

### Task 4: Host Resource Sampling

**Files:**
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/test_task123_runner_lifecycle.sh`

- [ ] Add a fake-QEMU test requiring `host-metrics.txt` with elapsed, CPU, RSS and thread fields.
- [ ] Verify the test fails because no sampler exists.
- [ ] Add a scoped `/proc/<qemu-pid>` sampler owned and reaped by the runner.
- [ ] Verify successful and interrupted runs do not leak sampler processes.

### Task 5: Comparison Analyzer and Orchestrator

**Files:**
- Create: `os/axvisor/scripts/compare_task123_guests.py`
- Create: `os/axvisor/scripts/test_compare_task123_guests.py`
- Create: `os/axvisor/scripts/run_task123_guest_comparison.sh`
- Create: `os/axvisor/scripts/test_task123_guest_comparison.sh`

- [ ] Write fixture tests for matching inputs, RTT/throughput deltas, RTBench metrics and mismatched-artifact rejection.
- [ ] Verify both new tests fail before implementation.
- [ ] Implement strict parsers and atomic JSON/Markdown publication.
- [ ] Implement `--quick` and `--full` orchestration with one shared artifact set.
- [ ] Re-run analyzer and orchestrator tests.

### Task 6: Runtime Validation and Report

**Files:**
- Modify: `docs/docs/quickstart/starryos.md`
- Create: `docs/reports/starryos-linux-stability-comparison.md`

- [ ] Run all focused shell/Python tests and `git diff --check`.
- [ ] Run the 300-second comparison and preserve raw evidence.
- [ ] Run the 3600-second comparison and preserve raw evidence.
- [ ] Generate and review the Chinese report, explicitly noting QEMU/TCG limitations.
- [ ] Commit source, tests and report without committing generated binaries or temporary runtime directories.
