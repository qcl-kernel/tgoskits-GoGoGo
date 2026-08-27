# Axvisor Single-vCPU TLBI Trap Optimization

## Goal

Reduce Zephyr timer tail latency in the existing Axvisor workload with two
Linux guests and one RTOS guest. All three guests have one vCPU, are configured
for separate physical CPU IDs in the experiment, and communicate only through
ordinary virtio-net Ethernet. Shared memory, IVC, virtio sockets, and
guest-count reductions remain out of scope. Correctness must not assume that a
configured physical CPU ID makes an AxVM task permanently non-migratable.

The local QEMU TCG phase tests whether replacing guest EL1 broadcast TLB
maintenance with a semantically conservative local invalidation removes the
MTTCG stop-the-world tail. A QEMU result is only an emulator attribution result.
Bare-metal-level acceptance still requires the same-board physical AArch64
measurements defined in the realtime report.

## Current Evidence

Iterations 155--163 completed all three network gates and `9999/9999` Zephyr
callbacks. Iteration 160 rejected BQL reacquisition as the source of a
`23.778 ms` maximum because only two BQL waits exceeded `100 us`, with a maximum
of `156.931 us`. Iterations 161--162 observed thousands of MTTCG exclusive-stop
events but no `cpu_exec_step_atomic_wait` or `cpu_exec_step_atomic_region`
events, rejecting `EXCP_ATOMIC` as the source of those barriers.

Iteration 163 decoded all 4,152 exclusive work callbacks as
`tlb_flush_range_by_mmuidx_async_1`, `tlb_flush_page_by_mmuidx_async_1`, or
`tlb_flush_by_mmuidx_async_work`. In one direct sample, a CPU 0 TLB-exclusive
request waited `1.415426 ms` for other QEMU vCPUs to stop while RTOS PPI 27 was
asserted. The flush callback itself took `1.040 us`; RTOS assert-to-take latency
was `1.120551 ms`.

QEMU 11.0.2 maps shareable EL1 TLBI instructions to
`tlb_flush_*_all_cpus_synced()`. Those functions use an exclusive work item on
the source CPU and stop all QEMU vCPUs even though each nested guest has only
one vCPU. QEMU also documents that the affected paths do not precisely filter
all invalidations by ASID. Axvisor's own guest-entry `tlbi alle2` and
`tlbi alle1` operations are local forms and are not removed by this design.

## Chosen Design

### Setup policy

Add a typed TLBI trap policy to `ArmVcpuSetupConfig`. AxVM derives it directly
from `AxVMConfig::cpu_num()`:

- exactly one vCPU enables the single-vCPU TLBI trap policy;
- zero or more than one vCPU leaves the policy disabled;
- no VM name, guest type, CPU placement, timer mode, or QEMU-specific setting
  participates in the decision.

The policy is architecture-local and is not exposed as a new TOML field. It is
applied to every vCPU context through the existing AArch64 setup-config path.
For experimentation it is additionally gated by an auditable build feature
that is disabled in ordinary builds until physical acceptance. Within a
candidate build, configured guest CPU count remains the only per-VM selection
input; the feature is not a QEMU, guest-name, or placement heuristic.

Startup provenance has two states. The resolved host-policy record reports
`configured` after configuration resolution. Only after every vCPU setup
succeeds may a second record report `active=true`; it includes VM ID,
configured `cpu_num`, resolved policy, every vCPU's effective `HCR_EL2.TTLB`
state, and the Axvisor artifact identity. A setup failure never emits
`active=true`.

This is initially a candidate, not a new accepted default. If the screening or
stability gates fail, revert the candidate commit or discard its isolated
worktree while retaining all diagnostic and benchmark records. Do not remove
files manually from the user's working tree.

### HCR composition

When the policy is enabled, compose the saved guest `HCR_EL2` value with
`HCR_EL2.TTLB` bit 25. Do not use `TTLBIS` or `TTLBOS`: those controls require
`FEAT_EVT`, while the base `TTLB` control is supported by the Cortex-A72 QEMU
model and traps both local and shareable EL1 TLB maintenance instructions.

The bit is part of the existing per-vCPU saved system-register context. It must
not leak between vCPU contexts or survive a setup configuration that disables
the policy. Existing interrupt passthrough and WFI-trap composition remains
independent. Multi-vCPU guests retain their current native TLBI behavior and
therefore preserve required inter-vCPU invalidation semantics.

### TLBI syndrome decoding

`HCR_EL2.TTLB` reports trapped AArch64 TLBI operations with exception class
`TrappedMsrMrs`. Decode the ISS before the generic system-register exit path and
classify only architected EL1 stage-1 TLBI writes. The decoder is a pure,
OS-neutral function with an explicit allow-list covering these operation
families and their local, inner-shareable, outer-shareable, range, and nXS
forms when architecturally present:

- `VMALLE1`, `VAE1`, `ASIDE1`, `VAAE1`, `VALE1`, and `VAALE1`;
- `RVAE1`, `RVAAE1`, `RVALE1`, and `RVAALE1`.

EL2, stage-2, and EL3 TLBI encodings are never accepted. Ordinary MRS/MSR
instructions continue through the existing `SysRegRead` or `SysRegWrite` VM
exit path. The decoder must not infer TLBI solely from the exception class.
The complete trapped EL1 TLBI namespace is `op0=1`, `op1=0`, and
`CRn in {8, 9}`: architected nXS variants occupy `CRn=9`. Every namespace
member not present in the explicit allow-list is rejected fail-closed.

### Conservative emulation

For every accepted EL1 TLBI operation, ignore the operand and invalidate all
stage-1 translations tagged with the currently installed VMID on the current
physical CPU:

```text
dsb sy
tlbi vmalle1
dsb sy
isb
```

This deliberately broadens the requested ASID, address, range, level, and
shareability scope. Broadening is correct for a one-vCPU guest because there is
no second guest vCPU whose local TLB must be synchronized, and invalidating
additional entries cannot preserve stale translations. It may add local refill
cost, which is measured rather than assumed to be beneficial.

The sequence runs at Axvisor EL2 with the current guest's `VTTBR_EL2` restored.
The current implementation does not write a distinct VMID into `VTTBR_EL2`;
all Axvisor VMs therefore use VMID 0. `VMALLE1` may invalidate VMID-0
translations belonging to another Axvisor VM that ran on the same physical PE.
This remains a conservative correctness-preserving invalidation, not an
isolation-preserving one, and its cross-VM refill cost is part of the measured
candidate overhead. The instruction does not use an `*IS` form, so QEMU TCG
handles it as a local flush rather than an all-vCPU synchronized flush.

Migration safety depends on an explicit existing invariant: every guest entry
through `ArmVcpu::run()` calls `restore_vm_system_regs()`, whose local
`tlbi alle1` clears stale stage-1 entries on the destination PE before the guest
runs. Therefore a vCPU that returns to any previously used PE cannot consume
translations left there before migration. This guest-entry flush and its call
site are a regression contract and are not removed by this candidate. If a
future change removes that entry flush, this policy must be disabled unless the
vCPU is permanently bound to one PE or Axvisor invalidates every PE on which
the VM has run.

### PC and error semantics

Advance the guest exception PC only after a recognized TLBI operation has been
successfully emulated. An unrecognized write in the EL1 TLBI encoding namespace
(`op0=1`, `op1=0`, `CRn in {8, 9}`) observed while `HCR_EL2.TTLB` is active
returns a TLBI-specific error without advancing the PC and without silently
dropping the maintenance request. The diagnostic includes ISS and ELR; the AxVM
caller adds VM and vCPU IDs to the lifecycle record. This is fail-closed
behavior: a guest may stop with an explicit error, but it cannot continue with
potentially stale translations. A trapped instruction outside that namespace
remains an ordinary system-register access and is not rejected merely because
`TTLB` is set.

Generic trapped system-register accesses preserve their current behavior and
advance the PC only when converted to a typed VM exit. No fallback re-executes
an unknown TLBI with `TTLB` temporarily cleared, because changing HCR around a
single instruction would add untested state and exception-recovery complexity.

## Component Boundaries

`virtualization/arm_vcpu/src/policy.rs` owns the typed setup policy, pure TLBI
syndrome classification, pure disposition decision, and pure HCR composer.
These units remain host-compilable. `virtualization/arm_vcpu/src/vcpu.rs` owns
the AArch64 register application. `virtualization/arm_vcpu/src/exception.rs`
owns the architecture wrapper, local emulation, PC advance, and typed errors.
`virtualization/axvm/src/arch/aarch64/vm.rs` uses a host-testable pure seam to
derive the policy from configured `cpu_num` and passes it into every vCPU.

AxVM does not decode ARM instruction fields, and `arm_vcpu` does not inspect VM
names or TOML. This keeps architecture semantics testable without an Axvisor
runtime and keeps VM topology selection in the VMM layer.

## Test Strategy

Implementation follows test-driven development. Each production change starts
with a focused test that fails for the intended missing behavior.

Host tests for pure policy and HCR composition cover disabled and enabled TLBI
policy values, HCR bit 25, independence from passthrough/TWI bits, and reset to
disabled. Decoder table tests cover every accepted family and representative
local, IS, OS, range, and nXS encodings. Negative tests cover ordinary system
registers, reads, malformed ISS values, EL2/stage-2 encodings, and reserved
`CRm`/`op2` combinations in both `CRn=8` and `CRn=9` namespaces.

Host disposition tests prove that recognized TLBI requests PC advancement
exactly once after successful emulation, while rejected input carries ISS/ELR
and requests no advancement. Because host Rust tests cannot compile the full
AArch64 exception wrapper or execute privileged `tlbi`, an AArch64 target
build/test covers wrapper integration. A tight assembly source contract only
checks the textual `dsb/tlbi vmalle1/dsb/isb` instruction order; it is not
claimed as a behavioral execution test. A separate source regression contract
checks that every `ArmVcpu::run()` guest entry still calls the local
`tlbi alle1` path required for migration safety.

Host-testable AxVM policy tests cover configured `cpu_num=0` and `cpu_num=2`
leaving the policy disabled and `cpu_num=1` enabling it. A mismatched placement
fixture proves that configured count, not `phys_cpu_ids` or placement length,
drives the decision. Existing arm_vcpu, AxVM architecture-boundary, VGIC,
configuration, formatting, Clippy, and AArch64 release-build checks must remain
green before runtime measurement.

## Runtime Evaluation

### QEMU TCG screening

Use the frozen inputs and environment from iterations 155--163: QEMU 11.0.2
with MTTCG/SMP3, the same Axvisor board and three VM configurations, the same
Zephyr ELF/raw image, rootfs source, timer rate, benchmark duration, CPU
placement, host settings, and network traffic. Build the control and candidate
from one immutable baseline in dedicated clean worktrees or equivalent
immutable source bundles. The candidate feature and its resulting code are the
only source/build difference.

Each build manifest records the source commit, tracked-diff hash, hash of an
archive containing the explicitly allow-listed untracked inputs, toolchain,
complete build command and features, board/config/rootfs hashes, QEMU hash, and
collector hash. The control and candidate manifests must match on every field
except the declared candidate change and resulting Axvisor artifacts. Existing
dirty user files are neither imported implicitly nor modified for rollback.

The runner has mutually exclusive `official` and `diagnostic` modes. Before an
`official` launch it must verify QEMU executable SHA-256
`84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956` and reject
any mismatch. Diagnostic mode writes a separate output tree and manifest with
`performance_eligible=false`. The performance acceptance script reads only
official manifests and rejects mixed modes or missing provenance before
examining latency.

First run one fresh control/candidate screening pair with the restored official
QEMU executable and synchronized collector. The candidate feature, Axvisor
artifact, and resulting configured/active TLBI policy evidence are the only
changed variables. Iterations 155--163 remain causal diagnostics and are not
substituted for this fresh performance control because their QEMU
instrumentation differs.

The official-QEMU screening pair passes only when each member satisfies the
first three gates and the candidate satisfies the fourth:

1. both Linux-to-Zephyr ICMP checks and Linux-1-to-Linux-2 TCP/8080 pass;
2. Zephyr completes `9999/9999` callbacks with valid phase and interval data;
3. no unknown-TLBI or VM lifecycle error occurs; and
4. p99.99, maximum latency, and `>100 us`/`>500 us`/`>1 ms` miss severity
   improve together against the fresh official-QEMU control.

If that screen passes, run one separate causal repetition with the cumulative
v10 QEMU diagnostic patch from iteration 163. This diagnostic repetition must
show that guest EL1 TLBI no longer creates an RTOS-overlapping all-vCPU TLB
exclusive interval. Its latency values are marked diagnostic and excluded from
performance comparison because the QEMU executable differs.

If both the official performance screen and separate causal diagnostic screen
pass, run three interleaved official control/candidate pairs in this order:
`control-1`, `candidate-1`, `control-2`, `candidate-2`, `control-3`,
`candidate-3`. The screening pair does not count toward these three formal
pairs. Every one of the six runs must pass both Linux-to-Zephyr ICMP checks and
Linux-1-to-Linux-2 TCP/8080, complete `9999/9999` callbacks with valid phase and
interval data, and report zero unknown-TLBI and VM lifecycle errors. Any
invalid phase accounting, including the negative-phase failure seen in
iteration 162, invalidates the run instead of counting as zero latency.

QEMU acceptance additionally requires every candidate run to have zero
`>1 ms` misses and p99.99 below `500 us`. Compare the worst candidate maximum
to the worst control maximum, and compare the sum of the three candidate
`>100 us` and `>500 us` miss counts to the corresponding three-control sums;
none may regress. Report paired deltas as supporting evidence, but do not
replace these worst-to-worst and sum-to-sum decisions with a favorable average.

If screening or confirmation fails, revert the explicit candidate commit or
discard the isolated candidate worktree and record the result as rejected. A
favorable QEMU result is not physical acceptance and cannot be described as
bare-metal or hard-real-time performance.

### Same-board AArch64 acceptance

After a QEMU candidate passes, repeat the existing same-board protocol with a
Zephyr bare-metal reference and Axvisor running two Linux guests plus Zephyr.
Both modes use the same RTOS image options, timer benchmark, timer rate, sample
count, external network load, CPU frequency/governor, and three repetitions.

Bare-metal-level acceptance requires full callback and network completion,
zero misses above `1 ms` in every Axvisor run, p99.9 and p99.99 no more than
`25%` or `10 us` above the corresponding bare-metal values (whichever allowance
is larger), and maximum latency no more than `2x` or `50 us` above the
bare-metal maximum (whichever allowance is larger). All raw values and ratios
are reported even when the candidate fails.

The current x86_64 host provides AArch64 TCG only. Physical acceptance remains
open until the required board inputs and measurements exist.

## Reporting and Reproducibility

Every failed build, failed launch, unsupported TLBI, diagnostic run, screening
run, rejected candidate, and confirmation run receives a monotonically
increasing CSV iteration. Preserve raw console, QMP, network, scheduler, QEMU
trace, artifact identity, and manifest paths. Record source commit, tracked
diff and allow-listed untracked archive hashes, toolchain/build identity,
official/diagnostic mode, `performance_eligible`, the single changed variable,
configured and active policies, artifact/input hashes, callback/network
results, all percentile and maximum fields, miss counts, causal attribution,
and candidate decision in the Markdown report.

Regenerate the checked-in PNG from the complete CSV and run its digest test.
Missing or invalid values remain missing and are never converted to zero.

## Non-Goals

- Changing QEMU TLB implementation or weakening `start_exclusive()` semantics.
- Adding a timeout or skipping an MTTCG exclusive waiter.
- Removing Axvisor guest-entry TLB or instruction-cache maintenance.
- Applying local-only emulation to a multi-vCPU guest.
- Optimizing ASID/range precision in the first implementation.
- Changing Linux scheduling, guest count, CPU placement, or network transport.
- Treating x86_64-hosted AArch64 TCG as physical AArch64 evidence.
