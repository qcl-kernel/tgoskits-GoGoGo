# AxVisor Linux + RT-Thread Docker Reproduction Design

## Goal

Provide a Docker-based, standalone Chinese runbook for reproducing the current
AxVisor system from a fresh Ubuntu 24.04 x86_64 host. The reproduced system has
one 2-vCPU Linux guest, one CPU-pinned RT-Thread guest, VirtIO-net/UDP/RT-IPC
communication, realtime benchmarks, and a native RT-Thread baseline.

Docker fixes the build and runtime dependencies. It does not remove host
scheduler, cgroup, thermal, or frequency-scaling effects, so container results
must be identified separately from the existing host results.

## Deliverables

Implementation adds:

- `container/Dockerfile.rtthread-repro`: a dedicated reproduction image.
- `compose.rtthread-repro.yml`: the supported container runtime contract.
- `docs/docs/build/axvisor/rtthread-reproduction.md`: the Chinese runbook.
- Docker-specific result evidence and a report update when a full benchmark is
  executed.

The existing `container/Dockerfile` and CI image behavior are not changed.

## Host Starting State

The reader starts with:

- Ubuntu 24.04 x86_64.
- Docker Engine with the Compose plugin.
- At least four host logical CPUs that can be dedicated to the run.
- At least 16 GiB host RAM and 40 GiB free disk space.
- A checkout of this repository.

The host does not need Rust, QEMU, `uv`, SCons, RT-Thread, an AArch64
toolchain, or `/dev/kvm`.

## Image Design

The dedicated image extends the project CI base image at an immutable digest.
The implementation records that digest in the Dockerfile or its adjacent lock
metadata. The image adds only reproduction-specific dependencies:

- QEMU 11.0.2 AArch64 softmmu, built from a SHA-256-verified source archive.
- `uv` at a fixed version.
- `scons`, invoked through `uv` rather than installed globally.
- `socat`, `sysstat`, `util-linux`, GNU AArch64 binutils/compiler support, and
  other tools required by the existing scripts.

The final image exposes version labels for the base image, QEMU, `uv`, and the
pinned RT-Thread commit. The build must fail if downloaded source checksums do
not match.

QEMU uses TCG. The container does not receive `/dev/kvm`, host networking,
`--privileged`, or access to unrelated host devices.

## Compose Runtime Contract

Compose is the supported entry point. It provides:

- `SYS_NICE` only, so the existing `uclampset` command can control the QEMU
  process and its threads.
- An init process for reliable child reaping.
- No CPU quota and no memory cgroup limit.
- A configurable host CPU set through `RT_REPRO_CPUSET`, defaulting to `0-3`.
- The repository mounted at `/workspace`.
- Named caches for Cargo, Git, and downloaded/build artifacts where compatible
  with the existing scripts.
- A host-visible output directory dedicated to reproduction logs.
- A fixed working directory and explicit environment variables.

The runbook must instruct the user to select four lightly loaded CPUs. A Docker
cpuset constrains placement but does not isolate those CPUs from host services;
the preflight records host load and warns when the selected CPUs are busy.

## System Contract

The container launches the existing QEMU/AxVisor topology:

- Linux VM: 2 vCPUs assigned to AxVisor physical CPU set `{0,1}`.
- RT-Thread VM: 1 vCPU pinned to AxVisor physical CPU 2 with busy idle policy.
- Linux: `192.168.77.11/24`, MAC `34:54:00:4d:00:01`.
- RT-Thread: `192.168.77.30/24`, MAC `34:54:00:4d:00:03`.
- RT-IPC: UDP port 9876 over virtual VirtIO-net.
- Main data channel: IP networking only; no shared-memory, hypercall, vsock, or
  raw-MMIO application transport.

The virtual network is internal to QEMU/AxVisor. Docker host networking is not
required for guest-to-guest traffic.

## Runbook Structure

The runbook contains these ordered sections:

1. Scope, topology, and Docker measurement limitations.
2. Host Docker installation and resource preflight.
3. Repository revision and immutable dependency identities.
4. Image build and image-version verification.
5. Compose configuration, cpuset selection, caches, and output ownership.
6. Pinned RT-Thread preparation, patch verification, and `uv`/SCons build.
7. Rust, shell, RT-IPC C, and AxVisor AArch64 tests.
8. Short system smoke test.
9. 1,000-sample suite and network acceptance.
10. 300-second stability run and native RT-Thread baseline.
11. Artifact-matched, same-container A/B comparison method.
12. Logs, manifests, SHA-256 evidence, result extraction, and troubleshooting.

Existing repository scripts remain the executable source of truth. No second
benchmark wrapper is introduced.

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
- Cleanup regression uses the same image digest, cpuset, QEMU binary, guest
  artifacts, workload, and container options for control and cleaned runs.
- A repeatable cleaned-run P50/P95/P99 increase above 10 percent relative to
  the same-container control fails the regression gate.
- Maximum latency and `miss_1ms` are retained and repeated when worse, but one
  isolated maximum does not by itself attribute a cleanup regression.

Docker overhead is assessed separately by comparing equivalent host and
container runs on the same machine. A P50/P95/P99 increase up to 10 percent is
the target tolerance, not a universal guarantee. If it is exceeded, the
container data remains valid as a separate environment but cannot be described
as a low-impact reproduction of the host run without further tuning.

QEMU TCG in Docker on a general-purpose Ubuntu host does not establish a
certified hardware worst-case execution-time bound.

## Verification

Implementation verification proceeds in increasing cost:

1. Lint the Dockerfile, render the Compose model, and check documented paths.
2. Build the image without using unpinned runtime package installation.
3. Verify tool versions, QEMU AArch64 availability, `SYS_NICE`, cpuset, and
   writable cache/output paths inside the container.
4. Run the existing shell contracts, Rust tests, RT-IPC C tests, fresh
   RT-Thread patch/build test, and AxVisor AArch64 `axtest` in the container.
5. Run a short end-to-end system smoke test.
6. Run the 1,000-sample suite.
7. When host resources permit, run the 300-second stability test and native
   RT-Thread baseline, then add the Docker-specific metrics and evidence hashes
   to the existing report.

Long-running historical host results are linked rather than silently relabeled
as Docker measurements.

## Non-Goals

- Modifying the general-purpose CI container.
- Using KVM, host networking, `--privileged`, or host device passthrough.
- Claiming hard realtime certification from Docker/TCG measurements.
- Covering task three AI inference and control-loop integration.
- Staging or committing unrelated changes already present in the shared
  worktree or index.
