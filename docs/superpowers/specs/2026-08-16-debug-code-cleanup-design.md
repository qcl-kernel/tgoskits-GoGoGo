# AxVisor RT-Thread Debug Code Cleanup Design

## Objective

Clean the `rtthread-migration` implementation without changing its scheduling,
interrupt, networking, CPU-affinity, RT-IPC, or benchmark behavior. Preserve the
evidence needed to reproduce the realtime report, then verify the cleaned tree
against the existing functional and performance baselines.

## Scope

The cleanup covers changes made for the AxVisor Linux plus RT-Thread system and
its test automation. It does not include unrelated refactoring or cleanup of
pre-existing debug logging elsewhere in tgoskits.

Files are classified into three groups:

1. Production and automation paths: remove temporary probes, unreachable
   experiments, hard-coded local launchers, backup files, and generated build
   outputs.
2. Required observability: retain structured benchmark records, protocol status
   and error messages, and diagnostics needed to explain a test failure.
3. Reproducibility evidence: retain report-referenced historical logs and
   `qemu-rtthread-timer-boundary-diagnostic.patch` under
   `docs/docs/build/axvisor`. These files must not be production dependencies.

## Planned Cleanup

Delete the repository-root launchers `run-debug.sh`, `run-gicv2-test.sh`,
`run-head-120.sh`, `run-head-test.sh`, `run-main.sh`, `run-rx-debug.sh`,
`run-txdbg.sh`, and `run-verify.sh`. They contain workstation-specific absolute
paths and terminate unrelated QEMU processes, while maintained runners already
cover their useful behavior.

Delete the tracked backup files:

- `os/arceos/api/arceos_posix_api/src/imp/io.rs.bak`
- `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-passthrough`
- `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-virt`
- `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-passthrough`
- `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-virt`

Delete the generated `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.dtb`.
The checked-in DTS and build tooling remain the source of truth.

Review code added relative to `origin/dev` for temporary UART writes, debug-only
runtime counters, polling diagnostics, trace probes, experiment flags, and
commented-out alternatives. A candidate is removed only when it is not part of
normal error reporting, protocol behavior, benchmark data collection, or a
maintained test contract.

## Artifact Validation Contract

The current checks conflict: `test_rtbench_precision.sh` rejects the old host
policy diagnostic marker, while `validate_qemu_artifact.sh` requires the same
diagnostic string and exported symbol in the ELF. The artifact validator will
stop treating debug text as a correctness witness.

Artifact validation will continue to verify that:

- the raw image is reproduced exactly from the ELF;
- every selected VM configuration is embedded in both ELF and raw image;
- all inputs remain unchanged during validation;
- the manifest records canonical paths and SHA-256 hashes.

The precision test will retain its negative assertion preventing the removed
host-policy debug hook from returning.

## Functional Verification

Run formatting and focused Rust tests for `arm_vcpu`, `axvmconfig`,
`axvirtio-net`, and `axvm` with its host-test feature. Run the RT-IPC unit and
contract tests, host realtime tests, QEMU control and benchmark-gate tests, and
runner lifecycle tests.

Apply the RT-Thread patch set to a fresh pinned source tree and build it with the
project's `uv`-managed SCons environment. Then run a fresh system smoke test and
require:

- the Linux guest reports CPUs 0-1 online and `nproc=2`;
- RT-Thread boots and its VirtIO network device and IP stack initialize;
- Linux and RT-Thread exchange traffic in both directions;
- each maintained RT-IPC request class completes 10 of 10 requests;
- no new crash, timeout, protocol error, or application error appears.

## Performance Verification

Use the existing v8 300-second result as the pre-cleanup long-run baseline:
P50 8.288 us, P99 293.712 us, maximum 1.193376 ms, two samples over 1 ms,
90,000 of 90,000 network requests successful, and no timeout or protocol error.
The historical best 300-second maximum of 997.808 us remains context rather
than the regression baseline.

After cleanup, first run the same 1,000-sample suite, then run the same
300-second concurrent benchmark. Compare P50, P95, P99, P99.9, maximum latency,
threshold miss counts, network RTT, effective throughput, timeout count, and
protocol/application error count.

Functional counters are strict: request success, timeout, and error results may
not regress. A repeatable increase greater than 10 percent in P50, P95, or P99
is a performance regression. Because QEMU TCG produces stochastic tail spikes,
a single maximum or `miss_1ms` increase triggers a repeat run and investigation
rather than an automatic regression verdict. All raw results and comparisons
will be appended to the existing realtime report.

## Change Discipline

All edits remain narrowly scoped to cleanup and its validation contract. The
existing dirty worktree is preserved: unrelated user changes are not reverted,
and commits stage only files belonging to this cleanup. If a candidate is
required by a maintained test or report, it is retained or replaced before
removal.
