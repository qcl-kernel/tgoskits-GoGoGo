# AxVisor RT-Thread Debug Code Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Remove temporary debug assets and hot-path diagnostics from the AxVisor Linux plus RT-Thread implementation while proving that functionality and realtime performance do not regress.

**Architecture:** Preserve report evidence under docs/docs/build/axvisor, but remove workstation launchers, backups, generated outputs, debug-dependent artifact checks, and runtime-only network counters. Keep protocol errors and structured benchmark records because they are product and acceptance-test observability.

**Tech Stack:** Rust/Cargo, POSIX shell, C, RT-Thread 5.2.2, SCons through uv, QEMU AArch64 TCG, VirtIO MMIO networking, RT-IPC over UDP/IP.

---

### Task 1: Record baseline and make stale-debug contract fail

**Files:**
- Modify: os/axvisor/scripts/test_rtbench_precision.sh:4-10,84-93
- Reference: docs/docs/build/axvisor/rtthread-realtime-report.md:100-170

- [ ] **Step 1: Capture pre-cleanup state**

Run git status --short --branch, git diff --check, and sha256sum on task12-busy-wfi-fast-v8-300s.log.

Expected: dirty state and baseline digest recorded, with no whitespace error.

- [ ] **Step 2: Extend negative debug-code contract**

Add ARTIFACT_VALIDATOR beside the source paths and make the existing debug-pattern loop scan AXVISOR_CONFIG_SOURCE and ARTIFACT_VALIDATOR.

- [ ] **Step 3: Verify the new assertion fails**

Run bash os/axvisor/scripts/test_rtbench_precision.sh.

Expected: FAIL with stale host-policy debug code because the validator still contains the old string or witness.

### Task 2: Remove debug-dependent artifact validation

**Files:**
- Modify: os/axvisor/scripts/validate_qemu_artifact.sh:28,87-127
- Test: os/axvisor/scripts/test_rtbench_precision.sh

- [ ] **Step 1: Remove debug-only tool dependencies**

Remove awk and nm from the validator tool preflight.

- [ ] **Step 2: Remove diagnostic witnesses**

Keep the Python VM-config byte checks, but remove host_policy_diagnostic and the complete HOST_POLICY_WITNESS/nm block. Change the failure message to required VM config bytes are absent from Axvisor artifacts. Preserve raw-image comparison, canonical paths, SHA-256 checks, immutability, and manifest publication.

- [ ] **Step 3: Run contracts**

Run test_rtbench_precision.sh and test_rtipc_runner_lifecycle.sh.

Expected: source contract passed and lifecycle PASS.

### Task 3: Remove VirtIO network hot-path diagnostics

**Files:**
- Modify: os/axvisor/src/virtio_net.rs:3-5,36-61,105-110,137-239,418-500,700-930
- Test: inline tests in os/axvisor/src/virtio_net.rs

- [ ] **Step 1: Replace counter assertion**

In runtime_no_buffer_waits_for_mmio_rx_kick_before_delivery, remove rx_no_buffer_count assertions. Poll twice and assert TEST_RX_USED index remains zero before the guest queue kick.

- [ ] **Step 2: Verify behavioral assertion passes**

Run cargo test -p axvisor runtime_no_buffer_waits_for_mmio_rx_kick_before_delivery.

Expected: PASS.

- [ ] **Step 3: Remove allocation and TX counters**

Remove VirtioNetModel.id and MMIO log::debug. Reduce SwitchBackend to endpoint and switch. Keep dropped-frame warning without cumulative count. Remove tx_count/drop_count from every constructor.

- [ ] **Step 4: Remove no-buffer counter**

Remove rx_no_buffer_count from VirtioNetRuntimeDevice and constructors. On NoGuestBuffer, requeue the frame and break. Restore atomic imports to AtomicBool, AtomicUsize, and Ordering.

- [ ] **Step 5: Run VirtIO tests**

Run cargo fmt --all -- --check, cargo test -p axvirtio-net, and cargo test -p axvisor virtio_net.

Expected: all selected tests pass, including deferred retry and interrupt delivery.

### Task 4: Remove Linux guest network dumps

**Files:**
- Modify: os/axvisor/guests/linux-net/init-linux-1:12-48
- Modify/Test: os/axvisor/scripts/test_rtipc_result_gate.sh

- [ ] **Step 1: Add failing source check**

Reject the exact strings Linux network counters before RT-IPC, Linux network counters after RT-IPC, and Linux UDP sockets after RT-IPC in init-linux-1.

~~~bash
LINUX_INIT="$ROOT/os/axvisor/guests/linux-net/init-linux-1"
for stale_dump in \
  'Linux network counters before RT-IPC:' \
  'Linux network counters after RT-IPC:' \
  'Linux UDP sockets after RT-IPC:'; do
  if rg -q --fixed-strings "$stale_dump" "$LINUX_INIT"; then
    fail "stale Linux guest network dump remains: $stale_dump"
  fi
done
~~~

- [ ] **Step 2: Verify assertion fails**

Run test_rtipc_result_gate.sh. Expected: stale Linux guest network dump remains.

- [ ] **Step 3: Remove only diagnostic dumps**

Delete success-path extra ifconfig, proc/net/snmp, and proc/net/udp writes. Preserve LINUX_SMP_READY, ready/reachability results, RT-IPC invocation, client exit status, and failure-only interface/neighbor diagnostics. Normalize indentation.

- [ ] **Step 4: Verify result gate passes**

Run test_rtipc_result_gate.sh. Expected: PASS.

### Task 5: Delete temporary assets

**Files:**
- Delete: run-debug.sh, run-gicv2-test.sh, run-head-120.sh, run-head-test.sh
- Delete: run-main.sh, run-rx-debug.sh, run-txdbg.sh, run-verify.sh
- Delete: os/arceos/api/arceos_posix_api/src/imp/io.rs.bak
- Delete: os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-passthrough
- Delete: os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-virt
- Delete: os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-passthrough
- Delete: os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-virt
- Delete: os/axvisor/configs/vms/qemu/aarch64/rtthread-net.dtb

- [ ] **Step 1: Recheck references**

Use rg for every basename, excluding .git and target. Expected: no maintained dependency.

- [ ] **Step 2: Delete with apply_patch**

Use explicit Delete File patches. Do not delete tmp content, report logs, or the QEMU diagnostic patch.

- [ ] **Step 3: Verify boundary**

Assert all candidates are absent and qemu-rtthread-timer-boundary-diagnostic.patch remains.

### Task 6: Run focused build and functional tests

**Files:** Verify only.

- [ ] **Step 1: Run Rust checks**

~~~bash
cargo fmt --all -- --check
cargo test -p arm_vcpu
cargo test -p axvmconfig
cargo test -p axvirtio-net
cargo test -p axvm --features host-test
~~~

Expected: all pass.

- [ ] **Step 2: Run RT-IPC C tests**

Run make -C os/axvisor/guests/rt-ipc/tests clean test.

Expected: protocol, loopback, concurrency, fault, lifecycle, and safety tests pass.

- [ ] **Step 3: Run shell contracts**

~~~bash
for test_script in \
  test_host_realtime_contract.sh \
  test_host_benchmark_timing.sh \
  test_qemu_realtime_controls.sh \
  test_rtbench_precision.sh \
  test_rtbench_suite_gate.sh \
  test_rtbench_stability_gate.sh \
  test_rtipc_result_gate.sh \
  test_rtipc_runner_lifecycle.sh \
  test_rtthread_native_baseline_contract.sh \
  test_rtthread_reproducibility_contract.sh \
  test_generate_linux_vmconfig.sh \
  test_run_until_log_marker.sh; do
  bash "os/axvisor/scripts/$test_script"
done
~~~

Expected: each exits zero with PASS.

- [ ] **Step 4: Build a fresh RT-Thread tree**

Prepare pinned RT-Thread 5.2.2 at tmp/rt-thread-5.2.2-cleanup, apply apply-rtthread-patches.sh, then run uv-managed scons in the qemu-virt64-aarch64 BSP.

Expected: patches apply and AArch64 image builds.

### Task 7: Run system and performance regression tests

**Files:**
- Modify: docs/docs/build/axvisor/rtthread-realtime-report.md
- Create: docs/docs/build/axvisor/task12-cleanup-*.log

- [ ] **Step 1: Run 1,000-sample suite**

~~~bash
RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
RTIPC_COUNT=1000 \
RTBENCH_SUITE_SAMPLES=1000 \
RTBENCH_START_MODE=concurrent \
QEMU_UCLAMP_MIN=1024 \
LOG=docs/docs/build/axvisor/task12-cleanup-suite-1000.log \
CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-suite-1000-cpu.log \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
bash os/axvisor/scripts/run_rtipc_test.sh
~~~

Expected: Linux online=0-1 nproc=2, RT-Thread network ready, all three sizes 1000/1000, benchmark gates pass.

- [ ] **Step 2: Run 300-second comparison**

~~~bash
RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
RTIPC_COUNT=30000 \
RTBENCH_STABILITY_SECONDS=300 \
RTBENCH_START_MODE=concurrent \
QEMU_UCLAMP_MIN=1024 \
LOG=docs/docs/build/axvisor/task12-cleanup-300s.log \
CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-300s-cpu.log \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
bash os/axvisor/scripts/run_rtipc_test.sh
~~~

Expected: 299999/299999 samples and 90000/90000 requests, no timeout, protocol/application error, or crash.

- [ ] **Step 3: Apply regression rule**

Compare with v8: P50 8.288 us, P95 241.328 us, P99 293.712 us, P99.9 362.144 us, max 1.193376 ms, miss_1ms=2. Fail on functional regression or repeatable P50/P95/P99 increase over 10 percent. If only max or miss_1ms worsens, repeat the long run once.

- [ ] **Step 4: Update report**

Append deleted assets, validator change, commands, hashes, suite and long-run metrics, network counters, CPU distribution, percentage comparisons, raw logs, and verdict. Preserve earlier evidence.

- [ ] **Step 5: Final integrity checks**

Run git diff --check, git status --short, git diff --stat origin/dev, and git diff --numstat origin/dev. Do not stage or revert unrelated user changes.
