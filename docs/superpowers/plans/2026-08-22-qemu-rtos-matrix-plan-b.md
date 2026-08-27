# QEMU RTOS/App-Guest Matrix Plan B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Support four selectable QEMU combinations---RT-Thread/Zephyr crossed with Linux/StarryOS---while preserving the current default RT-Thread + Linux/StarryOS comparison behavior.

**Architecture:** Keep AxVisor and the app-guest workload unchanged and add an explicit RTOS dimension. RT-Thread remains the default. Zephyr is built from a pinned source cache, runs alone on pCPU 2, uses virtio-net over a real SPI interrupt path, and shares the protocol/application state machines already used by RT-Thread.

**Tech Stack:** Bash orchestration, Python analysis, C on RT-Thread and Zephyr, CMake/Ninja for Zephyr, Cargo/AxVisor, and real QEMU TCG.

---

### Task 1: Runner API and contract tests

**Files:**
- Modify: run-task123.sh
- Modify: os/axvisor/scripts/run_task123.sh
- Modify: os/axvisor/scripts/run_task123_guest_comparison.sh
- Modify: os/axvisor/scripts/test_run_task123_entrypoint.sh
- Modify: os/axvisor/scripts/test_task123_runner_lifecycle.sh
- Modify: os/axvisor/scripts/test_task123_guest_comparison.sh

- [ ] Add --rtos rtthread|zephyr with default rtthread.
- [ ] Keep --app-guest linux|starryos and default comparison behavior unchanged.
- [ ] Add --matrix all only to the root one-command entrypoint and comparison orchestrator; it runs four combinations sequentially, never three guests in one QEMU.
- [ ] Give each matrix run an independent output directory and manifest labels.
- [ ] Run the focused shell contract tests and verify the new options fail before implementation and pass afterward.

### Task 2: Pinned Zephyr source and image builder

**Files:**
- Create: os/axvisor/scripts/prepare_zephyr_source.sh
- Create: os/axvisor/scripts/build_zephyr_task123.sh
- Create: os/axvisor/scripts/zephyr_image_metadata.py
- Create: os/axvisor/scripts/test_zephyr_build_contract.sh

- [ ] Pin Zephyr stable tag v4.4.2 and its peeled commit in the builder.
- [ ] Store the west workspace under tmp/source-cache/zephyr/<commit>/workspace.
- [ ] Build os/axvisor/guests/zephyr-task123 for qemu_cortex_a53.
- [ ] Publish zephyr.bin, its exact entry point, and JSON metadata into a persistent current-image directory.
- [ ] Show Git/CMake/Ninja progress directly; do not redirect downloads to per-run temporary trees.
- [ ] Verify metadata authentication, source pinning, real interrupt build flag, and reproducible cache reuse by contract test.

### Task 3: Shared protocol and Task 3 platform layer

**Files:**
- Move platform-independent responder/peer/time/status helpers from os/axvisor/guests/rt-ipc/rtthread/ to os/axvisor/guests/rt-ipc/common/.
- Modify: os/axvisor/guests/rt-ipc/rtthread/SConscript
- Modify: os/axvisor/guests/rt-ipc/tests/Makefile
- Create: os/axvisor/guests/rt-ipc/zephyr/
- Create: os/axvisor/guests/task3/src/zephyr/task3_server.c

- [ ] Keep public function names and wire behavior unchanged so existing protocol tests remain valid.
- [ ] Add a Zephyr UDP adapter for RT-IPC port 9876 and Task 3 port 9877.
- [ ] Reuse the common RT-IPC reliability actions and Task 3 controller/session code; do not duplicate either state machine.
- [ ] Preserve the existing status/final markers used by result gates.
- [ ] Run the native RT-IPC/Task 3 test suites before adding the Zephyr adapter.

### Task 4: Zephyr Task123 guest

**Files:**
- Create: os/axvisor/guests/zephyr-task123/
- Create: os/axvisor/configs/vms/qemu/aarch64/zephyr-task123.toml
- Create: os/axvisor/scripts/generate_zephyr_vmconfig.sh

- [ ] Configure static address 192.168.77.30/24 and the same peer ports as RT-Thread.
- [ ] Keep AXVISOR_DISABLE_VIRTIO_IRQ_POLL defined for all tested images.
- [ ] Start Task2 echo, Task3 control service, and RTBENCH from the guest command line without a shell dependency.
- [ ] Keep Zephyr fixed to pCPU 2 and the app guest at 2 vCPUs on pCPU set {0,1,3}.
- [ ] Generate a runtime VM config with the exact linked entry point and immutable image link.

### Task 5: Zephyr RTBENCH parity

**Files:**
- Modify: os/axvisor/guests/zephyr-task123/src/*
- Modify: os/axvisor/scripts/verify_rtbench_stability.sh
- Modify: os/axvisor/scripts/verify_rtbench_suite.sh
- Modify: os/axvisor/scripts/summarize_rtthread_realtime.py

- [ ] Emit the same marker grammar as RT-Thread.
- [ ] First bring up stability_jitter, callback_exec, and network RTT so all four combinations complete.
- [ ] Then add the extended suite mappings using k_thread, k_sem, k_mutex, k_msgq, timers, CNTVCT, and virtual PMU cycle/instruction counters.
- [ ] Include ns, cycles, instructions, P50/P95/P99/P99.9/max/mean, and threshold miss counts wherever RT-Thread reports them.
- [ ] Keep known QEMU TCG timer-limit classification explicit rather than hiding long tails.

### Task 6: Real-QEMU integration and reports

**Files:**
- Modify: os/axvisor/scripts/run_task123.sh
- Modify: os/axvisor/scripts/run_task123_guest_comparison.sh
- Modify: os/axvisor/scripts/compare_task123_guests.py
- Create: comp-docs/task123/report/2026-08-22/tgoskits/qemu-rtos-matrix/README.md

- [ ] Verify default ./run-task123.sh still selects RT-Thread.
- [ ] Run each combination with real QEMU in quick mode.
- [ ] Run ./run-task123.sh --matrix all --quick.
- [ ] Record source versions, CPU partitioning, network topology, Task1/2/3 results, limitations, and exact reproduction commands.
- [ ] Run all touched contract suites and git diff --check before claiming completion.
