# StarryOS Task 1/2/3 Guest Replacement Design

**Goal:** Replace the existing two-vCPU Linux application guest in the AxVisor Task 1/2/3 reproduction with an AArch64 StarryOS guest while preserving the RT-Thread network peer, real-time host policy, and reproducible result gates.

## Scope

The new branch is based on `origin/feat/axvisor-task123` and lives in the
`starryos-replace` worktree. Existing Linux and RT-Thread branches remain
unchanged. The replacement must preserve:

- one AxVisor instance with a two-vCPU application guest and one RT-Thread guest;
- RT-Thread CPU affinity and host timer/idle policies;
- virtio-net as the only guest-to-guest data channel;
- RT-IPC TCP framing, acknowledgements, retry and duplicate handling;
- Task 3 AI inference, control output and status return;
- RTBench and result-gate evidence.

The first implementation target is the Task 2 network client and Task 1
two-vCPU boot marker. Task 3 is enabled only after those markers pass.

## Current constraints

StarryOS already builds for `aarch64-unknown-none-softfloat` and includes the
`ax-driver/virtio-net` feature. Its normal root filesystem path calls
`ax_fs_ng::root::init_root_from_rdif_sources`, which requires a block device.
AxVisor currently provides a configured virtual `virtio-net` model but no
configured virtual `virtio-blk` model. Therefore a Linux-style initramfs cannot
be assumed to work, and a new guest must not silently fall back to the old
Linux image.

## Selected architecture

Use a StarryOS `virtualized` guest with a two-vCPU VM configuration and the
existing AxVisor internal virtio-net switch. Add an explicit StarryOS
`axvisor-guest` boot feature that installs a small read-only in-memory root
filesystem populated from a build-time archive containing only the required
Task 2/3 binaries, scripts and protocol assets. The normal block-backed root
filesystem remains the default for ordinary StarryOS QEMU and board boots.

This boundary keeps the change focused: no virtio-blk implementation is added
to AxVisor, no passthrough PCI device is introduced, and the network path stays
the same as the Linux baseline. The guest-specific root provider is selected
only by an explicit feature/configuration and fails closed if the archive is
missing or malformed.

## Guest contract

The generated Starry guest must emit:

```text
STARRY_SMP_READY configured=2 online=0-1 nproc=2
STARRY_NET_READY ip=192.168.77.11 peer=192.168.77.30
TASK2_LINUX_BEGIN port=9876
TASK2_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
```

The existing RT-Thread markers remain authoritative for RTOS behavior.
`TASK3_LINUX_END` and the existing Task 3 JSON summary are required in the
full suite. The result manifest records the guest kind as `starryos` and the
SHA-256 of the Starry kernel and generated guest archive.

## Build and runtime layout

- `os/StarryOS/configs/axvisor/task123-aarch64.toml`: Starry guest build
  feature set and two-vCPU target.
- `os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml`: VM memory,
  vCPU affinity, guest memory load address and virtual network device.
- `os/axvisor/guests/starryos-task123/`: Starry guest launcher and archive
  preparation scripts.
- `os/axvisor/scripts/run_task123.sh`: selectable guest artifact/config input
  and marker/result metadata; Linux remains the default compatibility path.

The Starry guest uses the same `192.168.77.11/24` address and RT-Thread
`192.168.77.30` peer as the Linux guest. It must use TCP ports 9876 and 9877
for the existing RT-IPC and Task 3 applications.

## Verification

Verification is staged:

1. Static contract test rejects a missing Starry artifact, wrong vCPU count,
   missing virtio-net device, or accidental Linux kernel reference.
2. Native StarryOS AArch64 build produces the ELF and binary artifact.
3. Single StarryOS QEMU boot proves the kernel can initialize the selected
   guest root and network driver.
4. AxVisor smoke proves two online vCPUs and Task 2 bidirectional TCP.
5. Full suite proves Task 3 and RTBench without changing the Linux baseline.
6. Stability run records long-duration Starry guest behavior separately from
   the existing Linux result directories.

Any stage that has not passed is reported as incomplete; a build-only result
is not considered a Linux replacement.
