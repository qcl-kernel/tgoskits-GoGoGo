# StarryOS Task 1/2/3 Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-vCPU Linux application guest in the AxVisor Task 1/2/3 setup with a bootable two-vCPU StarryOS guest that communicates with the existing RT-Thread guest over virtio-net and runs the existing RT-IPC and AI-control applications.

**Architecture:** StarryOS remains a normal AArch64 virtualized AxVisor guest and reuses AxVisor's existing virtual virtio-net switch. An explicit `axvisor-guest` feature selects a build-time embedded CPIO root filesystem; ordinary StarryOS board and QEMU builds retain their existing block-backed root filesystem. Existing Linux Task 1/2/3 remains the default compatibility path until the StarryOS result gates pass.

**Tech Stack:** Rust/no_std, ArceOS/StarryOS, ax-fs-ng VFS, newc CPIO, AxVisor/AxVM, AArch64 QEMU virt, virtio-net, C/Linux ABI Task 2 and Task 3 applications.

---

### Task 1: Static StarryOS guest contract

**Files:**
- Create: `os/StarryOS/configs/axvisor/task123-aarch64.toml`
- Create: `os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml`
- Test: `os/axvisor/guests/starryos-task123/tests/test_contract.sh`

- [ ] Run the existing contract test and retain the expected missing-config failure.
- [ ] Add an AArch64 StarryOS build configuration with `axvisor-guest`, virtio-net, and two-CPU support.
- [ ] Add a virtualized two-vCPU AxVisor VM configuration using the existing Linux guest CPU pool and virtual NIC identity.
- [ ] Run `os/axvisor/guests/starryos-task123/tests/test_contract.sh` and require `starryos task123 contract: PASS`.
- [ ] Commit the configuration contract.

### Task 2: Embedded CPIO root provider

**Files:**
- Create: `fs/ax-fs-ng/src/embedded.rs`
- Modify: `fs/ax-fs-ng/src/lib.rs`
- Modify: `fs/ax-fs-ng/Cargo.toml`
- Modify: `os/arceos/modules/axruntime/src/fs/mod.rs`
- Modify: `os/arceos/modules/axruntime/src/fs/block.rs`
- Modify: `os/arceos/modules/axruntime/Cargo.toml`
- Test: `fs/ax-fs-ng/tests/embedded_root.rs`

- [ ] Write parser tests for valid directories, regular files, symlinks, executable mode bits, malformed headers, traversal paths, duplicate entries, and truncated payloads.
- [ ] Run the focused test and verify that the missing embedded-root parser fails.
- [ ] Implement a bounded newc CPIO parser and read-only VFS tree without block-device dependencies.
- [ ] Add a public root initialization function that installs an arbitrary validated `Filesystem` as the root context.
- [ ] Split AxRuntime filesystem-runtime installation from block-root selection and select embedded CPIO only through an explicit feature.
- [ ] Run focused and ax-fs-ng regression tests.
- [ ] Commit the embedded root provider.

### Task 3: StarryOS AxVisor guest build

**Files:**
- Modify: `os/StarryOS/starryos/Cargo.toml`
- Modify: `os/StarryOS/starryos/src/main.rs`
- Modify: `os/StarryOS/kernel/Cargo.toml`
- Create: `os/axvisor/guests/starryos-task123/build_rootfs.sh`
- Create: `os/axvisor/guests/starryos-task123/build.sh`
- Extend: `os/axvisor/guests/starryos-task123/tests/test_contract.sh`

- [ ] Extend the contract test to require deterministic rootfs generation, an executable `/init`, no block driver, and two CPUs.
- [ ] Verify the extended contract fails before implementation.
- [ ] Add `axvisor-guest` feature propagation and an AxVisor-specific init command.
- [ ] Build a deterministic newc archive from an explicit manifest and reject missing or dynamic AArch64 executables.
- [ ] Build StarryOS with `SMP=2`, the embedded archive, and no NVMe/virtio-blk dependency.
- [ ] Validate the ELF entry, raw binary, archive members, and hashes.
- [ ] Commit the guest build path.

### Task 4: Minimal two-vCPU boot and virtio-net probe

**Files:**
- Create: `os/axvisor/guests/starryos-task123/rootfs/init`
- Create: `os/axvisor/guests/starryos-task123/src/net_probe.c`
- Create: `os/axvisor/configs/board/qemu-aarch64-starryos-task123.toml`
- Create: `os/axvisor/configs/qemu/qemu-aarch64-starryos-task123.toml`
- Create: `os/axvisor/guests/starryos-task123/tests/test_boot_markers.sh`

- [ ] Write a log-marker test requiring `STARRY_SMP_READY` and `STARRY_NET_READY`.
- [ ] Verify the marker test fails with no guest run.
- [ ] Add the minimal init and static network probe using StarryOS Linux socket ABI.
- [ ] Build AxVisor with StarryOS and RT-Thread images embedded.
- [ ] Boot under `qemu-system-aarch64` and capture per-guest console logs.
- [ ] Require two online StarryOS CPUs and a successful bidirectional TCP probe to RT-Thread.
- [ ] Commit the minimal boot milestone.

### Task 5: Task 2 and Task 3 application integration

**Files:**
- Modify: `os/axvisor/guests/starryos-task123/rootfs/init`
- Modify: `os/axvisor/guests/starryos-task123/build_rootfs.sh`
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/verify_task123_results.sh`
- Add tests under: `os/axvisor/guests/starryos-task123/tests/`

- [ ] Add a contract test that requires the RT-IPC client, Task 3 application, model/video inputs, and Starry-specific markers in the archive.
- [ ] Verify the contract fails before staging the applications.
- [ ] Reuse the existing AArch64 Linux ABI Task 2/3 binaries and assets in the embedded archive.
- [ ] Add `--app-guest linux|starryos` to the runner while retaining `linux` as the default.
- [ ] Add StarryOS artifact hashes and guest kind to the manifest and result gate.
- [ ] Run Task 2 normal/reliability tests and Task 3 normal/fault suites.
- [ ] Commit the complete application guest integration.

### Task 6: Regression, real-time, and stability verification

**Files:**
- Modify: `docs/axvisor-task123-reproduction-cn.md` or the active Task 1/2/3 reproduction document
- Modify: the active Task 1/2/3 result report

- [ ] Build and smoke-test the unchanged Linux default path.
- [ ] Run the StarryOS smoke, realtime-suite, Task 3, Task 3 fault, and stability modes.
- [ ] Compare RT-Thread jitter, interrupt latency, network RTT, success rate, and throughput against the Linux baseline.
- [ ] Record commands, hashes, environment, duration, raw result paths, and any platform limitations.
- [ ] Run formatting, focused tests, full relevant shell-contract suite, `git diff --check`, and inspect the final diff.
- [ ] Commit documentation and verification evidence, then push `feat/starryos-task123` only when explicitly requested.
