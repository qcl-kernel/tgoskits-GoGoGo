# Task123 One-Command Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a root-level command that runs the existing real-QEMU Linux/StarryOS Task123 comparison in quick mode by default and in 3600-second mode on request.

**Architecture:** Keep `os/axvisor/scripts/run_task123_guest_comparison.sh` as the only implementation of guest build, QEMU lifecycle, protocol tests, AI tests, RTBench, resource sampling, and result gates. Add `run-task123.sh` as a thin argument-normalizing wrapper that resolves paths relative to the repository and tees a top-level log without pre-populating the runner output directory. Add a shell contract test using the comparison runner's existing `TASK123_COMPARISON_RUNNER` override to verify argument forwarding without starting QEMU.

**Tech Stack:** Bash 5+, `realpath`, `git`, `qemu-system-aarch64`, existing AxVisor shell/Python runners.

---

### Task 1: Add the failing entrypoint contract test

**Files:**
- Create: `os/axvisor/scripts/test_task123_entrypoint.sh`
- Test target: `run-task123.sh`

- [ ] **Step 1: Write the failing test**

Create an executable Bash test using a temporary `TASK123_COMPARISON_RUNNER`. The temporary runner records its NUL-separated arguments, extracts `--output`, creates that directory, and writes `fake-runner-called`. The test must:

```bash
"$ENTRYPOINT" --help
"$ENTRYPOINT" --bad-option  # must fail and must not call the runner
TASK123_COMPARISON_RUNNER="$fake" "$ENTRYPOINT" --quick --allow-qemu-timer-limit --output "$quick"
TASK123_COMPARISON_RUNNER="$fake" "$ENTRYPOINT" --long --cache "$cache" --output "$long"
```

Assertions must verify that quick forwards `--quick` and `--allow-qemu-timer-limit`, long maps to `--full` and forwards `--cache`, both output directories contain the fake marker and `run.log`, and the invalid invocation does not create the argument capture file. The test may replace only the comparison runner; the entrypoint must still perform its real `qemu-system-aarch64` availability check.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash os/axvisor/scripts/test_task123_entrypoint.sh
```

Expected: failure because `run-task123.sh` does not exist.

- [ ] **Step 3: Commit the failing test**

```bash
git add os/axvisor/scripts/test_task123_entrypoint.sh
git commit -m "test: define task123 entrypoint contract"
```

### Task 2: Implement the thin root-level entrypoint

**Files:**
- Create: `run-task123.sh`

- [ ] **Step 1: Implement the wrapper**

Implement a Bash script with `set -Eeuo pipefail` and root resolution based on `BASH_SOURCE`. Its default runner is `os/axvisor/scripts/run_task123_guest_comparison.sh`, overridable only for tests through the existing `TASK123_COMPARISON_RUNNER` convention. Parse exactly `--quick`, `--long`, `--output DIR`, `--cache DIR`, `--allow-qemu-timer-limit`, and `--help`; reject duplicate or unknown options before launching anything.

The wrapper must resolve and validate `qemu-system-aarch64`, `git`, and the comparison runner with `realpath -e`; reject `/`, the repository root, non-directory output, and non-empty output directories; create default output parents under `tmp/task123-runs/<mode>-<UTC timestamp>`; and create cache parents without deleting existing cache content. It must not export required environment variables or download dependencies.

Build the downstream arguments as follows:

```bash
mode=quick  -> runner_args=(--quick)
mode=long   -> runner_args=(--full)
always      -> runner_args+=(--output "$output")
cache set   -> runner_args+=(--cache "$cache")
timer flag  -> runner_args+=(--allow-qemu-timer-limit)
```

Print the mode, runner, output, and fully quoted command. Pipe the runner's combined stdout/stderr through `tee` to a temporary sibling log, capture the runner status with `PIPESTATUS[0]`, then copy the complete log to `<output>/run.log`. If the runner failed before creating the output directory, create it only after the runner exits so the runner still receives an empty/nonexistent output path. Return the original runner status.

- [ ] **Step 2: Mark the wrapper executable**

Run:

```bash
chmod 0755 run-task123.sh
```

- [ ] **Step 3: Run contract and syntax checks**

Run:

```bash
bash -n run-task123.sh os/axvisor/scripts/test_task123_entrypoint.sh
bash os/axvisor/scripts/test_task123_entrypoint.sh
```

Expected: `task123 entrypoint contract: PASS`.

- [ ] **Step 4: Commit the implementation**

```bash
git add run-task123.sh os/axvisor/scripts/test_task123_entrypoint.sh
git commit -m "feat: add one-command task123 runner"
```

### Task 3: Document and execute the real quick validation

**Files:**
- Modify: `docs/docs/quickstart/starryos.md`

- [ ] **Step 1: Document the canonical commands**

Add the following usage contract near the existing Task123 comparison commands:

```markdown
./run-task123.sh
./run-task123.sh --long --allow-qemu-timer-limit
```

Document that the first command is the short default, the second is the 3600-second run, both use PATH's real `qemu-system-aarch64`, neither downloads dependencies nor uses fake-QEMU, and the printed output directory contains `run.log`, both guest results, `comparison.json`, and the Markdown report.

- [ ] **Step 2: Check documentation and shell formatting**

Run:

```bash
git diff --check
bash -n run-task123.sh os/axvisor/scripts/test_task123_entrypoint.sh
```

Expected: status 0 for both commands.

- [ ] **Step 3: Run the real quick test**

Run:

```bash
./run-task123.sh --quick --allow-qemu-timer-limit \
  --output "$PWD/tmp/task123-runs/quick-validation"
```

Expected: the existing comparison runner starts real QEMU for Linux and StarryOS, performs the network, AI, RTBench, and conditional timer gates, and publishes the comparison result files. The command must return nonzero for any network, AI, or runner failure.

- [ ] **Step 4: Verify output files**

Run:

```bash
test -s tmp/task123-runs/quick-validation/run.log
test -s tmp/task123-runs/quick-validation/comparison/comparison.json
test -s tmp/task123-runs/quick-validation/comparison/comparison-report.md
```

- [ ] **Step 5: Commit the documentation**

```bash
git add docs/docs/quickstart/starryos.md
git commit -m "docs: document task123 one-command reproduction"
```
