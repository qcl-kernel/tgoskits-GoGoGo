# Task 1/2/3 One-Click Reproduction Plan

## Goal

Provide one entry point that composes the existing authoritative Task 1/2/3
runner without duplicating its build, QEMU lifecycle, or result-gate logic.

## Interface

- `reproduce_task123.sh` defaults to `--quick`.
- `--quick` runs smoke, a short realtime suite, and a short Task 3 run.
- `--full` runs the full realtime suite, 300-second stability, 600-frame
  fixed/AI scenarios, and all five recovery profiles.
- `--output DIR` selects a new or empty evidence directory.

## Failure Policy

Every build, network, protocol, Task 3, evidence, and archive failure stops the
workflow. The full profile may continue after the stability runner returns
nonzero only when the console proves Task 2 and Task 3 passed, the stability
run completed, and the failed gate contains nonzero 1 ms misses without panic,
assertion, fatal, or guest failure markers. That result is explicitly reported
as `PASS_WITH_QEMU_TIMER_LIMIT`, never as an unqualified pass.

## Evidence

The script writes a machine-readable line-oriented summary, host metadata, one
orchestrator log, all per-phase runner directories, a deterministic tar.gz
archive, and a separate SHA-256 file. Host QEMU execution remains authoritative
for realtime results; containers are suitable only for build and functional
reproduction.

## Verification

`test_reproduce_task123.sh` uses a fake runner to verify phase order, exact
arguments, expected QEMU-limit continuation, hard-failure behavior, output
safety, fault aggregation, archive contents, and digest generation.
