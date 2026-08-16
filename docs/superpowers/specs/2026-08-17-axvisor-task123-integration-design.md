# AxVisor Task 1/2/3 Integration Design

## 1. Purpose

This design integrates the completed standalone `qemu-task3` Linux/RT-Thread
AI control demonstration into AxVisor while preserving and revalidating the
existing Task 1 realtime work and Task 2 RT-IPC network link.

The finished system shall boot exactly two guests under one AxVisor instance:

- one Linux guest with at least two vCPUs;
- one single-vCPU RT-Thread guest pinned to a dedicated physical CPU.

Linux performs image inference and Task 2 client work. RT-Thread runs realtime
benchmarks, the Task 2 echo/status service, and the Task 3 control service. All
inter-guest application data uses VirtIO-net, IPv4, UDP, and RT-IPC. Shared
memory, HyperCalls, raw MMIO, vsock, and host-side shortcuts are not permitted
as primary data channels.

## 2. Workspace Isolation

All implementation and commits are made in:

```text
/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123
```

The integration branch is:

```text
feat/axvisor-task123
```

It starts at tgoskits commit:

```text
cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35
```

The original checkout at `/home/yfblock/Code/hyper-rtos/tgoskits` is a
read-only migration source. Its source files, index, untracked files, and
working-tree state must not be changed, staged, cleaned, or committed.

Before the new worktree was created, the original checkout had these recorded
fingerprints:

```text
HEAD                         cc1bc7e466a9e67d1e681a9ed668b0f7197d0f35
status --porcelain SHA-256   9d1523eacf0bac1edef93c8574ed34f7c1392e0f20831fbe69ff7f89a5730078
unstaged diff SHA-256        3514871c0d525580abdc873f0e63c83f29fd6f7540511805f31f0e21166b7e58
staged diff SHA-256          471a190af20b1c230d935063686b9c7b23faae6f8b4ae12c1b5c51e826394963
```

The final audit must recompute these values and report any difference.

## 3. Migration Boundary

### 3.1 Task 1 and Task 2 source

The new branch imports only the current implementation needed for Tasks 1 and
2 from the original checkout:

- AxVisor scheduler, timer, vCPU idle, interrupt, VGIC, TLBI, CPU affinity,
  VirtIO-net, configuration, and FDT changes;
- Linux and RT-Thread guest configuration and boot scripts;
- RT-Thread 5.2.2 preparation and patch files;
- realtime benchmark sources and result gates;
- RT-IPC v2 common code, Linux client, RT-Thread server, fault injection,
  tests, runners, and result gates;
- focused design, reproduction, and result documentation.

The migration excludes debug logs, generated benchmark logs, build outputs,
temporary launchers, backup files, diagnostic-only patches, editor artifacts,
and the unfinished Docker reproduction files. Any migration must use an
explicit allowlist; broad copying of the dirty checkout is forbidden.

### 3.2 Task 3 source

Only Git-tracked content from the clean `qemu-task3` commit
`59e4aaf27614dd80f72190f37fe89eb019353828` is imported. Its `.git` directory
and 14 GiB generated `build/` tree are excluded.

Task 3 becomes a focused AxVisor guest application tree containing:

- the deterministic dataset and model generator;
- int8 CNN inference and exported model data;
- Linux application, metrics, Y4M parser, deadlines, and reporting;
- RT-Thread controller and Task 3 application service;
- Task 3 payload codec and session adapter;
- Buildroot package/configuration needed to produce reproducible Linux assets;
- host unit tests, fault tests, report tools, protocol documentation, and
  auditable pre-integration evidence.

The standalone dual-QEMU launch scripts are retained only as migration history
or converted into AxVisor launchers. They must not be used as final Task 3
evidence.

## 4. Runtime Architecture

### 4.1 CPU placement

The host QEMU machine exposes four physical CPUs to AxVisor.

- RT-Thread vCPU0 is statically assigned to physical CPU 2.
- Linux has two vCPUs. Both may be scheduled on the non-RTOS set containing
  physical CPUs 0, 1, and 3; neither Linux vCPU may execute on CPU 2.
- RT-Thread uses `HostVcpuIdlePolicy::Busy` for deterministic WFI handling.
- The selected timer policy must preserve VM one-shot deadlines and the
  realtime benchmark behavior already validated by Task 1.

This is asymmetric partitioning: RT-Thread receives an exclusive CPU, while
Linux retains freedom to preempt within its allowed non-RTOS CPU set.

### 4.2 Memory and boot

- Linux has at least 256 MiB RAM, two vCPUs, a Linux `Image`, and an initramfs
  containing both Task 2 and Task 3 applications and Task 3 model assets.
- RT-Thread has 256 MiB at the existing AxVisor guest address range and uses
  the existing AxVisor AArch64/RT-Thread port and linker layout.
- Guest kernel command lines are supplied through the VM configuration and
  generated FDT. Host QEMU `-append` is not treated as a guest shortcut.
- Images are generated from pinned source revisions and recorded by SHA-256.

The Task 3 RT-Thread standalone patch is not applied wholesale because it
targets standalone QEMU memory and interrupt layout. Its application and
configuration intent is merged into the existing AxVisor RT-Thread patchset.

### 4.3 Devices and interrupts

Each guest receives one emulated VirtIO-net MMIO device from AxVisor. AxVisor's
in-process virtual Ethernet switch forwards frames by guest MAC address and
injects RX interrupts through the virtual GIC. Polling is not accepted as the
primary RX completion mechanism.

The final configuration must document:

- guest memory regions and image load addresses;
- VirtIO MMIO addresses and interrupt IDs;
- virtual GIC routing and physical interrupt injection path;
- Linux and RT-Thread CPU masks;
- all guest boot arguments.

## 5. Network and Protocols

### 5.1 Topology

The isolated guest LAN is:

| Guest | MAC | IPv4 | Service |
|---|---|---|---|
| Linux | `52:54:00:77:00:01` | `192.168.77.11/24` | client |
| RT-Thread | `52:54:00:77:00:03` | `192.168.77.30/24` | UDP servers |

No default gateway, NAT, host bridge, TAP interface, port forwarding, or guest
firewall is needed. The link exists entirely inside the AxVisor virtual switch.

### 5.2 RT-IPC v2

AxVisor's current RT-IPC v2 is authoritative. It uses a 20-byte header with
protocol version, message type, payload length, sequence number, session ID,
error code, and CRC16. It also provides ACK, retransmission, bounded reordering,
duplicate suppression, heartbeat, disconnect/reconnect, FIN handling, and
session isolation.

The older Task 3 RT-IPC v1 copy is not imported. Compatibility probes already
proved that the Task 3 session test and Linux AI client compile and pass when
linked directly against AxVisor RT-IPC v2.

### 5.3 Service separation

- Task 2 remains on UDP port `9876` and keeps its existing payload benchmark,
  echo/status behavior, fault profiles, and result gates.
- Task 3 uses UDP port `9877` with a separate RT-IPC connection and server
  thread. This prevents ownership and lifecycle conflicts between Task 2
  benchmarking and Task 3 control traffic.

Task 3 preserves its versioned application payloads:

- `CTRL_CMD`: reset, step, or stop; mode; class; confidence; frame ID; Linux
  monotonic timestamp;
- `STATUS_REP`: applied class, duplicate flag, frame ID, PWM, actuator value,
  RTOS processing time, and echoed timestamp;
- `ERROR_NOTIFY`: category, error code, frame ID, and detail.

All multi-byte fields use network byte order. Invalid lengths, versions,
reserved fields, and enum values produce explicit errors without changing the
controller state. CRC failures are discarded by RT-IPC.

## 6. Task 3 AI Control Loop

Linux reads a deterministic 32x32 grayscale Y4M stream, executes the existing
int8 CNN, and produces LEFT, CENTER, or RIGHT with Q15 confidence. For every
frame it sends a Task 3 control transaction over UDP/RT-IPC v2.

RT-Thread validates the transaction, applies an idempotent virtual steering
and PWM update, and returns status. Linux records inference time, same-side
round-trip time, RTOS processing time, retries, duplicates, errors, recovery,
and the resulting control state.

Two 600-frame modes are evaluated at 10 FPS:

- FIXED always requests CENTER and provides the manual-control baseline;
- AI uses CNN output.

The control loop passes only when request success is at least 99.5%, model
accuracy is at least 95%, and AI mean tracking error improves by at least 30%
over FIXED. The report also includes p95/max control error, response latency,
and convergence/stability observations.

## 7. Build and Launch Flow

One top-level AxVisor integration runner owns the complete lifecycle:

1. verify pinned dependency revisions and required host tools;
2. generate the deterministic model and verify C/Python golden-vector parity;
3. prepare RT-Thread 5.2.2, apply the AxVisor patchset, install Task 1/2/3
   applications, and build normal and fault variants;
4. build or assemble the Linux kernel/initramfs with Task 2 and Task 3 binaries
   plus model/video/truth assets;
5. generate Linux and RT-Thread VM configurations from immutable templates;
6. build AxVisor with the two VM configurations;
7. launch one outer QEMU process containing AxVisor and both guests;
8. monitor only owned PIDs, collect serial output, enforce markers and
   deadlines, and preserve artifact hashes;
9. evaluate result gates and write machine-readable summaries.

The runner must never use `pkill`, `killall`, an unscoped process match, or an
external standalone guest QEMU as part of the final path.

## 8. Failure Handling

Build and runtime operations are fail-closed:

- unexpected source revisions, dirty generated source trees, missing images,
  missing symbols, invalid load addresses, and hash mismatches stop before
  QEMU launch;
- startup requires markers for Linux SMP, both network interfaces, Task 2
  server, and Task 3 server;
- every phase has a bounded deadline and preserves logs on failure;
- result gates reject missing/duplicate samples, malformed CSV/JSON, guest
  panic/assertion markers, incomplete shutdown, and nonzero QEMU status;
- cleanup targets only PIDs and temporary directories created by that run.

Task 3 fault acceptance covers dropped control, dropped status, duplicate
frame, delayed server, and malformed payload. It proves recovery or rejection
without extra control application.

## 9. Acceptance Tests

### 9.1 Static and unit gates

- Rust formatting and focused tests for `arm_vcpu`, `axvmconfig`, `axvm`, and
  `axvirtio-net` pass.
- AxVisor host realtime, VM configuration, interrupt, runner lifecycle, and
  result-gate shell contracts pass.
- RT-IPC v2 protocol, concurrency, wraparound, peer ownership, FIN, fault, and
  platform-safety tests pass.
- Task 3 codec, controller, dataset, model, C inference, session, metrics,
  deadline, Linux CLI, RT-Thread server, summarizer, report, and launcher
  contract tests pass against RT-IPC v2.
- A fresh RT-Thread checkout applies and builds without relying on a previously
  patched tree.

### 9.2 Task 1 runtime gates

- Linux reports two configured and online vCPUs.
- CPU evidence proves RT-Thread runs only on its dedicated physical CPU and
  Linux does not run there.
- The realtime suite collects all requested jitter, callback, preemption, and
  interrupt samples and reports p50, p95, p99, p99.9, maximum, and threshold
  misses.
- A 300-second concurrent run collects `299999/299999` periodic samples while
  network traffic is active, with no missing samples or guest errors.
- Results include native RT-Thread baseline, CPU load distribution, commands,
  image hashes, and an explicit QEMU TCG limitation statement.

The migration is rejected for a repeatable p50, p95, or p99 regression greater
than 10% against the same-QEMU pre-integration baseline. Maximum and `miss_1ms`
are reported separately and may trigger an additional repeat.

### 9.3 Task 2 runtime gates

- Linux and RT-Thread exchange traffic bidirectionally over VirtIO-net/IP.
- Three payload classes complete at least `1000/1000` each in the focused run
  and `30000/30000` each in the 300-second run.
- Success rate, application errors, timeouts, retries, duplicates, recovery,
  RTT percentiles, maximum RTT, and effective throughput are reported.
- Deterministic loss, duplicate, reordering, reconnect, stale-session, and FIN
  scenarios pass without duplicate application delivery.

### 9.4 Task 3 runtime gates

- One AxVisor instance boots Linux 2-vCPU and RT-Thread and completes the full
  AI input -> inference -> network -> RTOS control -> status feedback loop.
- FIXED and AI each complete 600 frames.
- Request success is at least 99.5%, classification accuracy at least 95%, and
  AI mean tracking error improvement at least 30%.
- Inference, round-trip, and RTOS processing latency distributions are reported
  with measurement method and error sources.
- All five real fault scenarios pass under AxVisor.

## 10. Evidence and Reporting

Generated logs and reports are kept outside Git until accepted. The final
committed documentation contains commands, exit codes, versions, CPU topology,
network topology, configuration, summary tables, and SHA-256 references to the
accepted artifacts.

Standalone dual-QEMU Task 3 evidence is retained and labeled as the migration
baseline. It is never presented as proof that Task 3 passed under AxVisor.

The final completion audit maps every Task 1, Task 2, and Task 3 requirement to
an authoritative test, runtime marker, log, configuration, or result table.
No percentage is reported as 100% unless that evidence is present and current.
