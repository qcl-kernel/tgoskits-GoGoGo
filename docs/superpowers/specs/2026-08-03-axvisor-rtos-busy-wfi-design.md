# Axvisor RTOS Busy-WFI Real-Time Optimization

## Goal

Reduce Zephyr timer tail latency in the existing Axvisor workload with two Linux
guests and one RTOS guest. Guest-to-guest traffic must continue to use ordinary
virtio-net Ethernet; shared memory, IVC, and virtio sockets remain prohibited.

The local QEMU TCG phase must determine whether avoiding the outer halted-vCPU
wakeup path removes the observed millisecond tail. A claim of bare-metal-level
performance additionally requires three-repeat Zephyr bare-metal and Axvisor
measurements on the same physical AArch64 board.

## Current Evidence

CSV iterations 144 and 145 are synchronized three-guest diagnostics. They
completed all `9999/9999` timer callbacks and network checks, but had maximum
latencies of `1459 us` and `1362 us`, with `1` and `3` misses above `1 ms`.
Their worst timer compare-overdue windows were `1.6616 ms` and `1.568544 ms`.

The RTOS QEMU vCPU thread accumulated `0 ns` run delay in both worst windows.
Iteration 145 observed it in `S/futex_do_wait`; 89,902 of 90,001 samples used
that wait channel. This rejects the hypothesis that a runnable RTOS vCPU is
waiting behind Linux work in the host CFS run queue.

Axvisor currently leaves `HCR_EL2.TWI` clear and has no trapped-WFI exception
case. Zephyr's WFI therefore reaches the outer QEMU process, which halts the
emulated pCPU. The QEMU virtual timer later travels through a main-loop timer
callback, IRQ assertion, `qemu_cpu_kick()`, and `halt_cond` wake before the RTOS
vCPU can take PPI 27. Existing sampling covers QEMU vCPU TIDs but not the QEMU
main/I/O TID, so it does not yet separate late main-loop callback dispatch from
late `halt_cond` wakeup.

## Chosen Design

### Per-VM idle policy

Add `HostVcpuIdlePolicy` to the VM base configuration with these serialized
values:

- `halt` is the default and preserves current behavior on every existing VM.
- `busy` is an AArch64 policy that traps guest WFI and immediately resumes the
  selected vCPU instead of allowing the physical CPU to execute WFI.

The TOML field is `host_vcpu_idle_policy`. Only the Zephyr benchmark VM sets it
to `"busy"`; both Linux VM configurations omit it and therefore remain `halt`.
The option applies to all vCPUs of the configured VM. The current Zephyr VM has
one vCPU pinned to pCPU 2, so the practical cost is one continuously busy QEMU
vCPU thread and approximately one host CPU.

The policy is explicit rather than inferred from VM name, guest type, timer
mode, or CPU placement. Existing configurations and generated templates remain
default-off. Requesting `busy` on a non-AArch64 build must produce an explicit
unsupported-configuration error rather than being silently ignored.

### AArch64 WFI handling

Propagate the policy through `AxVMCrateConfig`, `AxVMConfig`, the AArch64 setup
configuration, and each `ArmVcpu` context. When the policy is `busy`, compose
the guest's saved `HCR_EL2` value with `TWI`; otherwise leave `TWI` clear.
Because `HCR_EL2` is saved per vCPU, Linux and other VMs cannot inherit the RTOS
setting during a context switch.

Handle the AArch64 trapped-WFx exception class explicitly. A WFI trap advances
the guest PC by one instruction and returns a typed `WaitForInterrupt` VM exit.
AxVM maps that exit to `VcpuRunAction { waits_for_event: false }`, so the vCPU
loop performs normal stop/suspend checks and re-enters the guest without using
its wait queue. WFE is not enabled by this policy; if a WFE trap is observed,
it returns a typed unsupported error instead of being mistaken for WFI.

The existing `host_vcpu_yield` option remains independent. It may yield the
Axvisor scheduler after a trapped WFI, but it must not execute physical WFI or
put the outer QEMU vCPU thread into `futex_do_wait`. VM stop, suspend, resume,
and teardown continue through the existing loop and need no global policy
restoration because the TWI bit belongs to the vCPU context.

### Synchronized host diagnostics

Extend `collect_qemu_sched_trace.sh` so its sampled thread map contains both:

- every QMP-validated vCPU TID, labeled with its vCPU index; and
- the QEMU process leader/main-I/O TID, equal to the QEMU PID and labeled
  `main-loop`.

Validate that every sampled TID belongs to the same live QEMU process and keep
the current PID-start-time, executable, manifest, kernel snapshot, SMP count,
and QMP uniqueness checks. Preserve role labels in raw samples and summaries so
the worst guest timer window can be compared with both the RTOS vCPU and QEMU
main loop. The collector must continue to work when the process leader also
appears in auxiliary metadata; it must not count it as an additional vCPU.

## Test Strategy

Implementation follows test-driven development. Tests are added before each
production change and must fail for the intended reason.

Configuration tests cover default `halt`, `busy` deserialization, template
defaults, runtime mapping, and the non-AArch64 rejection rule. AArch64 tests
cover HCR composition with and without `TWI`, trapped-WFI decoding, PC advance,
typed VM exit mapping, and preservation of existing WFI behavior when the
policy is absent. Lifecycle/source-contract coverage verifies that busy WFI
still reaches stop and suspend checks and is scoped to the selected VM.

Collector tests use a controlled fake `/proc`/QMP fixture or the existing test
harness to prove that the main-loop TID and all vCPU TIDs are sampled exactly
once with stable role labels, while an invalid or reused PID is rejected.

Focused crate tests and the Axvisor AArch64 build must pass before any runtime
benchmark. Existing three-guest network, timer precision, scheduler trace, and
artifact freshness checks must also remain green.

## Runtime Evaluation

### QEMU TCG screening

Use the same QEMU version, SMP3 topology, Zephyr/Linux images, VM placement,
counter frequency, tick rate, network topology, benchmark duration, and host
settings as iterations 144-145. Change only `host_vcpu_idle_policy` for the
Zephyr VM. Bind the run to fresh Axvisor ELF/raw/VM-config hashes.

Run one screening repetition. Continue only when all conditions hold:

1. Both Linux-to-Zephyr ICMP checks and the Linux-to-Linux TCP check pass.
2. Zephyr completes `9999/9999` callbacks without timer or tick-gap failure.
3. The RTOS vCPU no longer spends the benchmark idle window in
   `futex_do_wait`.
4. p99.9 does not regress, and p99.99, maximum latency, and deadline-miss
   severity improve against the synchronized control runs.

If screening passes, run three fresh candidate repetitions. Accept the policy
for the QEMU benchmark only when all three satisfy the functional gates and the
aggregate p99.99, worst maximum, and `>100 us`/`>500 us`/`>1 ms` miss counts
improve without starving Linux or network progress. Otherwise disable the
candidate in the formal config and retain its data as rejected evidence.

This TCG result can establish that the WFI wake path caused the local tail, but
it cannot establish real-hardware or hard-real-time performance.

### Same-board AArch64 acceptance

Bare-metal-level acceptance requires a board that can run both a Zephyr
bare-metal reference and Axvisor with two Linux guests plus Zephyr using only
network communication. Each mode uses the same timer benchmark, timer rate,
sample count, RTOS build options, external network traffic profile, CPU
frequency/governor, and three repetitions. Axvisor also keeps the two Linux
guest workload and all three network checks active.

The result is called bare-metal-level only when every Axvisor repetition has
zero misses above `1 ms`, full callback/network completion, p99.9 and p99.99 no
more than `25%` or `10 us` above the corresponding bare-metal value (whichever
allowance is larger), and maximum latency no more than `2x` or `50 us` above
the bare-metal maximum (whichever allowance is larger). Report all raw values
and ratios even when the candidate fails these limits.

The repository currently lacks a physical-board configuration with three
independent guest network devices and matching two-Linux-plus-RTOS images.
Therefore this phase remains an external hardware/asset gate; QEMU results must
not be relabeled as same-board acceptance.

## Reporting and Reproducibility

Every diagnostic, failed launch, rejected candidate, screening run, and formal
run receives a new monotonically increasing CSV iteration and keeps its raw log
and trace paths. The Markdown report records the artifact hashes, environment,
single changed variable, functional results, latency distribution, deadline
misses, thread-state attribution, decision, and residual limitations.

Before adding new benchmark rows, correct the five known report/CSV p99.9
mismatches at iterations 60, 68, 84, 85, and 92. Regenerate the repository PNG
from the complete CSV, including iterations 143-145, and add a regression check
that compares the checked-in PNG with a fresh deterministic render. Existing
`NA` values remain missing and must never be plotted as zero.

## Failure and Rollback Behavior

The policy defaults to `halt`, so omitting the field is the complete rollback.
If WFI decoding, timer progress, VM lifecycle, network progress, or latency
gates fail, the Zephyr formal configuration returns to `halt`; the generic
implementation may remain only if all correctness tests pass and the report
labels the performance candidate rejected. A production default is never
changed based on one favorable run.

## Non-Goals

- Changing Linux guest scheduling or reducing the required guest count.
- Replacing virtio-net with shared memory, IVC, or virtio sockets.
- Trapping WFE, changing PSCI CPU suspend semantics, or adding a generic power
  management framework.
- Claiming that x86_64-hosted AArch64 TCG is equivalent to physical AArch64.
- Hiding the dedicated-CPU power and capacity cost of busy WFI.
