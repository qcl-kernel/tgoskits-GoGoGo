# AxVisor Task 1/2/3 Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one reproducible AxVisor system that boots a two-vCPU Linux guest and a dedicated-core RT-Thread guest, preserves the accepted realtime and RT-IPC results, and runs the complete AI inference-to-control feedback loop over VirtIO-net/IPv4/UDP/RT-IPC v2.

**Architecture:** Work only on `feat/axvisor-task123` in `/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123`. Curate Task 1/2 from the read-only original checkout, import only Git-tracked Task 3 content under `os/axvisor/guests/task3`, keep Task 2 on UDP 9876 and Task 3 on UDP 9877, and use one owned outer QEMU process per run. RT-Thread vCPU0 is restricted to pCPU 2 with busy WFI; both Linux vCPUs may run on pCPUs 0, 1, and 3.

**Tech Stack:** Rust 2024/no_std AxVisor and AxVM crates, AArch64 EL2/GICv3, RT-Thread 5.2.2, VirtIO-net MMIO, lwIP, C11 RT-IPC v2, Buildroot Linux, POSIX shell/Bash, SCons through `uv`, QEMU `virt`, Python 3/NumPy report tools.

---

## Workspace And File Map

All mutating commands in this plan run from:

```text
/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123
```

These trees are read-only migration inputs:

```text
/home/yfblock/Code/hyper-rtos/tgoskits
/home/yfblock/Code/hyper-rtos/qemu-task3
```

The implementation boundaries are:

- `virtualization/arm_vcpu/`: trapped WFI and TLBI architecture policy.
- `virtualization/axvmconfig/`: serialized VM policy and CPU-mask contract.
- `virtualization/axvm/`: vCPU runtime binding, guest FDT, VGIC routing, and VM-scoped TLBI.
- `virtualization/axvirtio-net/`: virtual switch and interrupt-driven RX contract tests.
- `os/axvisor/src/`: AxVisor policy wiring, virtual NIC registration, and guest console behavior.
- `os/axvisor/configs/`: two-guest topology, memory, devices, CPU masks, and guest command line.
- `os/axvisor/patches/rtthread/`: pinned RT-Thread source preparation and complete application patch/install flow.
- `os/axvisor/guests/rt-benchmark/`: canonical RT-Thread realtime benchmark source.
- `os/axvisor/guests/rt-ipc/`: authoritative RT-IPC v2 and Task 2 applications/tests.
- `os/axvisor/guests/task3/`: imported Task 3 model, codec, controller, Linux app, RT-Thread service, tests, and baseline evidence.
- `os/axvisor/scripts/run_task123.sh`: one owner for build, launch, markers, PID cleanup, artifact hashes, and result gates.
- `docs/docs/build/axvisor/`: Chinese reproduction guide and accepted AxVisor-only test report.

Generated sources, images, logs, CSV, JSON, and run manifests stay below `tmp/task123-*` or a caller-supplied output directory and are not committed.

### Task 1: Curate Task 1/2 Into The Isolated Worktree

**Files:**
- Modify/Delete: the 62 tracked paths listed in Step 3
- Create: the 59 untracked paths listed in Step 4
- Delete: `container/test-rtthread-repro.sh`
- Test: `virtualization/arm_vcpu/tests/wfi_policy_contract_test.rs`
- Test: `virtualization/arm_vcpu/tests/tlbi_policy_contract_test.rs`
- Test: `virtualization/axvmconfig/src/test.rs`
- Test: `virtualization/axvm/src/config.rs`
- Test: `virtualization/axvirtio-net/tests/net_tests.rs`

- [ ] **Step 1: Record the isolated destination and read-only source state**

Run:

```bash
test "$(git rev-parse --show-toplevel)" = "/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123"
test "$(git branch --show-current)" = "feat/axvisor-task123"
git status --short
git -C /home/yfblock/Code/hyper-rtos/tgoskits rev-parse HEAD
git -C /home/yfblock/Code/hyper-rtos/tgoskits status --porcelain=v1 | sha256sum
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --binary | sha256sum
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --cached --binary | sha256sum
```

Expected: destination is clean; source HEAD is `cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35`. Record but do not repair any source fingerprint difference.

- [ ] **Step 2: Reproduce the two known pre-migration test failures**

Run:

```bash
cargo test -p arm_vcpu
cargo test -p axvm --features host-test
```

Expected: `arm_vcpu` fails because WFI policy APIs are absent; `axvm` fails because four FDT test call sites lack the new policy arguments. These failures prove that the migration changes behavior rather than merely changing source text.

- [ ] **Step 3: Apply only the approved tracked Task 1/2 diff**

Use `git diff --binary HEAD -- <paths>` in the original checkout and apply that patch in this worktree. The exact tracked allowlist is:

```text
Cargo.lock
docs/docs/build/axvisor/rtthread-realtime-report.md
os/arceos/api/arceos_posix_api/src/imp/io.rs.bak
os/axvisor/Cargo.toml
os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml
os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml
os/axvisor/configs/qemu/qemu-aarch64-two-guest-net.toml
os/axvisor/configs/vms/qemu/aarch64/linux-net.toml
os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-passthrough
os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-virt
os/axvisor/configs/vms/qemu/aarch64/rtthread-baseline.toml
os/axvisor/configs/vms/qemu/aarch64/rtthread-net.dts
os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml
os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-passthrough
os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-virt
os/axvisor/guests/linux-net/init-linux-1
os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c
os/axvisor/guests/rt-ipc/common/rt_ipc.c
os/axvisor/guests/rt-ipc/common/rt_ipc.h
os/axvisor/guests/rt-ipc/linux/Makefile
os/axvisor/guests/rt-ipc/linux/rtipc_client.c
os/axvisor/guests/rt-ipc/rtthread/rtipc_server.c
os/axvisor/guests/rt-ipc/tests/Makefile
os/axvisor/guests/rt-ipc/tests/loopback_test.c
os/axvisor/guests/rt-ipc/tests/protocol_test.c
os/axvisor/patches/rtthread/apply-rtthread-patches.sh
os/axvisor/scripts/run_rtipc_test.sh
os/axvisor/scripts/test_rtbench_precision.sh
os/axvisor/scripts/validate_qemu_artifact.sh
os/axvisor/src/config.rs
os/axvisor/src/guest_console/mux/mod.rs
os/axvisor/src/manager.rs
os/axvisor/src/virtio_net.rs
os/axvisor/tests/axtest.rs
platforms/somehal/src/arch/aarch64/gic/mod.rs
run-debug.sh
virtualization/arm_vcpu/README.md
virtualization/arm_vcpu/src/architecture/exception.S
virtualization/arm_vcpu/src/architecture/exception.rs
virtualization/arm_vcpu/src/architecture/mod.rs
virtualization/arm_vcpu/src/architecture/vcpu.rs
virtualization/arm_vcpu/src/lib.rs
virtualization/arm_vcpu/src/types.rs
virtualization/arm_vcpu/src/world_switch_tests.rs
virtualization/arm_vcpu/tests/wfi_policy_contract_test.rs
virtualization/axvirtio-net/tests/net_tests.rs
virtualization/axvm/src/arch/aarch64/capabilities.rs
virtualization/axvm/src/arch/aarch64/gic.rs
virtualization/axvm/src/arch/aarch64/mod.rs
virtualization/axvm/src/arch/aarch64/resource_pools.rs
virtualization/axvm/src/arch/aarch64/vgic/plan.rs
virtualization/axvm/src/arch/aarch64/vm.rs
virtualization/axvm/src/arch/riscv64/capabilities.rs
virtualization/axvm/src/architecture/types.rs
virtualization/axvm/src/boot/fdt/core/create.rs
virtualization/axvm/src/boot/fdt/core/parser.rs
virtualization/axvm/src/config.rs
virtualization/axvm/src/runtime/vcpus.rs
virtualization/axvm/src/vm/mod.rs
virtualization/axvmconfig/src/lib.rs
virtualization/axvmconfig/src/templates.rs
virtualization/axvmconfig/src/test.rs
```

Expected: the patch applies without rejects. `container/test-rtthread-repro.sh` is not included.

- [ ] **Step 4: Copy only the approved untracked Task 1/2 files**

Copy these exact files while preserving relative paths:

```text
configs/board/arm/qemu-aarch64-two-guest-net/config/qemu-aarch64-two-guest-net.toml
docs/superpowers/plans/2026-08-15-task1-task2-implementation.md
os/axvisor/guests/rt-ipc/linux/rtipc_client_report.c
os/axvisor/guests/rt-ipc/linux/rtipc_client_report.h
os/axvisor/guests/rt-ipc/linux/rtipc_fault.c
os/axvisor/guests/rt-ipc/linux/rtipc_fault.h
os/axvisor/guests/rt-ipc/linux/rtipc_shutdown.c
os/axvisor/guests/rt-ipc/linux/rtipc_shutdown.h
os/axvisor/guests/rt-ipc/rtthread/rtipc_echo_responder.c
os/axvisor/guests/rt-ipc/rtthread/rtipc_echo_responder.h
os/axvisor/guests/rt-ipc/rtthread/rtipc_peer.c
os/axvisor/guests/rt-ipc/rtthread/rtipc_peer.h
os/axvisor/guests/rt-ipc/rtthread/rtipc_server_status.c
os/axvisor/guests/rt-ipc/rtthread/rtipc_server_status.h
os/axvisor/guests/rt-ipc/rtthread/rtipc_time.c
os/axvisor/guests/rt-ipc/rtthread/rtipc_time.h
os/axvisor/guests/rt-ipc/tests/client_clock_wrap.c
os/axvisor/guests/rt-ipc/tests/crc_concurrency_test.c
os/axvisor/guests/rt-ipc/tests/echo_responder_test.c
os/axvisor/guests/rt-ipc/tests/fault_profile_test.c
os/axvisor/guests/rt-ipc/tests/linux_shutdown_test.c
os/axvisor/guests/rt-ipc/tests/platform_safety_test.c
os/axvisor/guests/rt-ipc/tests/state_machine_regression_test.c
os/axvisor/guests/rt-ipc/tests/test_rtthread_server_contract.sh
os/axvisor/patches/rtthread/0000-axvisor-aarch64-port.patch
os/axvisor/patches/rtthread/0002-lwip-rx-mailbox-recover-notice.patch
os/axvisor/patches/rtthread/0003-virtio-net-reclaim-tx-used-ring.patch
os/axvisor/patches/rtthread/0004-virtio-net-use-rx-used-ring-head.patch
os/axvisor/patches/rtthread/0005-lwip-configurable-udp-recv-mailbox.patch
os/axvisor/patches/rtthread/0006-gicv3-use-redistributor-pending-registers.patch
os/axvisor/patches/rtthread/0007-gicv3-query-interrupt-enable-state.patch
os/axvisor/patches/rtthread/0008-aarch64-gtimer-use-absolute-deadlines.patch
os/axvisor/patches/rtthread/0009-native-qemu-memory-layout.patch
os/axvisor/patches/rtthread/prepare_rtthread_source.sh
os/axvisor/patches/rtthread/test-rtthread-patches.sh
os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
os/axvisor/patches/rtthread/test_prepare_rtthread_source.sh
os/axvisor/scripts/apply_qemu_realtime_controls.sh
os/axvisor/scripts/generate_linux_vmconfig.sh
os/axvisor/scripts/generate_rtthread_vmconfig.sh
os/axvisor/scripts/host_benchmark_timing.sh
os/axvisor/scripts/run_rtthread_native_baseline.sh
os/axvisor/scripts/run_until_log_marker.sh
os/axvisor/scripts/test_generate_linux_vmconfig.sh
os/axvisor/scripts/test_host_benchmark_timing.sh
os/axvisor/scripts/test_host_realtime_contract.sh
os/axvisor/scripts/test_qemu_realtime_controls.sh
os/axvisor/scripts/test_rtbench_stability_gate.sh
os/axvisor/scripts/test_rtbench_suite_gate.sh
os/axvisor/scripts/test_rtipc_result_gate.sh
os/axvisor/scripts/test_rtipc_runner_lifecycle.sh
os/axvisor/scripts/test_rtthread_native_baseline_contract.sh
os/axvisor/scripts/test_rtthread_reproducibility_contract.sh
os/axvisor/scripts/test_run_until_log_marker.sh
os/axvisor/scripts/verify_rtbench_stability.sh
os/axvisor/scripts/verify_rtbench_suite.sh
os/axvisor/scripts/verify_rtipc_results.sh
virtualization/arm_vcpu/src/tlbi.rs
virtualization/arm_vcpu/tests/tlbi_policy_contract_test.rs
virtualization/axvm/src/arch/aarch64/tlbi.rs
```

Expected: 59 files are copied. No `*.log`, `*.patch` diagnostic, Docker reproduction file, backup, build output, or temporary launcher is copied.

- [ ] **Step 5: Remove the Docker reproduction side branch from this integration branch**

Run:

```bash
git rm container/test-rtthread-repro.sh
test ! -e container/Dockerfile.rtthread-repro
test ! -e container/rtthread-repro-preflight.sh
```

Expected: the base-tracked reproduction script is deleted and neither untracked Docker helper exists.

- [ ] **Step 6: Restore focused Task 1/2 tests to green**

Run:

```bash
cargo test -p axvmconfig
cargo test -p arm_vcpu
cargo test -p axvm --features host-test
cargo test -p axvirtio-net
make -C os/axvisor/guests/rt-ipc/tests clean all test
bash os/axvisor/scripts/test_host_realtime_contract.sh
bash os/axvisor/scripts/test_rtbench_suite_gate.sh
bash os/axvisor/scripts/test_rtbench_stability_gate.sh
bash os/axvisor/scripts/test_rtipc_result_gate.sh
bash os/axvisor/scripts/test_rtipc_runner_lifecycle.sh
```

Expected: every command exits 0; `axvmconfig` reports 11 passing tests or more; RT-IPC and all shell gates print `PASS`.

- [ ] **Step 7: Format, lint, and commit the curated migration**

Run:

```bash
cargo fmt --all --check
cargo xtask clippy --package arm_vcpu
cargo xtask clippy --package axvmconfig
cargo xtask clippy --package axvm
cargo xtask clippy --package axvirtio-net
git add Cargo.lock configs docs os platforms virtualization container/test-rtthread-repro.sh run-debug.sh
git commit -m "feat(axvisor): migrate realtime and RT-IPC integration"
```

Expected: formatting and clippy pass; the commit contains no generated logs or Docker reproduction files.

### Task 2: Make The CPU And Guest Topology Match The Approved Design

**Files:**
- Modify: `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml`
- Modify: `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml`
- Modify: `os/axvisor/scripts/generate_linux_vmconfig.sh`
- Modify: `os/axvisor/scripts/test_generate_linux_vmconfig.sh`
- Create: `os/axvisor/scripts/test_task123_topology.sh`

- [ ] **Step 1: Write a failing topology contract**

Create `os/axvisor/scripts/test_task123_topology.sh` with assertions that parse TOML through the existing `axvmconfig` test tooling and require:

```text
Linux: cpu_num=2, phys_cpu_ids=[0,1], phys_cpu_sets=[0b1011,0b1011]
RT-Thread: cpu_num=1, phys_cpu_ids=[2], phys_cpu_sets=[0b0100]
RT-Thread: host_vcpu_idle_policy="busy"
Linux memory: 0x80000000..0x9fffffff (512 MiB)
RT-Thread memory: 0xa0000000..0xafffffff (256 MiB)
Linux MAC: 52:54:00:77:00:01
RT-Thread MAC: 52:54:00:77:00:03
```

The shell contract must also reject any overlap between the RT-Thread mask and either Linux mask.

Run:

```bash
bash os/axvisor/scripts/test_task123_topology.sh
```

Expected: FAIL because Linux currently uses `phys_cpu_sets = [0b11, 0b11]`.

- [ ] **Step 2: Permit Linux scheduling on every non-RTOS pCPU**

Change the Linux base section to:

```toml
[base]
id = 1
name = "linux-net"
guest_type = "virtualized"
cpu_num = 2
guest_tlbi_policy = "vm_scoped"
phys_cpu_ids = [0, 1]
phys_cpu_sets = [0b1011, 0b1011]
```

Keep the RT-Thread base section as:

```toml
[base]
id = 3
name = "rtthread-net"
guest_type = "virtualized"
cpu_num = 1
host_vcpu_idle_policy = "busy"
phys_cpu_ids = [2]
phys_cpu_sets = [0b0100]
```

- [ ] **Step 3: Add guest command-line generation without using outer QEMU `-append`**

Extend `generate_linux_vmconfig.sh` with an optional sixth `GUEST_CMDLINE` argument. Require exactly one template `cmdline` key when the argument is supplied and replace it in the generated VM TOML. The generated value for normal Task 1/2/3 runs is:

```text
console=ttyAMA0 rdinit=/init task2.count=1000 task2.fault=none task3.frames=600 task3.fault=normal
```

Add generator tests for a valid replacement, embedded quote rejection, missing `cmdline`, duplicate `cmdline`, and proof that the outer QEMU command line is not used as the Linux guest command line.

- [ ] **Step 4: Run the topology and generator tests**

Run:

```bash
bash os/axvisor/scripts/test_task123_topology.sh
bash os/axvisor/scripts/test_generate_linux_vmconfig.sh
cargo test -p axvmconfig
cargo test -p axvm --features host-test
```

Expected: all commands pass; Linux is movable only among pCPUs 0, 1, and 3, while RT-Thread remains exclusive to pCPU 2.

- [ ] **Step 5: Commit the topology**

```bash
git add os/axvisor/configs/vms/qemu/aarch64/linux-net.toml os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml os/axvisor/scripts/generate_linux_vmconfig.sh os/axvisor/scripts/test_generate_linux_vmconfig.sh os/axvisor/scripts/test_task123_topology.sh
git commit -m "feat(axvisor): isolate RT-Thread CPU placement"
```

### Task 3: Import Task 3 As An Auditable Guest Application

**Files:**
- Create: `os/axvisor/guests/task3/**` from Git-tracked files at qemu-task3 commit `59e4aaf27614dd80f72190f37fe89eb019353828`
- Modify: `os/axvisor/guests/task3/.gitignore`
- Modify: `os/axvisor/guests/task3/README.md`
- Test: `os/axvisor/guests/task3/tests/test_docs_contract.sh`

- [ ] **Step 1: Verify the source commit and cleanliness**

Run:

```bash
test "$(git -C /home/yfblock/Code/hyper-rtos/qemu-task3 rev-parse HEAD)" = "59e4aaf27614dd80f72190f37fe89eb019353828"
test -z "$(git -C /home/yfblock/Code/hyper-rtos/qemu-task3 status --porcelain)"
test "$(git -C /home/yfblock/Code/hyper-rtos/qemu-task3 ls-files | wc -l)" -eq 126
```

Expected: all checks pass.

- [ ] **Step 2: Import exactly the tracked tree**

Use `git archive 59e4aaf27614dd80f72190f37fe89eb019353828` to extract under `os/axvisor/guests/task3/`. Do not copy `.git`, `build/`, a worktree status, or filesystem-only files.

Run:

```bash
test "$(find os/axvisor/guests/task3 -type f | wc -l)" -eq 126
test ! -d os/axvisor/guests/task3/build
test ! -e os/axvisor/guests/task3/.git
```

Expected: 126 imported files and no 14 GiB build tree.

- [ ] **Step 3: Label standalone evidence and retire standalone launch as final proof**

Update `README.md`, `docs/results/task3-report.md`, and `scripts/run_demo.sh` so that:

```text
- docs/results/evidence is explicitly labeled dual-QEMU migration baseline;
- scripts/run_demo.sh refuses final-evidence mode and points to run_task123.sh;
- no standalone result is described as AxVisor evidence.
```

Keep the deterministic source/model/test assets and baseline logs because they are tracked and auditable.

- [ ] **Step 4: Run imported tests before adaptation**

Run:

```bash
make -C os/axvisor/guests/task3 model
make -C os/axvisor/guests/task3 test
```

Expected: protocol/model/controller tests pass, while RT-IPC path contracts fail until Task 4 points them at AxVisor RT-IPC v2.

- [ ] **Step 5: Commit the source import separately**

```bash
git add os/axvisor/guests/task3
git commit -m "feat(axvisor): import Task 3 AI control application"
```

### Task 4: Adapt Task 3 To AxVisor RT-IPC v2 And UDP 9877

**Files:**
- Modify: `os/axvisor/guests/task3/src/linux/main.c`
- Modify: `os/axvisor/guests/task3/src/linux/rtipc_client.h`
- Modify: `os/axvisor/guests/task3/src/linux/rtipc_client.c`
- Modify: `os/axvisor/guests/task3/src/common/session.c`
- Modify: `os/axvisor/guests/task3/src/rtthread/task3_server.c`
- Modify: `os/axvisor/guests/task3/tests/Makefile`
- Modify: `os/axvisor/guests/task3/scripts/common.sh`
- Modify: `os/axvisor/guests/task3/scripts/build_linux.sh`
- Modify: `os/axvisor/guests/task3/scripts/build_rtthread.sh`
- Create: `os/axvisor/guests/task3/tests/test_axvisor_contract.sh`

- [ ] **Step 1: Write failing RT-IPC v2 and service-separation contracts**

Create `tests/test_axvisor_contract.sh` to require:

```text
RTIPC_HEADER_SIZE == 20
rtipc_header_t contains uint64_t session_id
Task 2 default service port == 9876
Task 3 default client and server port == 9877
Task 3 test/build RTIPC_DIR resolves to ../rt-ipc/common
Task 3 source does not contain a second rt_ipc.c or rt_ipc.h
Task 3 standalone launcher cannot claim AxVisor evidence
```

Run:

```bash
bash os/axvisor/guests/task3/tests/test_axvisor_contract.sh
```

Expected: FAIL because imported Task 3 defaults to 9876 and points to `protocol/c`.

- [ ] **Step 2: Switch every Task 3 default to UDP 9877**

Use these constants:

```c
enum {
    TASK3_SERVER_PORT = 9877,
    TASK3_CLIENT_APPLICATION_TIMEOUT_MS = 500,
    TASK3_CLIENT_RECOVERY_TIMEOUT_MS = 30000,
};
```

and:

```c
enum {
    TASK3_DEFAULT_PORT = 9877,
    TASK3_DEFAULT_FRAMES = 600,
    TASK3_MAX_FRAMES_PER_MODE = 600,
    TASK3_CONNECT_TIMEOUT_MS = 60000,
    TASK3_SETTLING_TOLERANCE_Q15 = 100,
    TASK3_SETTLING_CONSECUTIVE = 3,
};
```

The RT-Thread ready marker must be exactly:

```text
TASK3_RTOS_READY ip=192.168.77.30 port=9877
```

- [ ] **Step 3: Link only the authoritative RT-IPC v2 implementation**

Set the Task 3 root default to:

```sh
RTIPC_DIR=${RTIPC_DIR:-"$TASK3_ROOT/../rt-ipc/common"}
```

Change Task 3 make/build dependencies to `$(RTIPC_DIR)/rt_ipc.c` and `$(RTIPC_DIR)/rt_ipc.h`, with `-I$(RTIPC_DIR)`. Do not import or generate Task 3's old RT-IPC v1 source.

Keep `session.c` as the application adapter over `rtipc_connection_*`; preserve session IDs, stale-session rejection, ACK/retry, duplicate suppression, reconnect, heartbeat, FIN, and action draining from v2.

- [ ] **Step 4: Verify the codec/session/client/server against v2**

Run:

```bash
make -C os/axvisor/guests/rt-ipc/tests clean all test
make -C os/axvisor/guests/task3/tests clean test_task3_protocol test_controller test_session test_linux_cli test_rtthread_server
bash os/axvisor/guests/task3/tests/test_axvisor_contract.sh
```

Expected: all tests pass; the compiled Task 3 session and Linux client directly link AxVisor's 20-byte RT-IPC v2 implementation.

- [ ] **Step 5: Commit the protocol adaptation**

```bash
git add os/axvisor/guests/task3 os/axvisor/guests/rt-ipc
git commit -m "feat(axvisor): run Task 3 over RT-IPC v2"
```

### Task 5: Install Task 1/2/3 In One RT-Thread Image

**Files:**
- Modify: `os/axvisor/patches/rtthread/0000-axvisor-aarch64-port.patch`
- Modify: `os/axvisor/patches/rtthread/apply-rtthread-patches.sh`
- Modify: `os/axvisor/patches/rtthread/test-rtthread-patches.sh`
- Modify: `os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh`
- Modify: `os/axvisor/guests/task3/src/rtthread/SConscript`
- Test: `os/axvisor/guests/task3/tests/test_rtthread_server.c`

- [ ] **Step 1: Write a failing fresh-build contract for all three services**

Extend the patch tests to require these ELF symbols from a clean RT-Thread 5.2.2 checkout:

```text
rtbench_stability
rtipc_server_start
task3_server_start
rt_virtio_net_init
```

Also require `CONFIG_BSP_USING_VIRTIO_NET=y`, `CONFIG_RT_USING_VIRTIO_NET=y`, SAL sockets, a 16-slot UDP receive mailbox, and no virtio-net polling timer symbol.

Run:

```bash
bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
```

Expected: FAIL because the current patch installer does not install Task 3.

- [ ] **Step 2: Add the Task 3 SCons group to the base BSP patch**

Make the patched `applications/SConscript` return both groups:

```python
from building import *

cwd = GetCurrentDir()
src = Glob('*.c') + Glob('*.cpp') + Glob('rt-ipc-test/*.c')
CPPPATH = [cwd]

group = DefineGroup('Applications', src, depend=[''], CPPPATH=CPPPATH)
group += SConscript('task3/SConscript')

Return('group')
```

Keep `task3/SConscript` responsible only for Task 3 sources and fault compile definitions.

- [ ] **Step 3: Install Task 3 without compiling a duplicate RT-IPC implementation**

Extend `apply-rtthread-patches.sh` to copy these files into `bsp/qemu-virt64-aarch64/applications/task3/`:

```text
src/rtthread/task3_server.c
src/rtthread/SConscript
src/common/controller.c
src/common/controller.h
src/common/task3_protocol.c
src/common/task3_protocol.h
src/common/session.c
src/common/session.h
../rt-ipc/common/rt_ipc.h
```

Do not copy `rt_ipc.c`; the existing `rt-ipc-test` group owns that implementation and the linker must contain one copy.

- [ ] **Step 4: Add real server-side fault variants**

Support these SCons environment definitions:

```text
TASK3_FAULT_DROP_STATUS_ONCE=1
TASK3_FAULT_DELAY_START_MS=3000
```

For delayed-server, sleep at the beginning of `task3_server_entry` before emitting `TASK3_RTOS_READY`. Do not delay or poll in the VirtIO-net RX path.

- [ ] **Step 5: Build from a fresh pinned checkout**

Run:

```bash
bash os/axvisor/patches/rtthread/test_prepare_rtthread_source.sh
bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh tmp/task123-rtthread
bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh tmp/task123-rtthread
uv run --with scons scons -C tmp/task123-rtthread/bsp/qemu-virt64-aarch64 -j"$(getconf _NPROCESSORS_ONLN)"
```

Expected: clean source preparation and build pass; symbol and no-polling checks pass.

- [ ] **Step 6: Commit RT-Thread integration**

```bash
git add os/axvisor/patches/rtthread os/axvisor/guests/task3/src/rtthread os/axvisor/guests/task3/tests
git commit -m "feat(axvisor): combine realtime and network RT-Thread services"
```

### Task 6: Build One Linux Image With Task 2 And Task 3

**Files:**
- Modify: `os/axvisor/guests/task3/buildroot/package/task3-linux/task3-linux.mk`
- Modify: `os/axvisor/guests/task3/buildroot/rootfs-overlay/etc/init.d/S99task3`
- Modify: `os/axvisor/guests/task3/scripts/build_linux.sh`
- Create: `os/axvisor/guests/linux-net/init-task123`
- Create: `os/axvisor/scripts/test_task123_linux_image_contract.sh`

- [ ] **Step 1: Write the failing combined-image contract**

Require the generated initramfs to contain:

```text
/bin/rtipic-client
/usr/bin/task3-linux
/opt/task3/line-follow.y4m
/opt/task3/truth.csv
/init
```

Require `/init` to configure only `192.168.77.11/24`, report two online CPUs, run Task 2 on 9876, run Task 3 on 9877, propagate each exit status, and never power off before both requested workloads finish.

Run:

```bash
bash os/axvisor/scripts/test_task123_linux_image_contract.sh
```

Expected: FAIL because the imported rootfs contains Task 3 only.

- [ ] **Step 2: Build and install both Linux applications**

Extend `build_linux.sh` to cross-compile the canonical Task 2 client from `os/axvisor/guests/rt-ipc/linux` and install it alongside `task3-linux`. Keep model/video/truth generation and SHA-256 validation unchanged.

The combined init path must emit these markers:

```text
LINUX_SMP_READY configured=2 online=0-1 nproc=2
TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
TASK2_LINUX_BEGIN port=9876
TASK2_LINUX_END status=PASS
TASK3_LINUX_READY ip=192.168.77.11 peer=192.168.77.30:9877
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
```

- [ ] **Step 3: Parse workload controls only from the guest FDT command line**

Support:

```text
task2.count=<positive integer>
task2.fault=none|reliability
task3.frames=1..600
task3.fault=normal|drop-control|drop-status|duplicate-frame|delayed-server|malformed
```

Reject malformed values before launching applications. Map client-side Task 3 profiles to `--drop-tx-seq 2`, `--duplicate-frame-once`, or `--malformed-once`; server-side profiles select the matching RT-Thread image.

- [ ] **Step 4: Build and inspect the image**

Run:

```bash
make -C os/axvisor/guests/rt-ipc/linux clean all
make -C os/axvisor/guests/task3 model
os/axvisor/guests/task3/scripts/build_linux.sh
bash os/axvisor/scripts/test_task123_linux_image_contract.sh
```

Expected: Linux `Image` and `rootfs.cpio` exist; all five required paths and markers pass the contract.

- [ ] **Step 5: Commit the combined image flow**

```bash
git add os/axvisor/guests/task3 os/axvisor/guests/linux-net/init-task123 os/axvisor/scripts/test_task123_linux_image_contract.sh
git commit -m "feat(axvisor): build combined Linux workload image"
```

### Task 7: Implement One Owned AxVisor Runner

**Files:**
- Create: `os/axvisor/scripts/run_task123.sh`
- Create: `os/axvisor/scripts/test_task123_runner_lifecycle.sh`
- Create: `os/axvisor/scripts/verify_task123_results.sh`
- Create: `os/axvisor/scripts/test_task123_result_gate.sh`
- Reuse: `os/axvisor/scripts/run_until_log_marker.sh`
- Reuse: `os/axvisor/scripts/apply_qemu_realtime_controls.sh`
- Reuse: `os/axvisor/scripts/generate_linux_vmconfig.sh`
- Reuse: `os/axvisor/scripts/generate_rtthread_vmconfig.sh`

- [ ] **Step 1: Write failing runner ownership and safety tests**

The lifecycle test must verify:

```text
- exactly one qemu-system-aarch64 child is started per run;
- the QEMU child boots AxVisor, not a guest kernel directly;
- cargo xtask axvisor build receives exactly Linux and RT-Thread VM configs;
- all output paths are canonical, writable, distinct, and outside source inputs;
- cleanup kills/waits only recorded child PIDs;
- pkill, killall, process-name matching, multicast socket networking, TAP, and host bridge commands are absent;
- TERM, timeout, marker failure, build failure, and result-gate failure preserve logs and return nonzero;
- normal completion records QEMU, AxVisor, Linux, initramfs, RT-Thread, VM config, model, and protocol hashes.
```

Run:

```bash
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
```

Expected: FAIL because `run_task123.sh` does not exist.

- [ ] **Step 2: Implement the runner modes and bounded phases**

Support these explicit modes:

```text
--mode smoke --task2-count 1000 --task3-frames 3
--mode realtime-suite --rtbench-samples 1000 --task2-count 1000
--mode stability --seconds 300 --task2-count 30000
--mode task3 --task3-frames 600
--mode task3-fault --task3-fault <profile> --task3-frames 3
```

Each mode performs: dependency verification, image build/selection, immutable VM-config generation, `cargo xtask axvisor build`, AxVisor binary conversion, one QEMU launch, host realtime controls, marker collection, scoped cleanup, result gating, and manifest output.

- [ ] **Step 3: Require architecture and application markers**

The runner must fail closed unless it observes exactly one of every applicable marker:

```text
LINUX_SMP_READY configured=2
TASK123_LINUX_NET_READY
RTIPC_SERVER_READY ip=192.168.77.30 port=9876
TASK3_RTOS_READY ip=192.168.77.30 port=9877
TASK2_LINUX_END status=PASS
TASK3_LINUX_END status=PASS
RTBENCH_END status=PASS
RTBENCH_STABILITY_END status=PASS
```

Reject panic/assert/fatal markers, duplicate summaries, missing samples, nonzero QEMU exit, and unclean application shutdown.

- [ ] **Step 4: Add structured Task 3 extraction and gating**

Strip only the `[VM 1] ` console prefix before extracting `TASK3_FRAME_CSV=` and `TASK3_SUMMARY_JSON=`. Reuse `task3/scripts/summarize.py` and `summarize_faults.py`; do not parse metrics with an ad hoc replacement.

- [ ] **Step 5: Run lifecycle and synthetic result-gate tests**

Run:

```bash
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
bash os/axvisor/scripts/test_task123_result_gate.sh
bash os/axvisor/scripts/test_run_until_log_marker.sh
bash os/axvisor/scripts/test_qemu_realtime_controls.sh
```

Expected: all normal and failure fixtures pass and owned fake PIDs are fully reaped.

- [ ] **Step 6: Commit the runner**

```bash
git add os/axvisor/scripts/run_task123.sh os/axvisor/scripts/test_task123_runner_lifecycle.sh os/axvisor/scripts/verify_task123_results.sh os/axvisor/scripts/test_task123_result_gate.sh
git commit -m "feat(axvisor): add integrated Task 1 2 3 runner"
```

### Task 8: Run Static, Build, And Smoke Gates

**Files:**
- Modify only files implicated by deterministic failures
- Output: `tmp/task123-smoke-*`

- [ ] **Step 1: Run Rust formatting, tests, and targeted clippy**

```bash
cargo fmt --all --check
cargo test -p axvmconfig
cargo test -p arm_vcpu
cargo test -p axvm --features host-test
cargo test -p axvirtio-net
cargo xtask clippy --package arm_vcpu
cargo xtask clippy --package axvmconfig
cargo xtask clippy --package axvm
cargo xtask clippy --package axvirtio-net
```

Expected: all commands pass with no suppressed warning added for this work.

- [ ] **Step 2: Run C, Python, shell, and fresh-source tests**

```bash
make -C os/axvisor/guests/rt-ipc/tests clean all test
make -C os/axvisor/guests/task3 model
make -C os/axvisor/guests/task3 test
bash os/axvisor/patches/rtthread/test_prepare_rtthread_source.sh
bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
bash os/axvisor/scripts/test_host_realtime_contract.sh
bash os/axvisor/scripts/test_task123_topology.sh
bash os/axvisor/scripts/test_task123_linux_image_contract.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
bash os/axvisor/scripts/test_task123_result_gate.sh
```

Expected: every command exits 0.

- [ ] **Step 3: Run one integrated smoke boot**

```bash
os/axvisor/scripts/run_task123.sh --mode smoke --task2-count 1000 --task3-frames 3 --output tmp/task123-smoke
```

Expected: Linux reports two online vCPUs; both virtual NICs initialize; Task 2 exchanges all three payload classes; Task 3 completes 3 FIXED and 3 AI frames; RT-Thread stays on pCPU 2; all gates pass.

- [ ] **Step 4: Fix only evidence-backed smoke failures with regression tests**

For each failure, first add the smallest deterministic test to the owning module or script, run it to observe failure, apply the minimal fix, rerun that test, then rerun the smoke command. Do not add polling to VirtIO-net RX, broad sleeps to hide races, or success markers before postconditions.

- [ ] **Step 5: Commit smoke fixes**

```bash
git add os virtualization platforms configs docs
git commit -m "fix(axvisor): stabilize integrated guest startup"
```

Expected: skip this commit when no smoke fix is necessary.

### Task 9: Collect Task 1 And Task 2 Acceptance Evidence

**Files:**
- Output: `tmp/task123-results/realtime-suite/`
- Output: `tmp/task123-results/stability-300s/`
- Modify: `docs/docs/build/axvisor/rtthread-realtime-report.md`

- [ ] **Step 1: Collect the realtime suite under concurrent network load**

```bash
os/axvisor/scripts/run_task123.sh --mode realtime-suite --rtbench-samples 1000 --task2-count 1000 --output tmp/task123-results/realtime-suite
```

Expected: periodic jitter, callback execution, preemption, SGI interrupt response, and network RTT all report p50/p95/p99/p99.9/max and threshold misses; Task 2 reports 1000/1000 for each payload class.

- [ ] **Step 2: Collect the 300-second stability run**

```bash
os/axvisor/scripts/run_task123.sh --mode stability --seconds 300 --task2-count 30000 --output tmp/task123-results/stability-300s
```

Expected: `299999/299999`, zero missing periodic samples, three Task 2 classes at `30000/30000`, no guest errors, and complete CPU-load/artifact/timing manifests.

- [ ] **Step 3: Compare against same-QEMU pre-integration evidence**

Use the report tooling to compare p50, p95, and p99. Reject a repeatable regression greater than 10%. Report max and `miss_1ms` separately; if either worsens materially, repeat once before attributing the result.

- [ ] **Step 4: Update the realtime report with current-head evidence**

Add exact commands, duration, host/QEMU versions, CPU topology, image hashes, workload counts, CPU load distribution, native RT-Thread baseline, percentile tables, max/miss data, and the QEMU TCG limitation. Label older evidence as historical and do not overwrite raw files.

- [ ] **Step 5: Commit accepted Task 1/2 results**

```bash
git add docs/docs/build/axvisor/rtthread-realtime-report.md
git commit -m "docs(axvisor): record integrated realtime and network results"
```

### Task 10: Collect Task 3 Normal And Fault Evidence Under AxVisor

**Files:**
- Output: `tmp/task123-results/task3-normal/`
- Output: `tmp/task123-results/task3-faults/<profile>/`
- Create: `docs/docs/build/axvisor/task123-test-report.md`

- [ ] **Step 1: Run the complete 600+600 frame control loop**

```bash
os/axvisor/scripts/run_task123.sh --mode task3 --task3-frames 600 --output tmp/task123-results/task3-normal
```

Expected: exactly 600 FIXED and 600 AI rows, request success at least 99.5%, model accuracy at least 95%, and AI mean tracking error improvement at least 30%.

- [ ] **Step 2: Run all five real AxVisor fault profiles**

```bash
for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
  os/axvisor/scripts/run_task123.sh --mode task3-fault --task3-fault "$profile" --task3-frames 3 --output "tmp/task123-results/task3-faults/$profile"
done
python3 os/axvisor/guests/task3/scripts/summarize_faults.py --suite-dir tmp/task123-results/task3-faults
```

Expected: all profiles recover or reject as designed; no duplicate control application occurs; malformed packets do not alter control state.

- [ ] **Step 3: Produce the AxVisor-only Task 3 report**

Report inference, same-side round-trip, RTOS processing, and end-to-end distributions; request success, timeouts, retries, duplicates, application errors, reconnections, throughput, accuracy, mean/p95/max control error, and settling behavior. Explain that Linux measures RTT with `CLOCK_MONOTONIC_RAW`, RT-Thread processing uses the architectural counter, and cross-guest one-way latency is not claimed without synchronized clocks.

- [ ] **Step 4: Commit accepted Task 3 results**

```bash
git add docs/docs/build/axvisor/task123-test-report.md
git commit -m "docs(axvisor): record AxVisor AI control results"
```

### Task 11: Write Chinese Reproduction Documentation And Final Audit

**Files:**
- Create: `docs/docs/build/axvisor/task123-reproduction-cn.md`
- Modify: `docs/docs/build/axvisor/task123-test-report.md`
- Modify: `docs/docs/build/axvisor/rtthread-realtime-report.md`
- Test: `os/axvisor/scripts/test_task123_docs_contract.sh`

- [ ] **Step 1: Write a failing documentation contract**

Require the Chinese guide to include exact pinned revisions, host packages, `uv`/SCons use, model build, RT-Thread build, Linux build, AxVisor build, every runner command, artifact locations, CPU masks, memory ranges, VirtIO MMIO/IRQ routing, MAC/IP/ports, no gateway/NAT/firewall rule, result collection, expected markers, failure diagnosis, and raw-data hash verification.

Run:

```bash
bash os/axvisor/scripts/test_task123_docs_contract.sh
```

Expected: FAIL until the guide exists.

- [ ] **Step 2: Write the Chinese reproduction guide from verified commands**

Use only commands already executed successfully in Tasks 8-10. State that Docker scheduling adds host noise and is not the authoritative realtime environment. State that inter-guest application traffic is exclusively VirtIO-net/IPv4/UDP/RT-IPC v2; shared memory, HyperCall, raw MMIO, vsock, TAP, and host-side relays are not the main channel.

- [ ] **Step 3: Map every requirement to evidence**

Add a table with one row per Task 1/2/3 requirement and columns:

```text
requirement | implementation/config | verification command | accepted artifact/marker | status
```

Do not report 100% for any task lacking current-head evidence.

- [ ] **Step 4: Run the final complete verification set**

```bash
cargo fmt --all --check
cargo test -p axvmconfig
cargo test -p arm_vcpu
cargo test -p axvm --features host-test
cargo test -p axvirtio-net
make -C os/axvisor/guests/rt-ipc/tests clean all test
make -C os/axvisor/guests/task3 test
bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
bash os/axvisor/scripts/test_host_realtime_contract.sh
bash os/axvisor/scripts/test_rtbench_suite_gate.sh
bash os/axvisor/scripts/test_rtbench_stability_gate.sh
bash os/axvisor/scripts/test_rtipc_result_gate.sh
bash os/axvisor/scripts/test_rtipc_runner_lifecycle.sh
bash os/axvisor/scripts/test_task123_topology.sh
bash os/axvisor/scripts/test_task123_linux_image_contract.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
bash os/axvisor/scripts/test_task123_result_gate.sh
bash os/axvisor/scripts/test_task123_docs_contract.sh
```

Expected: every command exits 0.

- [ ] **Step 5: Audit the original checkout without modifying it**

Run read-only commands:

```bash
git -C /home/yfblock/Code/hyper-rtos/tgoskits rev-parse HEAD
git -C /home/yfblock/Code/hyper-rtos/tgoskits status --porcelain=v1 | sha256sum
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --binary | sha256sum
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --cached --binary | sha256sum
git -C /home/yfblock/Code/hyper-rtos/tgoskits status --porcelain=v1 | wc -l
```

Compare with the design-spec fingerprints. Report every difference as external source-tree drift; do not reset, clean, stage, or repair the original checkout.

- [ ] **Step 6: Review committed scope and finish the branch**

```bash
git status --short
git log --oneline cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35..HEAD
git diff --stat cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35..HEAD
git diff --check cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35..HEAD
```

Expected: worktree is clean, no debug/generated/Docker side-branch files are present, and `git diff --check` is silent.

- [ ] **Step 7: Commit the reproduction and completion audit**

```bash
git add docs/docs/build/axvisor/task123-reproduction-cn.md docs/docs/build/axvisor/task123-test-report.md docs/docs/build/axvisor/rtthread-realtime-report.md os/axvisor/scripts/test_task123_docs_contract.sh
git commit -m "docs(axvisor): add Task 1 2 3 reproduction guide"
```

Expected: final branch contains source, tests, configuration, reproducible commands, and current-head evidence, while the original checkout remains untouched by this branch.
