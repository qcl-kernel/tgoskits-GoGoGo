# Task 1/2/3 Native Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repository-root `run-native.sh` that reproduces the current Task 1/2/3 integration with one command and no required environment exports.

**Architecture:** The root wrapper performs only argument parsing, host-tool and local-artifact discovery, and mode mapping. It exports validated immutable paths to the existing `run_task123.sh`, which continues to own VM construction, AxVisor builds, CPU affinity, QEMU lifecycle, networking, result gates, and evidence generation.

**Tech Stack:** Bash 5, Git object verification, existing Task 1/2/3 shell runner and shell contract tests.

---

## File Structure

- Create `run-native.sh`: user-facing native entry, mode mapping and validated
  artifact discovery.
- Create `os/axvisor/scripts/test_run_native.sh`: isolated contract tests using
  fake runner/QEMU and fixture artifacts.
- Modify `docs/docs/build/axvisor/task123-reproduction-cn.md`: make the root
  command the primary reproduction flow and document optional overrides.
- Modify `os/axvisor/scripts/test_task123_docs_contract.sh`: require the new
  command and executable contract test.

### Task 1: Native Entry And Mode Mapping

**Files:**
- Create: `run-native.sh`
- Create: `os/axvisor/scripts/test_run_native.sh`

- [ ] **Step 1: Write failing command-contract tests**

Create a fixture root containing executable fake `run_task123.sh`, a fake
`qemu-system-aarch64` in `PATH`, Linux Image, initramfs, model and rootfs. Invoke `run-native.sh` with test-only
path overrides and assert these exact mappings:

```text
smoke     -> --mode smoke --task2-count 100 --task3-frames 3
suite     -> --mode realtime-suite --rtbench-samples 1000 --task2-count 1000
stability -> --mode stability --seconds 300 --task2-count 30000
```

Assert the runner receives an absolute, empty output directory and that no
ambient export is required. Add failures for duplicate modes, unknown options,
nonempty output and missing explicit input.

- [ ] **Step 2: Verify RED**

Run:

```bash
bash os/axvisor/scripts/test_run_native.sh
```

Expected: FAIL because the integration worktree has no root `run-native.sh`.

- [ ] **Step 3: Implement minimal entry and mapping**

Implement:

```text
./run-native.sh [smoke|suite|stability] [--output DIR]
```

Default to `smoke`. Resolve the script root from `BASH_SOURCE`, canonicalize the
underlying runner, reject unsafe/nonempty output directories, print the selected
mode/output/QEMU/artifacts, then invoke the runner once with the mapped arguments.
Use an array for runner arguments and `env` for the exact allowlisted artifact
variables.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
bash os/axvisor/scripts/test_run_native.sh
bash -n run-native.sh os/axvisor/scripts/test_run_native.sh
git diff --check
```

Expected: all commands exit 0 and the contract test prints PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add run-native.sh os/axvisor/scripts/test_run_native.sh
git commit -m "feat(axvisor): add native task123 entry"
```

### Task 2: Automatic Local Artifact Discovery

**Files:**
- Modify: `run-native.sh`
- Modify: `os/axvisor/scripts/test_run_native.sh`

- [ ] **Step 1: Add failing discovery tests**

Create isolated candidates proving this precedence:

```text
explicit override > repository-local conventional path > accepted resolver evidence > runner fallback
```

For RT-Thread, create Git fixtures for complete/clean, partial/missing-object,
dirty, wrong-commit and missing-tree candidates. Wrap `git` so any HTTP(S) fetch
exits 97 and assert complete local discovery performs no network operation.
Assert an explicit invalid RT-Thread source fails closed.

- [ ] **Step 2: Verify RED**

Run the Task 1 contract. Expected: FAIL on automatic discovery cases.

- [ ] **Step 3: Implement validated discovery**

Require `qemu-system-aarch64` in `PATH` and leave its execution to the existing
runner without exporting `QEMU`. Resolve artifacts from optional
`NATIVE_INPUT_DIR`, repository-relative conventional paths and the existing
`task123_artifacts.py resolve` output. Validate each selected file as readable,
regular and nonempty before exporting it.

Discover RT-Thread repositories only below the current root `tmp`, the parent
workspace's repository-local cache directories, and an explicit `RTTHREAD_SRC`.
Use `GIT_NO_LAZY_FETCH=1` for `cat-file`, `rev-list --missing=print`, and tree
checks. Require pinned commit, required trees, zero missing objects and a clean
worktree. If no valid local source exists, leave `RTTHREAD_REPOSITORY` unset so
the runner downloads the fixed version.

- [ ] **Step 4: Verify GREEN And Regression Contracts**

Run:

```bash
bash os/axvisor/scripts/test_run_native.sh
bash os/axvisor/scripts/test_prepare_task123_artifacts.sh
bash os/axvisor/scripts/test_reproduce_task123.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
git diff --check
```

Expected: every contract exits 0 and prints PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add run-native.sh os/axvisor/scripts/test_run_native.sh
git commit -m "fix(axvisor): discover native task123 inputs"
```

### Task 3: Documentation And Real Smoke Verification

**Files:**
- Modify: `docs/docs/build/axvisor/task123-reproduction-cn.md`
- Modify: `os/axvisor/scripts/test_task123_docs_contract.sh`

- [ ] **Step 1: Add failing documentation contract**

Require the guide to contain executable `run-native.sh`, all three modes, default
output location, optional overrides and the distinction between smoke/suite/
stability. Require both root script and contract test to be executable.

- [ ] **Step 2: Verify RED**

Run:

```bash
bash os/axvisor/scripts/test_task123_docs_contract.sh
```

Expected: FAIL because the guide does not yet present the root native command.

- [ ] **Step 3: Update the Chinese guide**

Place this first in the reproduction section:

```bash
./run-native.sh smoke
./run-native.sh suite
./run-native.sh stability
```

Document output files, live log path, automatic local selection and the optional
`--output`, `NATIVE_INPUT_DIR`, and `RTTHREAD_SRC` overrides. Explain that
formal realtime evidence must run directly on the host.

- [ ] **Step 4: Run focused verification**

Run all contracts from Task 2 plus docs contract, `bash -n`, and `git diff
--check`. Expected: all exit 0.

- [ ] **Step 5: Run real local smoke**

Confirm no Task 1/2/3 QEMU is active, then run:

```bash
./run-native.sh smoke
```

Expected terminal markers:

```text
LINUX_SMP_READY configured=2
TASK2_LINUX_END status=PASS
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
result_gate=PASS
```

Record the generated output path. Do not run suite or 300-second stability until
smoke passes.

- [ ] **Step 6: Commit Task 3**

```bash
git add docs/docs/build/axvisor/task123-reproduction-cn.md \
  os/axvisor/scripts/test_task123_docs_contract.sh
git commit -m "docs(axvisor): document native task123 runner"
```

- [ ] **Step 7: Final audit**

Run `git status --short --branch` and `git log --oneline -6`. Confirm only
pre-existing unrelated one-click/cache-plan changes remain uncommitted.
