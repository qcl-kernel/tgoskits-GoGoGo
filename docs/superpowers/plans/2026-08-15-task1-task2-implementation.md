# AxVisor Task 1 and Task 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a reproducible AxVisor configuration that boots a two-vCPU Linux guest and a CPU-pinned RT-Thread guest, provides bidirectional RT-IPC communication over virtio-net/IP, and produces trustworthy real-time and network measurements.

**Architecture:** Keep Linux vCPUs schedulable on the configured host CPU set while pinning the RT-Thread vCPU to its dedicated host CPU. Network ingress is queued by the internal L2 switch, wakes the target vCPU through the existing runtime notification path, and is drained by the vCPU-owned device poll path before delivering a guest interrupt. RT-IPC remains UDP-based with explicit framing, CRC, ACK/retry, duplicate and reorder handling.

**Tech Stack:** Rust/AxVisor, ArceOS `ax-task`, AArch64 GIC/virtio-mmio, C RT-IPC, RT-Thread 5.2.2/lwIP, shell-based reproducibility tests.

---

### Task 1: Reproduce and isolate host wakeup behavior

**Files:**
- Inspect: `virtualization/axvm/src/runtime/vcpus.rs`
- Inspect: `virtualization/axvm/src/vm/mod.rs`
- Inspect: `os/arceos/modules/axtask/src/run_queue.rs`
- Inspect: `os/arceos/modules/axtask/src/wait_queue.rs`
- Test: `os/axvisor/scripts/test_host_realtime_contract.sh`

- [ ] Run the host contract test and a current build with the scheduler configuration exactly as checked out.
- [ ] Reproduce the IRQ-context panic with the smallest network/boot command and capture the full caller path.
- [ ] Add a narrowly scoped regression assertion for the chosen wakeup contract before changing scheduler code.

### Task 2: Implement safe vCPU wakeup and guest device progress

**Files:**
- Modify: `virtualization/axvm/src/runtime/vcpus.rs`
- Modify: `virtualization/axvm/src/vm/mod.rs`
- Modify: `os/axvisor/src/virtio_net.rs`
- Modify: `os/arceos/modules/axtask/src/run_queue.rs` only if the isolated scheduler test proves the remote-reschedule path is incomplete
- Test: relevant Rust unit tests and `os/axvisor/scripts/test_host_realtime_contract.sh`

- [ ] Ensure ingress notification publishes state before waking the target CPU and that the wake operation is legal from the caller context.
- [ ] Ensure a woken vCPU drains DMA and pulses the guest IRQ without requiring an unrelated host scheduler time slice.
- [ ] Do not keep `sched-rr` enabled solely as a workaround if it causes the NVMe IRQ path to sleep; either fix the specific illegal path or use the existing IPI contract with a valid scheduler configuration.
- [ ] Build AxVisor and verify both VMs reach their expected boot state.

### Task 3: Make RT-IPC integration deterministic

**Files:**
- Modify: `os/axvisor/guests/rt-ipc/common/rt_ipc.c`
- Modify: `os/axvisor/guests/rt-ipc/common/rt_ipc.h`
- Modify: `os/axvisor/guests/rt-ipc/linux/rtipc_client.c`
- Modify: `os/axvisor/guests/rt-ipc/rtthread/rtipc_server.c`
- Modify: `os/axvisor/scripts/run_rtipc_test.sh`
- Test: `os/axvisor/guests/rt-ipc/tests/protocol_test.c`

- [ ] Add failing tests proving a received DELIVER action survives until the caller drains it and that retransmission is not triggered when the configured RTO exceeds the measured RTT.
- [ ] Implement the smallest action-queue and integration-loop correction that passes those tests.
- [ ] Use millisecond-accurate throughput calculation and report sent, received, timeout, retransmission, duplicate, reorder, protocol-error, and reconnect counters.
- [ ] Set or derive an RTO with margin over the measured RTT while preserving a short-RTO unit test for actual retry behavior.

### Task 4: Make RT-Thread real-time measurements valid

**Files:**
- Modify through patch: `os/axvisor/patches/rtthread/*.patch`
- Modify through patch: `os/axvisor/patches/rtthread/apply-rtthread-patches.sh`
- Test: `os/axvisor/patches/rtthread/test-rtthread-patches.sh`

- [ ] Add failing invariants for actual sample counts, deadline-miss counters, percentile output, and an explicit long-test duration.
- [ ] Patch the benchmark to compute P50/P95/P99/P99.9/max from collected samples and distinguish missing samples/timeouts from valid zero values.
- [ ] Collect no-network and network-load runs, including host CPU load distribution, with an explicit duration and command line.

### Task 5: End-to-end verification and report

**Files:**
- Modify: `docs/docs/build/axvisor/rtthread-realtime-report.md`
- Add/update: reproducibility logs under `docs/docs/build/axvisor/`

- [ ] Run protocol tests, patch invariants, host contract tests, a fresh AxVisor build, and the two-guest boot test.
- [ ] Run at least 1000 RT-IPC requests for each payload size and record success, errors, retries, RTT percentiles, and throughput.
- [ ] Run the configured long-stability test and retain raw output.
- [ ] Update the report only with evidence from the current source tree and explicitly mark any hardware/KVM evidence that is unavailable.

