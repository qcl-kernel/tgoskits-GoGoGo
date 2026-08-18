# Historical Documentation Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `starryos-replace` 与 `tgoskits` 中的历史 Task 1/2 和 Task 1/2/3 文档安全迁移到 `/home/yfblock/Code/hyper-rtos/history-docs`，按阶段、类型、日期和来源归档，并提供可验证的来源清单。

**Architecture:** 在 `scripts/repo/` 中增加一个默认只读的 Bash 归档器和独立规则表。归档器先从两个 Git worktree 生成冻结清单，再复制到临时目录、生成 JSON manifest 和索引、校验大小与 SHA-256，最后通过独立 `delete` 子命令删除已验证源文件；未分类文件、路径冲突、哈希变化或意外 Git 状态都会在删除前失败。

**Tech Stack:** Bash 5、Git、`jq`、`sha256sum`、`rsync`、现有 shell contract-test 风格。

---

## File Map

- Create: `scripts/repo/history-docs-rules.tsv` — 有序的 include/exclude、阶段和类型规则，不包含工作站绝对路径。
- Create: `scripts/repo/archive-history-docs.sh` — inventory、stage、verify、delete 四阶段归档器。
- Create: `scripts/repo/test-archive-history-docs.sh` — 使用临时 Git 仓库验证分类、排除、重复、冲突和删除保护。
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/INDEX.md` — 按 `task12`、`task123`、类型和日期列出的入口。
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/manifest.json` — 每个归档文件的机器可读来源、分类和哈希。
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv` — 实际执行前冻结的清单。
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/migration-report.md` — 来源版本、数量、重复组、链接检查和最终状态。
- Move: `starryos-replace` 与 `tgoskits` 中清单选中的历史文档 — 目标保留原始相对路径。
- Modify: 仍保留在两个源 worktree 中且引用已迁移文件的 Markdown 文档 — 仅修复实际扫描发现的本地链接。

### Task 1: Add Classification Contract Tests

**Files:**
- Create: `scripts/repo/test-archive-history-docs.sh`
- Test: `scripts/repo/test-archive-history-docs.sh`

- [ ] **Step 1: Create fixture repositories and expected inventory**

测试脚本使用 `mktemp -d` 创建 `task12-source` 和 `task123-source` 两个 Git 仓库，并写入以下固定用例：

```text
task12-source/docs/README.md                                      excluded
task12-source/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md
task12-source/docs/superpowers/plans/2026-08-15-task1-task2-implementation.md
task12-source/docs/docs/build/axvisor/task1-2026-08-15-run.log
task12-source/docs/docs/build/axvisor/shared-evidence.log
task12-source/docs/docs/architecture/axvisor/overview.md          excluded
task12-source/apps/demo/validation/baseline.txt                   excluded
task123-source/docs/reports/starryos-linux-stability-comparison.md
task123-source/docs/superpowers/plans/2026-08-18-task123-native-runner.md
task123-source/docs/docs/build/axvisor/shared-evidence.log
task123-source/os/axvisor/guests/task3/docs/results/task3-report.md
task123-source/os/axvisor/guests/task3/docs/results/evidence/normal/summary.json
```

两个 `shared-evidence.log` 内容完全相同，用于验证跨来源重复组。除 `task1-2026-08-15-run.log` 外均提交；该日志保持未跟踪状态，以验证 `tracked=false` 和修改时间日期来源。测试固定 Git author/committer 时间为 `2026-08-17T12:00:00Z`，并使用 `touch -d 2026-08-15T12:00:00Z` 固定未跟踪日志时间，避免依赖主机配置。

- [ ] **Step 2: Assert exact phase/type/date mappings**

脚本调用尚不存在的归档器：

```bash
scripts/repo/archive-history-docs.sh inventory \
  --rules scripts/repo/history-docs-rules.tsv \
  --source task12-source="$fixture_root/task12-source" \
  --source task123-source="$fixture_root/task123-source" \
  --output "$fixture_root/inventory.tsv"
```

用 `awk` 和 `diff -u` 断言设计、计划、报告、结果证据分别映射到：

```text
task12 design 2026-08-11
task12 plan   2026-08-15
task12 evidence 2026-08-15
task123 report 2026-08-18
task123 plan   2026-08-18
task123 report 2026-08-17
task123 evidence 2026-08-17
```

同时断言 README、活动架构文档和测试基线不出现在 inventory 中。

- [ ] **Step 3: Run the test and verify the expected failure**

Run:

```bash
bash scripts/repo/test-archive-history-docs.sh
```

Expected: FAIL，错误指出 `scripts/repo/archive-history-docs.sh` 或规则表不存在。

- [ ] **Step 4: Commit the failing contract test**

```bash
git add scripts/repo/test-archive-history-docs.sh
git commit -m "test(repo): define history archive contracts"
```

### Task 2: Implement Inventory And Classification

**Files:**
- Create: `scripts/repo/history-docs-rules.tsv`
- Create: `scripts/repo/archive-history-docs.sh`
- Modify: `scripts/repo/test-archive-history-docs.sh`
- Test: `scripts/repo/test-archive-history-docs.sh`

- [ ] **Step 1: Define ordered include and exclusion rules**

`history-docs-rules.tsv` 使用五列：`action`、`path_regex`、`phase`、`type`、`reason`。规则从上到下匹配，第一条命中生效。以下代码块用 `\t` 表示实际制表符：

```text
exclude\t(^|/)README([^/]*)$\t\t\trepository entry point
exclude\t(^|/)(CHANGELOG|AGENTS|CLAUDE)([^/]*)$\t\t\trepository metadata
exclude\t^apps/.*/(validation|golden)/.*\.txt$\t\t\ttest baseline
exclude\t^apps/starry/qemu/syscall-test/syscalls/.*\.txt$\t\t\tsyscall test list
exclude\t^(book/design|docs/docs/architecture|memory/.*/docs|virtualization/.*/docs)/\t\t\tactive reference
include\t^os/axvisor/guests/task3/docs/results/evidence/\ttask123\tevidence\ttask3 raw evidence
include\t^os/axvisor/guests/task3/docs/results/.*\.md$\ttask123\treport\ttask3 report
include\t^os/axvisor/guests/task3/docs/superpowers/specs/.*-design\.md$\ttask123\tdesign\ttask3 design
include\t^os/axvisor/guests/task3/docs/superpowers/plans/.*\.md$\ttask123\tplan\ttask3 plan
include\t^os/axvisor/guests/task3/docs/protocol\.md$\ttask123\tspec\ttask3 protocol
include\t^docs/reports/.*\.md$\ttask123\treport\tintegrated reports
include\t^docs/superpowers/specs/.*(task123|starryos|native-runner|one-click|local-first|stability|history-docs).*\.md$\ttask123\tdesign\ttask123 design
include\t^docs/superpowers/plans/.*(task123|starryos|native-runner|one-click|local-first|stability|history-docs).*\.md$\ttask123\tplan\ttask123 plan
include\t^docs/superpowers/specs/.*\.md$\ttask12\tdesign\ttask12 design
include\t^docs/superpowers/plans/.*\.md$\ttask12\tplan\ttask12 plan
include\t^docs/docs/build/axvisor/task123.*(reproduction|复现).*\.md$\ttask123\tguide\tintegrated reproduction guide
include\t^docs/docs/build/axvisor/rtthread-reproduction\.md$\ttask12\tguide\ttask12 reproduction guide
include\t^docs/docs/build/axvisor/task123.*\.md$\ttask123\treport\tintegrated report
include\t^docs/docs/build/axvisor/.*(report|progress|status).*\.md$\ttask12\treport\ttask12 report
include\t^docs/docs/build/axvisor/rtos-realtime-iterations\.(csv|png)$\ttask12\tresult\trealtime result data
include\t^docs/docs/build/axvisor/.*\.(log|csv|json|tsv|txt)$\ttask12\tevidence\ttask12 evidence
```

规则还要显式包含已盘点的 `docs/design/axvisor-virtio-net.md`、`docs/qperf-virtio-optimization-report.md`、`docs/qperf-starryos-integration-report.md` 和 `docs/spin-migration-tracking.md`，分别映射到与内容一致的阶段和类型。`docs/blog`、`docs/community`、一般构建指南以及未命中规则的文件默认保留，不进行隐式全目录归档。

- [ ] **Step 2: Implement the read-only inventory command**

`archive-history-docs.sh` 必须使用以下接口：

```text
archive-history-docs.sh inventory --rules FILE --source NAME=PATH... --output FILE
archive-history-docs.sh stage --inventory FILE --destination DIR
archive-history-docs.sh verify --inventory FILE --destination DIR
archive-history-docs.sh delete --inventory FILE --destination DIR
```

实现要求：

- `set -euo pipefail`，所有临时目录由 `mktemp -d` 创建并用 trap 清理；
- 不硬编码两个 worktree 或目标路径，所有根目录从参数取得；
- 使用 `git ls-files -z` 与 `git ls-files --others --exclude-standard -z` 合并候选；
- 只接受普通文件，不跟随源目录外的符号链接；
- 规则只处理 `.md`、`.txt`、`.log`、`.json`、`.csv`、`.tsv`，以及被 Markdown 历史报告明确引用的 `.png` 结果图；
- 从文件名收集全部 `YYYY-MM-DD` token；恰好一个合法日期时使用文件名，多个合法日期失败，无合法日期时
  `git log -1 --format=%cs -- "$relative_path"`，untracked 文件用
  `date -r "$path" +%F`；
- inventory 使用制表符分隔并包含：source、source_root、branch、commit、tracked、original_path、phase、type、date、date_source、size、sha256、archived_path；
- 包含文件的目标路径固定为
  `<phase>/<type>/<date>/<source>/<original_path>`；
- 未命中的文件写入 stderr 的保留摘要，但不进入 inventory；
- inventory 按 `archived_path` 排序，若同一目标路径出现两次则失败。

- [ ] **Step 3: Make the inventory test pass**

Run:

```bash
bash scripts/repo/test-archive-history-docs.sh
```

Expected: PASS，并打印每个 fixture source 的 selected/excluded/unmatched 数量。

- [ ] **Step 4: Run shell syntax and formatting checks**

Run:

```bash
bash -n scripts/repo/archive-history-docs.sh
bash -n scripts/repo/test-archive-history-docs.sh
git diff --check
```

Expected: 三条命令退出码均为 0。

- [ ] **Step 5: Commit inventory support**

```bash
git add scripts/repo/archive-history-docs.sh scripts/repo/history-docs-rules.tsv scripts/repo/test-archive-history-docs.sh
git commit -m "feat(repo): inventory historical documents"
```

### Task 3: Add Staging, Integrity, And Deletion Safety Tests

**Files:**
- Modify: `scripts/repo/test-archive-history-docs.sh`
- Test: `scripts/repo/test-archive-history-docs.sh`

- [ ] **Step 1: Add a successful stage/verify/delete scenario**

测试运行 `stage` 后断言：

- 每个 inventory 条目对应一个目标文件；
- 两个来源中内容相同的文件都存在于各自 source 路径；
- `manifest.json` 中有两个独立条目，且 `duplicate_group` 相同；
- `INDEX.md` 的 task/type 计数与 `jq` 聚合结果一致；
- 未传 `delete` 时源文件全部存在；
- 运行 `delete` 后只删除 inventory 中列出的源文件，README、活动架构文档和测试基线仍存在。

- [ ] **Step 2: Add pre-delete mutation and missing-target failures**

在 stage 后分别修改一个源文件、删除一个目标文件，再运行：

```bash
scripts/repo/archive-history-docs.sh delete \
  --inventory "$fixture_root/inventory.tsv" \
  --destination "$fixture_root/archive"
```

Expected: 两种情况均 FAIL，且所有尚未删除的候选源文件保持不变。

- [ ] **Step 3: Add destination collision and unsafe-root failures**

构造已存在但哈希不同的目标文件，并分别传入 `/`、源仓库根目录和非空无 manifest 的 destination。Expected: `stage` 在写入或删除前失败，诊断包含准确目标路径。

- [ ] **Step 4: Run tests and observe failure before implementation**

Run:

```bash
bash scripts/repo/test-archive-history-docs.sh
```

Expected: FAIL，首个失败来自尚未实现的 `stage` 子命令。

- [ ] **Step 5: Commit the failing safety tests**

```bash
git add scripts/repo/test-archive-history-docs.sh
git commit -m "test(repo): cover archive deletion safety"
```

### Task 4: Implement Stage, Manifest, Index, And Verified Deletion

**Files:**
- Modify: `scripts/repo/archive-history-docs.sh`
- Test: `scripts/repo/test-archive-history-docs.sh`

- [ ] **Step 1: Implement staging without source deletion**

`stage` 先验证 inventory 的每个源文件 size/SHA-256 未变化，再创建 destination 的同级临时目录。使用 `install -D -m 0644` 复制普通文件，复制完成后再次校验目标 size/SHA-256。destination 已存在时只允许它为空或仅包含与 `--inventory` 相同的 `migration-inventory.tsv`；临时树完整通过校验后，再将其内容发布到 destination，失败时不留下部分 task/type 目录。

- [ ] **Step 2: Generate structured provenance**

使用 `jq -Rn` 从 inventory 生成：

```json
{
  "schema_version": 1,
  "generated_at": "<UTC RFC3339>",
  "sources": [],
  "entries": []
}
```

每个 entry 包含设计规格要求的来源、分支、提交、原路径、归档路径、日期来源、tracked、size、sha256 和 duplicate_group。`duplicate_group` 仅在同一 SHA-256 对应两个或更多 entry 时为该摘要，否则为 `null`。

- [ ] **Step 3: Generate deterministic INDEX.md**

索引固定包含：来源 revision 表、分类规则说明、总数、按 task/type 的数量表，以及按 phase/type/date 排序的相对 Markdown 链接。所有显示路径从 JSON 字符串转义后生成，不能通过拼接未经处理的文件内容生成 Markdown。

- [ ] **Step 4: Implement full verification**

`verify` 检查：inventory、manifest 和磁盘文件一一对应；不存在额外归档文件（允许 `INDEX.md`、`manifest.json`、`migration-inventory.tsv`、`migration-report.md`）；size/SHA-256 一致；manifest 聚合计数与 INDEX 一致；所有 `archived_path` 均位于 destination 内。

- [ ] **Step 5: Implement verified deletion**

`delete` 必须先完整运行 `verify`，再逐个重新校验源文件哈希，并拒绝：

- source root 与 inventory 记录不一致；
- source branch 或 HEAD commit 已变化；
- tracked 状态变化；
- 源文件或目标文件缺失；
- 任一摘要变化。

全部预检通过后才开始删除。删除使用 inventory 中解析出的绝对普通文件路径，不使用 glob，不删除目录；空目录只在确认位于已知历史文档子树后用 `rmdir` 清理。

- [ ] **Step 6: Run the full contract suite**

Run:

```bash
bash scripts/repo/test-archive-history-docs.sh
bash -n scripts/repo/archive-history-docs.sh
git diff --check
```

Expected: 全部 PASS。

- [ ] **Step 7: Commit safe archive execution**

```bash
git add scripts/repo/archive-history-docs.sh scripts/repo/test-archive-history-docs.sh
git commit -m "feat(repo): archive documents after integrity checks"
```

### Task 5: Freeze And Review The Real Migration Inventory

**Files:**
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv`
- Modify: `scripts/repo/history-docs-rules.tsv`
- Test: `scripts/repo/test-archive-history-docs.sh`

- [ ] **Step 1: Capture pre-migration source state**

Run:

```bash
git -C /home/yfblock/Code/hyper-rtos/starryos-replace status --short --branch
git -C /home/yfblock/Code/hyper-rtos/tgoskits status --short --branch
git -C /home/yfblock/Code/hyper-rtos/starryos-replace rev-parse HEAD
git -C /home/yfblock/Code/hyper-rtos/tgoskits rev-parse HEAD
```

Expected: `starryos-replace` 只包含本计划产生的已提交状态；`tgoskits` 的既有未跟踪日志和配置被记录，且不做清理。

- [ ] **Step 2: Generate the real inventory without changing source files**

Run:

```bash
scripts/repo/archive-history-docs.sh inventory \
  --rules scripts/repo/history-docs-rules.tsv \
  --source starryos-replace=/home/yfblock/Code/hyper-rtos/starryos-replace \
  --source tgoskits=/home/yfblock/Code/hyper-rtos/tgoskits \
  --output /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv
```

Expected: 命令成功，两个 worktree 均只有历史候选被选择，且没有文件变化。

- [ ] **Step 3: Audit phase, type, date, and exclusions**

使用以下检查定位错误分类和遗漏：

```bash
awk -F '\t' 'NR > 1 { count[$7 FS $8]++ } END { for (key in count) print key, count[key] }' \
  /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv | sort
rg -n 'README|CHANGELOG|AGENTS\.md|CLAUDE\.md|/validation/|/golden/|docs/docs/architecture|^.*book/design' \
  /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv
```

Expected: 聚合中只出现 `task12`、`task123` 和八种批准类型；第二条命令无输出。逐项检查所有无日期文件采用正确 Git 日期，未跟踪日志采用 mtime。

- [ ] **Step 4: Tighten rules for every discovered ambiguity**

对真实清单中发现的错误，增加比通用规则更靠前的精确 path regex。每次调整后重跑 fixture test 和 inventory；只有规则能说明具体文件为什么属于 Task 1/2 或 Task 1/2/3 时才归档。无法从内容或 Git 历史确定阶段的文件保持未命中并留在源仓库。

- [ ] **Step 5: Commit the finalized classification rules**

```bash
git add scripts/repo/history-docs-rules.tsv scripts/repo/test-archive-history-docs.sh
git commit -m "docs(repo): finalize history archive classification"
```

### Task 6: Stage The Archive And Validate Links

**Files:**
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/INDEX.md`
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/manifest.json`
- Create: archived files below `/home/yfblock/Code/hyper-rtos/history-docs/task12/`
- Create: archived files below `/home/yfblock/Code/hyper-rtos/history-docs/task123/`
- Create: `/home/yfblock/Code/hyper-rtos/history-docs/migration-report.md`

- [ ] **Step 1: Stage and verify all files**

Run:

```bash
scripts/repo/archive-history-docs.sh stage \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
scripts/repo/archive-history-docs.sh verify \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
```

Expected: 两条命令成功，source 文件仍全部存在，manifest 和 index 计数一致。

- [ ] **Step 2: Check archived Markdown links without mutating evidence**

从 manifest 选出 `.md` 条目，解析 Markdown 本地相对链接，并用 `source + original_path` 映射判断目标是否也已归档。归档文件保持逐字节不变，确保其 SHA-256 继续等于迁移前源文件；由于新增 phase/type/date 前缀而失效的链接写入 `migration-report.md`，同时在 `INDEX.md` 的 link map 中列出正确目标。忽略 `http://`、`https://`、`mailto:` 和纯 fragment 链接。

Run the archive verifier after link analysis. Expected: archive SHA-256 不变，每个新失效链接都有明确 link-map 目标或无法解析原因。

- [ ] **Step 3: Scan retained source documents for moved targets**

从 inventory 的 `original_path` 生成精确目标列表，在两个 worktree 的 retained `.md` 文件中检查 Markdown 引用。只修改实际命中的 retained 文档，将链接指向 `/home/yfblock/Code/hyper-rtos/history-docs/...` 对应条目；无法保持可移植的引用写入 `migration-report.md`，不静默删除链接。

- [ ] **Step 4: Write the migration report**

报告包含：执行时间、两个 source branch/commit、tracked/untracked 数量、task/type/date 聚合、duplicate groups、排除项抽样、归档链接检查、retained source 链接修复、未解决链接和 `history-docs` 尚未单独版本控制的说明。

- [ ] **Step 5: Verify again before any deletion**

Run:

```bash
scripts/repo/archive-history-docs.sh verify \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
git -C /home/yfblock/Code/hyper-rtos/starryos-replace diff --check
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --check
```

Expected: 全部成功，源历史文件尚未删除。

### Task 7: Delete Verified Sources And Commit Source Changes

**Files:**
- Delete: inventory 中列出的 `starryos-replace` 历史文档
- Delete: inventory 中列出的 `tgoskits` 历史文档和历史证据日志
- Modify: Task 6 扫描命中的 retained Markdown links

- [ ] **Step 1: Run verified deletion exactly once**

Run:

```bash
scripts/repo/archive-history-docs.sh delete \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
```

Expected: 只删除 manifest 对应源文件；任何 source branch、HEAD、状态或哈希变化都会在第一项删除前终止。

- [ ] **Step 2: Verify retained sentinels and unrelated user state**

Run explicit existence checks for source `README*`、`CHANGELOG*`、`AGENTS.md`、`CLAUDE.md`、validation/golden/syscall `.txt` and active architecture files. Compare the post-migration `tgoskits` status against the Task 5 snapshot, subtracting only inventory paths and intentional link edits.

Expected: 所有 sentinel 存在；`configs/` 和其他既有未跟踪内容完全不变。

- [ ] **Step 3: Run final archive integrity checks**

Run:

```bash
scripts/repo/archive-history-docs.sh verify \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
jq -e '.entries | length > 0' /home/yfblock/Code/hyper-rtos/history-docs/manifest.json
find /home/yfblock/Code/hyper-rtos/history-docs/task12 \
     /home/yfblock/Code/hyper-rtos/history-docs/task123 -type f | sort
```

Expected: verifier 和 `jq` 成功；文件清单只位于批准的 phase/type/date/source 层级。

- [ ] **Step 4: Commit `starryos-replace` source changes**

先确认 staged paths 全部是 inventory 中的删除、链接修复或归档工具，然后：

```bash
git -C /home/yfblock/Code/hyper-rtos/starryos-replace add -u
git -C /home/yfblock/Code/hyper-rtos/starryos-replace commit \
  -m "docs(task123): move historical records to shared archive"
```

- [ ] **Step 5: Commit only intended tracked changes in `tgoskits`**

不得使用 `git add -A`。按 manifest 中 `source=tgoskits` 且 `tracked=true` 的路径生成 NUL 分隔列表，逐路径 `git add -u -- <path>`，再单独暂存 retained link edits：

```bash
git -C /home/yfblock/Code/hyper-rtos/tgoskits diff --cached --name-status
git -C /home/yfblock/Code/hyper-rtos/tgoskits commit \
  -m "docs(task12): move historical records to shared archive"
```

Expected: 未跟踪 `configs/` 和非 inventory 文件没有进入 commit。

### Task 8: Final Verification And Handoff

**Files:**
- Modify: `/home/yfblock/Code/hyper-rtos/history-docs/migration-report.md`

- [ ] **Step 1: Record final repository states**

将以下结果摘要追加到 migration report：

```bash
git -C /home/yfblock/Code/hyper-rtos/starryos-replace status --short --branch
git -C /home/yfblock/Code/hyper-rtos/tgoskits status --short --branch
git -C /home/yfblock/Code/hyper-rtos/starryos-replace log -2 --oneline
git -C /home/yfblock/Code/hyper-rtos/tgoskits log -2 --oneline
```

- [ ] **Step 2: Re-run all migration tests from committed source**

Run:

```bash
cd /home/yfblock/Code/hyper-rtos/starryos-replace
bash scripts/repo/test-archive-history-docs.sh
bash scripts/repo/archive-history-docs.sh verify \
  --inventory /home/yfblock/Code/hyper-rtos/history-docs/migration-inventory.tsv \
  --destination /home/yfblock/Code/hyper-rtos/history-docs
git diff --check
```

Expected: 全部 PASS。

- [ ] **Step 3: Reconcile counts and duplicate groups**

Run:

```bash
jq -e '
  (.entries | length) > 0 and
  ([.entries[].phase] | all(. == "task12" or . == "task123")) and
  ([.entries[].type] | all(IN("design","spec","plan","report","result","evidence","debug","guide")))
' /home/yfblock/Code/hyper-rtos/history-docs/manifest.json
```

Expected: `true`。对比 INDEX、manifest、inventory 和磁盘文件数，四者一致；migration report 列出的 duplicate group 数与 manifest 聚合一致。

- [ ] **Step 4: Report the non-versioned destination boundary**

最终交付明确说明：两个源仓库中的迁移变更已经分别提交；`history-docs` 位于外层尚无提交的仓库中，因此本任务不自行创建外层初始提交。提供 manifest 路径、两个 source commit、归档文件总数和仍保留的未跟踪状态。
