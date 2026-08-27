# Axvisor RT-Thread Debug Code Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove experiment-only tracing and diagnostics from `rtthread-guest` without changing routed interrupt injection, RT-Thread core affinity, Linux dual-vCPU boot, RT-IPC, benchmarks, or reports, then publish exact code-size statistics.

**Architecture:** Treat cleanup as removal of observers around the production path, not a rollback of mixed feature commits. Capture the dirty worktree as a non-mutating Git baseline, remove `rt_trace` from its feature boundary inward, remove standalone diagnostic assets, restore production log levels, and verify absence contracts plus functional tests before recording results.

**Tech Stack:** Rust/Cargo, Bash, TOML, C/Make, Git numstat, Axvisor/AxVM, QEMU AArch64, RT-Thread 5.2.2, RT-IPC/UDP.

---

## File Map

**Delete runtime instrumentation and trace configuration:**

- `virtualization/axvm/src/rt_trace.rs`
- `os/axvisor/configs/board/qemu-aarch64-rt-trace.toml`
- `os/axvisor/configs/board/qemu-aarch64-three-guest-net-rt-trace.toml`
- `os/axvisor/configs/qemu/qemu-aarch64-three-guest-net-trace.toml`

**Delete diagnostic collectors and patches:**

- `os/axvisor/scripts/collect_qemu_sched_trace.sh`
- `os/axvisor/scripts/qemu_sched_probe.c`
- `os/axvisor/scripts/qemu_sched_thread_map.sh`
- `os/axvisor/scripts/run_qemu_vcpu_affinity.sh`
- `os/axvisor/scripts/test_qemu_sched_trace.sh`
- `os/axvisor/scripts/test_qemu_vcpu_affinity.sh`
- `docs/docs/build/axvisor/qemu-arm-ppi27-diagnostic.patch`
- `docs/docs/build/axvisor/qemu-mttcg-exclusive-diagnostic.patch`

**Modify instrumentation boundaries:**

- `virtualization/axvm/Cargo.toml`: remove the `rt-trace` feature.
- `os/axvisor/Cargo.toml`: remove forwarding of the `rt-trace` feature.
- `virtualization/axvm/src/lib.rs`: remove trace module and no-op facade.
- `virtualization/axvm/src/architecture/ops.rs`: remove guest entry/exit hooks.
- `virtualization/axvm/src/arch/aarch64/mod.rs`: remove exit-handler/deferred-finish hooks.
- `virtualization/axvm/src/timer.rs`: remove deadline publication hook.
- `virtualization/axvm/tests/arch_boundary_contract.rs`: remove the deleted file's architecture exception.
- `os/axvisor/scripts/test_rtbench_precision.sh`: remove only the deleted combined trace-board contract.

**Modify production logging:**

- `os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml`: restore `Info`.
- `os/axvisor/qemu-aarch64-two-guest-net`: restore `Info`.
- `virtualization/axvm/src/arch/aarch64/gic.rs`: remove the newly added per-injection debug statement while retaining LR programming and errors.

**Update retained record:**

- `docs/docs/build/axvisor/rtthread-realtime-report.md`: append cleanup inventory, verification status, and code-size tables without rewriting historical measurements.

**Protected dirty files:**

- `platforms/ax-plat/src/irq/aarch64_hv.rs`
- `platforms/axplat-dyn/src/irq/aarch64_hv.rs`
- `virtualization/axvm/src/arch/aarch64/irq.rs`
- `os/axvisor/patches/rtthread/0001-virtio-net-remove-rx-polling.patch`
- `run_test.sh`
- `run_committed_test.sh`

### Task 1: Capture the cleanup baseline and prove the absence contract fails

**Files:**

- Read: all paths listed above
- Create outside repository: `/tmp/axvisor-debug-cleanup-baseline`
- Create outside repository: `/tmp/axvisor-debug-cleanup-before-committed.numstat`
- Create outside repository: `/tmp/axvisor-debug-cleanup-before-worktree.numstat`

- [ ] **Step 1: Confirm branch and protected dirty state**

Run:

```bash
git branch --show-current
git status --short
```

Expected: branch is `rtthread-guest`; protected AArch64 IRQ files and both user scripts are present and unstaged.

- [ ] **Step 2: Create a non-mutating baseline commit object**

Run:

```bash
git stash create "pre debug cleanup" | tee /tmp/axvisor-debug-cleanup-baseline
test -s /tmp/axvisor-debug-cleanup-baseline
git status --short
```

Expected: the temporary file contains one commit hash and status is unchanged. `git stash create` must not alter the worktree or stash list.

- [ ] **Step 3: Capture committed and tracked-worktree baselines**

Run:

```bash
git diff --numstat dev...HEAD | tee /tmp/axvisor-debug-cleanup-before-committed.numstat
git diff --numstat dev | tee /tmp/axvisor-debug-cleanup-before-worktree.numstat
```

Expected: both files are non-empty. Binary rows may contain `-` and are counted separately later.

- [ ] **Step 4: Run the cleanup absence contract before deletion**

Run:

```bash
test ! -e virtualization/axvm/src/rt_trace.rs \
  && ! rg -n 'rt-trace|crate::rt_trace' virtualization/axvm os/axvisor/Cargo.toml \
  && test ! -e os/axvisor/scripts/collect_qemu_sched_trace.sh \
  && test ! -e os/axvisor/configs/qemu/qemu-aarch64-three-guest-net-trace.toml
```

Expected: FAIL because instrumentation and diagnostic assets still exist. This is the red phase for the removal contract.

### Task 2: Remove AxVM runtime tracing at the feature boundary

**Files:**

- Delete: `virtualization/axvm/src/rt_trace.rs`
- Modify: `virtualization/axvm/Cargo.toml`
- Modify: `os/axvisor/Cargo.toml`
- Modify: `virtualization/axvm/src/lib.rs`
- Modify: `virtualization/axvm/src/architecture/ops.rs`
- Modify: `virtualization/axvm/src/arch/aarch64/mod.rs`
- Modify: `virtualization/axvm/src/timer.rs`
- Modify: `virtualization/axvm/tests/arch_boundary_contract.rs`

- [ ] **Step 1: Remove feature declarations and trace facade**

The resulting Cargo feature tables contain no `rt-trace` key. In `virtualization/axvm/src/lib.rs` the module list flows directly from `percpu` to `runtime`:

```rust
mod npt;
mod percpu;
mod runtime;
mod task;
```

Delete both the real module declaration and no-op `rt_trace` module, then delete `virtualization/axvm/src/rt_trace.rs`.

- [ ] **Step 2: Remove all runtime hook calls**

Remove these calls without changing adjacent control flow:

```rust
crate::rt_trace::guest_entry(vm_id, vcpu_id);
crate::rt_trace::guest_exit(vm_id, vcpu_id);
crate::rt_trace::exit_handler_return(vm.id(), vcpu.id(), vector as usize);
crate::rt_trace::deferred_finish(vm.id(), vcpu.id());
crate::rt_trace::axvm_deadline_publish(deadline_nanos);
```

If `vm_id` becomes unused in `run_vcpu_bound`, remove only that local binding. Keep `vcpu_id` because interrupt delivery uses it.

- [ ] **Step 3: Remove the architecture scan exception**

The boundary test must inspect every Rust file:

```rust
if path.extension().is_some_and(|extension| extension == "rs")
    && std::fs::read_to_string(&path)
        .expect("AxVM source file must be readable")
        .contains("target_arch")
{
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
! rg -n 'rt-trace|crate::rt_trace' virtualization/axvm os/axvisor/Cargo.toml
cargo test -p axvm --test arch_boundary_contract
```

Expected: search returns no matches and `arch_boundary_contract` passes.

- [ ] **Step 5: Protect pre-existing dirty hunks**

Inspect `git diff -- <file>` for every modified file. On already dirty files, stage only cleanup hunks with an index-only patch; never use whole-file `git add`. Verify:

```bash
git diff --cached --check
git diff --cached --stat
```

Expected: cached content contains only trace removal. If exact staging cannot be proven, leave implementation unstaged rather than committing unrelated work.

- [ ] **Step 6: Commit the isolated trace removal when staging is exact**

Run:

```bash
git commit -m "refactor(axvm): remove realtime trace instrumentation"
```

Expected: the commit contains only the files and hunks described in Task 2. If Task 2 remained unstaged for safety, skip this command and record that reason.

### Task 3: Remove standalone diagnostics and repair the retained precision test

**Files:**

- Delete: the eleven diagnostic config/script/patch paths in the file map
- Modify: `os/axvisor/scripts/test_rtbench_precision.sh`

- [ ] **Step 1: Establish the precision-test baseline**

Run:

```bash
bash os/axvisor/scripts/test_rtbench_precision.sh
```

Expected: PASS before deletion, proving the retained benchmark test is healthy.

- [ ] **Step 2: Remove only the combined trace-board contract**

Delete `THREE_GUEST_RT_TRACE_BOARD_CONFIG`. Invoke the embedded Python with production and generic configs only:

```bash
python3 - \
  "$THREE_GUEST_BOARD_CONFIG" \
  "$GENERIC_BOARD_CONFIG" <<'PY' \
  || fail_test "checked-in QEMU board feature contracts"
```

Delete all `combined_path` and `combined_features` assertions. Renumber inputs:

```python
three_guest_path = pathlib.Path(sys.argv[1])
generic_path = pathlib.Path(sys.argv[2])
```

Replace the production board's feature-count checks with an exact multiset contract, which rejects every extra feature without retaining the removed trace feature name:

```python
expected_three_guest_features = collections.Counter({
    "ax-driver/nvme": 1,
    "fs": 1,
    reservation_feature: 1,
})
assert collections.Counter(three_guest_features) == expected_three_guest_features, (
    f"{three_guest_path}: expected feature multiset="
    f"{dict(expected_three_guest_features)!r}, actual={three_guest_features!r}"
)
```

Retain benchmark source checks, topology checks, artifact checks, and rootfs checks.

- [ ] **Step 3: Delete standalone diagnostic assets**

Delete exactly:

```text
os/axvisor/configs/board/qemu-aarch64-rt-trace.toml
os/axvisor/configs/board/qemu-aarch64-three-guest-net-rt-trace.toml
os/axvisor/configs/qemu/qemu-aarch64-three-guest-net-trace.toml
os/axvisor/scripts/collect_qemu_sched_trace.sh
os/axvisor/scripts/qemu_sched_probe.c
os/axvisor/scripts/qemu_sched_thread_map.sh
os/axvisor/scripts/run_qemu_vcpu_affinity.sh
os/axvisor/scripts/test_qemu_sched_trace.sh
os/axvisor/scripts/test_qemu_vcpu_affinity.sh
docs/docs/build/axvisor/qemu-arm-ppi27-diagnostic.patch
docs/docs/build/axvisor/qemu-mttcg-exclusive-diagnostic.patch
```

- [ ] **Step 4: Re-run the retained precision test**

Run:

```bash
bash os/axvisor/scripts/test_rtbench_precision.sh
```

Expected: PASS without deleted trace configs or scheduler collectors.

- [ ] **Step 5: Check live references while retaining historical evidence**

Run:

```bash
rg -n 'qemu_sched|vcpu_affinity|rt-trace|three-guest-net-trace|ppi27-diagnostic|mttcg-exclusive-diagnostic' \
  --glob '!docs/superpowers/**' --glob '!docs/docs/build/axvisor/*report*.md' \
  --glob '!docs/docs/build/axvisor/rtos-realtime-iterations.csv' \
  --glob '!target/**' --glob '!tmp/**'
```

Expected: no live code/config/script references. Historical report and CSV references remain excluded as evidence.

- [ ] **Step 6: Commit the diagnostic asset cleanup**

Run:

```bash
git add \
  os/axvisor/configs/board/qemu-aarch64-rt-trace.toml \
  os/axvisor/configs/board/qemu-aarch64-three-guest-net-rt-trace.toml \
  os/axvisor/configs/qemu/qemu-aarch64-three-guest-net-trace.toml \
  os/axvisor/scripts/collect_qemu_sched_trace.sh \
  os/axvisor/scripts/qemu_sched_probe.c \
  os/axvisor/scripts/qemu_sched_thread_map.sh \
  os/axvisor/scripts/run_qemu_vcpu_affinity.sh \
  os/axvisor/scripts/test_qemu_sched_trace.sh \
  os/axvisor/scripts/test_qemu_vcpu_affinity.sh \
  os/axvisor/scripts/test_rtbench_precision.sh \
  docs/docs/build/axvisor/qemu-arm-ppi27-diagnostic.patch \
  docs/docs/build/axvisor/qemu-mttcg-exclusive-diagnostic.patch
git diff --cached --check
git commit -m "chore(axvisor): remove realtime diagnostic assets"
```

Expected: one commit containing only the deleted diagnostics and precision-test adaptation.

### Task 4: Restore production logging and remove new event-level output

**Files:**

- Modify: `os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml`
- Modify: `os/axvisor/qemu-aarch64-two-guest-net`
- Modify: `virtualization/axvm/src/arch/aarch64/gic.rs`

- [ ] **Step 1: Prove the production log-level contract fails**

Run:

```bash
rg -n '^log = "Debug"$' \
  os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml \
  os/axvisor/qemu-aarch64-two-guest-net
```

Expected: two matches.

- [ ] **Step 2: Restore Info level**

Both files must contain:

```toml
log = "Info"
```

Do not change topology, feature lists, QEMU arguments, or image paths.

- [ ] **Step 3: Remove only the new external-interrupt debug statement**

The function must begin directly with functional GIC access:

```rust
pub(crate) fn inject_external_interrupt(vector: usize, physical_intid: usize) {
    with_gic(|gic| {
```

Keep LR `HW`/`PINTID` programming, duplicate-vector handling, and warning/error logs. Keep older generic GIC `debug!` calls because they predate this branch and are suppressed by `Info`.

- [ ] **Step 4: Verify logging and interrupt semantics**

Run:

```bash
! rg -n '^log = "Debug"$' \
  os/axvisor/configs/board/qemu-aarch64-two-guest-net.toml \
  os/axvisor/qemu-aarch64-two-guest-net
rg -n 'ICH_LR_EL2::HW::SET|ICH_LR_EL2::PINTID' virtualization/axvm/src/arch/aarch64/gic.rs
rg -n 'defer_deactivation_to_guest' platforms virtualization/axvm
```

Expected: no Debug-level production config; hardware-backed LR and deferred deactivation searches return matches.

- [ ] **Step 5: Commit only verified logging cleanup hunks**

Stage the two clean TOML/config files normally and stage only the event-log deletion hunk from the already dirty GIC source. Then run:

```bash
git diff --cached --check
git diff --cached --stat
git commit -m "chore(axvisor): restore production logging"
```

Expected: the commit changes two `Debug` values to `Info` and removes one debug statement; it contains no LR or interrupt-routing logic changes.

### Task 5: Verify behavior and record code-size results

**Files:**

- Modify: `docs/docs/build/axvisor/rtthread-realtime-report.md`
- Read: the `/tmp/axvisor-debug-cleanup-*` baseline files

- [ ] **Step 1: Run formatting and static cleanup checks**

Run:

```bash
cargo fmt --all -- --check
git diff --check
test ! -e virtualization/axvm/src/rt_trace.rs \
  && ! rg -n 'rt-trace|crate::rt_trace' virtualization/axvm os/axvisor/Cargo.toml \
  && test ! -e os/axvisor/scripts/collect_qemu_sched_trace.sh \
  && test ! -e os/axvisor/configs/qemu/qemu-aarch64-three-guest-net-trace.toml
```

Expected: all commands return zero; the Task 1 absence contract is green.

- [ ] **Step 2: Run focused Rust and RT-IPC tests**

Run:

```bash
cargo test -p axvm --test arch_boundary_contract
make -C os/axvisor/guests/rt-ipc/tests clean all test
make -C os/axvisor/guests/rt-ipc/tests reliability-test
```

Expected: AxVM contract tests pass, RT-IPC protocol reports 8/8, and reliability reports 3/3.

- [ ] **Step 3: Build retained Axvisor configuration**

Run:

```bash
cargo build -p axvisor --features qemu-aarch64-two-guest-net
```

Expected: build succeeds. If the host target cannot build the bare-metal feature set, run the repository's existing AArch64 Axvisor build command and record the exact environment limitation.

- [ ] **Step 4: Run available QEMU/RT-IPC smoke**

Run:

```bash
bash os/axvisor/scripts/run_rtipc_test.sh
```

Expected: Linux and RT-Thread boot, virtio-net remains interrupt-driven, and RT-IPC completes. If images or host capabilities are absent, record command, exit status, and missing prerequisite without claiming PASS.

- [ ] **Step 5: Calculate cleanup and branch totals**

Run:

```bash
baseline_commit="$(cat /tmp/axvisor-debug-cleanup-baseline)"
git diff --numstat "$baseline_commit" -- > /tmp/axvisor-debug-cleanup-change.numstat
git diff --numstat dev...HEAD > /tmp/axvisor-debug-cleanup-after-committed.numstat
git diff --numstat dev > /tmp/axvisor-debug-cleanup-after-worktree.numstat
for file in /tmp/axvisor-debug-cleanup-*.numstat; do
  awk -v name="$file" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { files++; added += $1; deleted += $2; next }
    { binaries++ }
    END { printf "%s files=%d added=%d deleted=%d net=%d binaries=%d\n", name, files, added, deleted, added-deleted, binaries }
  ' "$file"
done
wc -l \
  platforms/ax-plat/src/irq/aarch64_hv.rs \
  platforms/axplat-dyn/src/irq/aarch64_hv.rs \
  virtualization/axvm/src/arch/aarch64/irq.rs \
  os/axvisor/patches/rtthread/0001-virtio-net-remove-rx-polling.patch
```

Expected: output includes cleanup-only, before/after committed, and before/after tracked-worktree totals. The final `wc` reports protected untracked implementation separately; user scripts are excluded.

- [ ] **Step 6: Calculate subsystem totals**

Run:

```bash
git diff --numstat dev -- | awk '
  $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { binaries++; next }
  {
    path=$3
    if (path ~ /^os\/axvisor\/guests\/rt-ipc\//) group="RT-IPC"
    else if (path ~ /^os\/axvisor\//) group="Axvisor/guest"
    else if (path ~ /^virtualization\//) group="virtualization"
    else if (path ~ /^platforms\//) group="platforms"
    else if (path ~ /^docs\//) group="docs/tests"
    else group="other"
    files[group]++; added[group]+=$1; deleted[group]+=$2
  }
  END {
    for (group in files)
      printf "%s files=%d added=%d deleted=%d net=%d\n", group, files[group], added[group], deleted[group], added[group]-deleted[group]
    printf "binary rows=%d\n", binaries
  }' | sort
```

Expected: one row per subsystem plus binary count.

- [ ] **Step 7: Append exact results to the Chinese report**

Append a dated section with this structure:

```markdown
## 调试代码清理（2026-08-12）

- 清理范围：运行时 rt_trace、调度诊断配置/脚本/补丁、Debug 级生产配置和新增的逐中断日志。
- 保留范围：硬件 LR 即时注入、SPI 路由、延迟 deactivate、RT-IPC、实时基准、历史数据和错误日志。
- 验证结果：每条实际命令的 PASS、FAIL 或未运行原因。
- 代码量：清理动作、相对 dev 的已提交状态、包含工作树状态和各子系统统计。
- 历史说明：报告中提到的 QEMU 诊断补丁与调度 trace 文件是当时实验依据，源文件已在产品清理中移除。
```

Replace descriptions with exact numbers and command results. Do not alter previous benchmark values or claim an unexecuted QEMU smoke passed.

- [ ] **Step 8: Final protected-state review**

Run:

```bash
git status --short
git diff --check
test -f run_test.sh
test -f run_committed_test.sh
test -f platforms/ax-plat/src/irq/aarch64_hv.rs
test -f platforms/axplat-dyn/src/irq/aarch64_hv.rs
test -f virtualization/axvm/src/arch/aarch64/irq.rs
test -f os/axvisor/patches/rtthread/0001-virtio-net-remove-rx-polling.patch
```

Expected: all protected files remain, whitespace checks pass, and status contains no unexpected generated artifacts.

- [ ] **Step 9: Commit the measured report update**

Run:

```bash
git add docs/docs/build/axvisor/rtthread-realtime-report.md
git diff --cached --check
git commit -m "docs(axvisor): record debug cleanup and code size"
```

Expected: the commit contains only the appended cleanup and measurement section.
