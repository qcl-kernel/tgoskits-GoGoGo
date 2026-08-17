# Task 1/2/3 Native Runner Design

## Goal

Provide one repository-root command for native Task 1/2/3 reproduction without
requiring users to export QEMU, Linux, rootfs, model, or RT-Thread paths. The
interface follows the existing `run-native.sh` workflow while retaining the
current integration branch's runner, result gates, and evidence format.

## User Interface

The root script accepts exactly one mode and an optional output directory:

```text
./run-native.sh smoke [--output DIR]
./run-native.sh suite [--output DIR]
./run-native.sh stability [--output DIR]
```

`smoke` runs the existing smoke mode, `suite` runs the realtime suite, and
`stability` runs the 300-second stability mode. The default output is
`tmp/native-runs/<mode>-<UTC timestamp>`. An explicit output directory must be
empty, matching the underlying runner contract.

Advanced overrides remain optional rather than required: `QEMU`,
`NATIVE_INPUT_DIR`, `RTTHREAD_SRC`, and `NATIVE_OUTPUT_DIR`.

## Artifact Discovery

The script resolves inputs in this order:

1. An explicit advanced override.
2. Valid repository-relative local artifacts.
3. Accepted local evidence discovered by the existing structured resolver.
4. The existing runner's build/download fallback.

QEMU is resolved from `QEMU` or `PATH`. Linux kernel, initramfs, model, and
rootfs candidates are validated as readable nonempty files and canonicalized.
No workstation-specific path is encoded in the script.

RT-Thread source candidates are restricted to repositories under the project
parent's known local workspaces and the current repository `tmp` directory. A
candidate is accepted only when it contains pinned commit
`ddf52e2cdd977f14fc04035c88672ac204aec713`, the required commit-tree paths, no
missing Git objects for that commit, and no tracked or untracked worktree
changes. Git object checks disable lazy fetching so discovery cannot access the
network. When no complete local source exists, the underlying preparation path
may download the pinned source with visible progress.

## Runner Mapping

The wrapper invokes `os/axvisor/scripts/run_task123.sh` exactly once:

| Native mode | Runner invocation |
|---|---|
| `smoke` | `--mode smoke --task2-count 100 --task3-frames 3` |
| `suite` | `--mode realtime-suite --rtbench-samples 1000 --task2-count 1000` |
| `stability` | `--mode stability --seconds 300 --task2-count 30000` |

The wrapper sets only validated artifact environment variables. VM generation,
AxVisor builds, QEMU ownership, CPU affinity, network topology, marker
collection, and result gates remain owned by `run_task123.sh`.

## Output And Failure Behavior

Before starting, the script prints the selected mode, output directory, QEMU,
artifact paths and RT-Thread source. Runner progress remains live on the
terminal. Missing host tools fail with a direct diagnostic. Invalid explicit
overrides fail closed. Automatically discovered invalid candidates are skipped.
No existing output directory contents are deleted or overwritten.

## Verification

Contract tests use fake runners and isolated fixture artifacts to prove:

- all three modes map to the exact expected runner arguments;
- no exports are required for a complete local fixture;
- explicit overrides take precedence and invalid overrides fail closed;
- partial, dirty, wrong-commit, or incomplete RT-Thread repositories are
  rejected without network access;
- selected paths are absolute and identical to those received by the runner;
- output defaults are repository-relative and no workstation path is encoded;
- the existing runner lifecycle and result-gate contracts remain unchanged.
