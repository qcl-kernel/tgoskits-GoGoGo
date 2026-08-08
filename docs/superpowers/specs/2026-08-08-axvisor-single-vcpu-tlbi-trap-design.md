# Axvisor Single-vCPU TLBI Trap Optimization

## Goal

Reduce Zephyr timer tail latency in the existing Axvisor workload with two
Linux guests and one RTOS guest. All three guests have one vCPU, remain pinned
to separate physical CPUs, and communicate only through ordinary virtio-net
Ethernet. Shared memory, IVC, virtio sockets, and guest-count reductions remain
out of scope.

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
The selected policy is included in the existing resolved VM host-policy startup
record so runtime evidence proves which HCR behavior was built and used.

This is initially a candidate, not a new accepted default. If the screening or
stability gates fail, the implementation and startup field are removed as one
candidate while all diagnostic and benchmark records are retained.

### HCR composition

When the policy is enabled, compose the saved guest `HCR_EL2` value with
`HCR_EL2.TTLB` bit 25. Do not use `TTLBIS` or `TTLBOS`: those controls require
`FEAT_EVT`, while the base `TTLB` control is supported by the Cortex-A72 QEMU
model and traps both local and shareable EL1 TLB maintenance instructions.

The bit is part of the existing per-vCPU saved system-register context. It must
not leak between VMs or survive a setup configuration that disables the policy.
Existing interrupt passthrough and WFI-trap composition remains independent.
Multi-vCPU guests retain their current native TLBI behavior and therefore
preserve required inter-vCPU invalidation semantics.

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

### Conservative emulation

For every accepted EL1 TLBI operation, ignore the operand and invalidate all
stage-1 translations for the current guest VMID on the current physical CPU:

```text
dsb sy
tlbi vmalle1
dsb sy
isb
```

This deliberately broadens the requested ASID, address, range, level, and
shareability scope. Broadening is correct for a one-vCPU guest because there is
no second guest vCPU whose local TLB must be synchronized, and invalidating
additional current-VMID entries cannot preserve stale translations. It may add
local refill cost, which is measured rather than assumed to be beneficial.

The sequence runs at Axvisor EL2 with the current guest's `VTTBR_EL2` restored.
It does not invalidate another VMID and does not use an `*IS` instruction, so
QEMU TCG handles it as a local flush rather than an all-vCPU synchronized flush.
The existing guest-entry cache/TLB maintenance sequence is unchanged.

### PC and error semantics

Advance the guest exception PC only after a recognized TLBI operation has been
successfully emulated. An unrecognized write in the EL1 TLBI encoding namespace
(`op0=1`, `op1=0`, `CRn=8`) observed while `HCR_EL2.TTLB` is active returns
`ArmVcpuError::Unsupported` without advancing the PC and without silently
dropping the maintenance request. This is fail-closed behavior; a guest may
stop with an explicit error, but it cannot continue with potentially stale
translations. A trapped instruction outside that namespace remains an ordinary
system-register access and is not rejected merely because `TTLB` is set.

Generic trapped system-register accesses preserve their current behavior and
advance the PC only when converted to a typed VM exit. No fallback re-executes
an unknown TLBI with `TTLB` temporarily cleared, because changing HCR around a
single instruction would add untested state and exception-recovery complexity.

## Component Boundaries

`virtualization/arm_vcpu/src/policy.rs` owns the typed setup policy and pure
TLBI syndrome classification. `virtualization/arm_vcpu/src/vcpu.rs` owns HCR
composition. `virtualization/arm_vcpu/src/exception.rs` owns exception routing,
local emulation, PC advance, and typed errors. `virtualization/axvm/src/arch/
aarch64/vm.rs` derives the policy from `cpu_num` and passes it into every vCPU.

AxVM does not decode ARM instruction fields, and `arm_vcpu` does not inspect VM
names or TOML. This keeps architecture semantics testable without an Axvisor
runtime and keeps VM topology selection in the VMM layer.

## Test Strategy

Implementation follows test-driven development. Each production change starts
with a focused test that fails for the intended missing behavior.

Pure policy tests cover disabled and enabled TLBI policy values, HCR bit 25,
independence from passthrough/TWI bits, and reset to disabled. Decoder table
tests cover every accepted family and representative local, IS, OS, range, and
nXS encodings. Negative tests cover ordinary system registers, reads, malformed
ISS values, EL2/stage-2 encodings, and reserved CRM/op2 combinations.

Exception tests prove that recognized TLBI advances PC exactly once after the
emulation decision, while rejected input returns `Unsupported` and leaves PC
unchanged. Because host Rust tests cannot execute privileged `tlbi`, the
decoder and disposition decision are pure; a tight AArch64 source contract and
the release guest build cover the exact `dsb/tlbi vmalle1/dsb/isb` sequence.

AxVM tests cover `cpu_num=1` enabling the policy and `cpu_num=2` leaving it
disabled. Existing arm_vcpu, AxVM architecture-boundary, VGIC, configuration,
formatting, Clippy, and AArch64 release-build checks must remain green before
runtime measurement.

## Runtime Evaluation

### QEMU TCG screening

Use the frozen artifacts and environment from iterations 155--163: QEMU 11.0.2
with MTTCG/SMP3, the same Axvisor board and three VM configurations, the same
Zephyr ELF/raw image, rootfs source, timer rate, benchmark duration, CPU
placement, host settings, and network traffic.

First run one fresh control with the restored official QEMU executable SHA-256
`84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956`, the
pre-candidate Axvisor image, and the synchronized collector. Then run the
candidate with the same QEMU executable and inputs. The Axvisor candidate and
its resolved `single_vcpu_tlbi_trap=true` startup evidence are the only changed
variable. Iterations 155--163 remain causal diagnostics and are not substituted
for this fresh performance control because their QEMU instrumentation differs.

Run one official-QEMU screening repetition. It passes only when:

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

If both screens pass, run three fresh official-QEMU repetitions. QEMU acceptance requires all
three functional gates, zero `>1 ms` misses in every repetition, p99.99 below
`500 us` in every repetition, and no regression in the worst maximum or total
`>100 us`/`>500 us` misses against the fresh official-QEMU control.
Any invalid phase accounting, including the negative-phase failure seen in
iteration 162, invalidates the repetition instead of counting as zero latency.

If screening or confirmation fails, remove the candidate implementation and
record the result as rejected. A favorable QEMU result is not physical
acceptance and cannot be described as bare-metal or hard-real-time performance.

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
trace, artifact identity, and manifest paths. Record the single changed
variable, resolved policy, hashes, callback/network results, all percentile and
maximum fields, miss counts, causal attribution, and candidate decision in the
Markdown report.

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
