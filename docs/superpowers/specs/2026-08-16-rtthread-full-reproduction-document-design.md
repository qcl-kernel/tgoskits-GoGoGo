# AxVisor Linux + RT-Thread Full Reproduction Document Design

## Goal

Create a standalone Chinese runbook that lets a developer reproduce the current
AxVisor configuration from a fresh Ubuntu 24.04 x86_64 host. The runbook must
cover the 2-vCPU Linux guest, CPU-pinned RT-Thread guest, VirtIO-net/UDP/RT-IPC
communication, realtime benchmarks, native RT-Thread baseline, evidence
collection, and acceptance criteria.

## Audience And Starting State

The primary reader is a developer starting from a fresh Ubuntu 24.04 x86_64
machine and a checkout of this repository. The document must not assume that
QEMU, Rust, cross toolchains, `uv`, SCons, RT-Thread sources, guest images, or
benchmark artifacts are already present.

Where the repository cannot build an external artifact from source, the runbook
must state the pinned source or download location, expected destination, and a
command that verifies the artifact before testing.

## Document Location

The final runbook will be written to:

`docs/docs/build/axvisor/rtthread-reproduction.md`

The existing realtime report remains the authoritative result history. The new
runbook links to it but does not duplicate historical iteration narratives.

## Structure

The runbook will contain these ordered sections:

1. Scope, tested topology, and the distinction between reproduction and hard
   realtime certification.
2. Pinned repository, RT-Thread, QEMU, guest image, and toolchain identities.
3. Fresh Ubuntu package installation and user-level Rust/`uv` setup.
4. Checkout validation and preflight commands.
5. Pinned RT-Thread source preparation, patch application, invariant checks,
   and `uv`-managed SCons build.
6. Focused Rust, shell, RT-IPC C, and AxVisor AArch64 tests.
7. Full system launch with one 2-vCPU Linux guest and one CPU-pinned RT-Thread
   guest.
8. VirtIO-net/IP/UDP/RT-IPC network validation.
9. The 1,000-sample realtime suite, 300-second stability run, and native
   RT-Thread baseline.
10. Artifact-matched same-QEMU comparison rules for performance regression.
11. Logs, artifact manifests, SHA-256 evidence, and result extraction.
12. Acceptance criteria and common failure diagnosis.

## Execution Model

Existing repository scripts remain the executable source of truth. The runbook
will not add a second wrapper script. It will provide copyable commands with
explicit environment variables and output paths, primarily using:

- `os/axvisor/patches/rtthread/prepare_rtthread_source.sh`
- `os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh`
- `os/axvisor/scripts/run_rtipc_test.sh`
- `os/axvisor/scripts/run_rtthread_native_baseline.sh`
- the existing result gates and Cargo test entry points

Commands will be split into a short preflight, a fast functional verification,
and the full long-running acceptance flow. Expected duration and output files
will be stated before long-running commands.

## System Contract

The document must identify the reproduced system as:

- Linux VM: 2 vCPUs, non-realtime physical CPU set `{0,1}`.
- RT-Thread VM: 1 vCPU pinned to physical CPU 2 with busy idle policy.
- Linux: `192.168.77.11/24`, MAC `34:54:00:4d:00:01`.
- RT-Thread: `192.168.77.30/24`, MAC `34:54:00:4d:00:03`.
- RT-IPC: UDP port 9876 over virtual VirtIO-net.
- Main data channel: IP networking only; no shared-memory, hypercall, vsock, or
  raw-MMIO application transport.

## Acceptance Criteria

Functional acceptance requires:

- Linux reports `LINUX_SMP_READY configured=2 online=0-1 nproc=2`.
- RT-Thread initializes lwIP and the RT-IPC server.
- 64, 256, and 1024-byte payload tests complete at the requested count.
- Request, protocol, application, and transport timeout/error counters are zero.
- QEMU and the Linux client exit successfully.

Realtime acceptance requires:

- The requested suite or stability sample count is complete with no missing
  samples.
- P50, P95, P99, P99.9, maximum latency, and `miss_1ms` are collected.
- Cleanup regression is evaluated against an artifact-matched, same-QEMU
  control. A repeatable cleaned-run P50/P95/P99 increase above 10 percent is a
  failure.
- Native RT-Thread results are reported as a platform baseline, not as a
  byte-for-byte equivalent of the virtualized environment.

The runbook must explicitly state that QEMU TCG on a general-purpose Ubuntu
host does not establish a certified hardware worst-case execution-time bound.

## Verification

Before delivery, every referenced path and environment variable will be checked
against the current scripts. Shell snippets will be syntax-checked where
possible, internal links and pinned commits will be validated, and the
documented fast verification commands will be run. Long-running results will be
linked to the existing verified report rather than rerun solely for prose edits.

## Non-Goals

- Adding a new orchestration script.
- Replacing the existing realtime report.
- Claiming hard realtime certification from QEMU TCG measurements.
- Covering task three AI inference and control-loop integration.
- Staging or committing unrelated changes already present in the shared
  worktree or index.
