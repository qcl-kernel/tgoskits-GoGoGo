# 提交基线说明

> 本文档属于 [GoGoGo 成果材料](../README.md) ｜ 文档集：[设计](design.md) · [更改](changes.md) · [性能](performance.md) · [验证报告](results-report.md) · [任务对照](task-coverage.md) · [提交基线](commits.md) · [工程实录](walkthrough.md) · [复现](reproduce.md)

本工作基于 **rcore-os/tgoskits 的 upstream/dev 分支**开发，最终 rebase 到
upstream/dev 的最新提交上交付。

## 基线与提交链

```text
upstream/dev 基线（起点）
  ba252ca67433932341cea2d35bccc5afaaffc2b1
  周睿 <34859362+ZR233@users.noreply.github.com>
  2026-08-27 13:11:35 +0800
  fix(virtualization): port isolated interrupt controller fixes (#2199)
        │
        ▼
87eb3fcc5da515701cb8d64465de2493bf113844        ← 核心 commit 1
  2026-08-27 14:15:30 +0800
  feat(task123): integrate ROCK 4D/QEMU RTOS guest matrix onto upstream/dev
  （task123 全栈集成：guest 组件、RT-Thread 补丁集、runner、板级配置，
    1298 文件；原 237-commit 开发历史 squash 后重放）
        │
        ▼
621a063a987917f9e4256f611c2fb784f6bb5dd8        ← 核心 commit 2
  2026-08-27 16:55:41 +0800
  fix(axvm): adapt task123 guests to the rebase onto upstream/dev
  （rebase 后四项适配：vCPU 独占 pinning、virtio-mmio QEMU vendor 身份、
    busy WFI fastpath 禁用、host-SPI 风暴熔断；7 文件）
        │
        ▼
3fe50f72c … f75cb08fc（6 个文档提交）
  2026-08-27 17:00 – 19:06 +0800
  （证据基线对齐、数据刷新、材料整理、定位与任务对照文档）
```

完整提交列表（`git log --oneline upstream/dev..HEAD`）：

| Commit | 时间 (+0800) | 说明 |
|---|---|---|
| `87eb3fcc5` | 08-27 14:15 | task123 全栈集成（核心） |
| `621a063a9` | 08-27 16:55 | rebase 后适配修复（核心） |
| `3fe50f72c` | 08-27 17:00 | 证据基线对齐 rebase 后分支 |
| `af6db1e9f` | 08-27 18:10 | 证据数据刷新为 08-27 批次 |
| `bba5da785` | 08-27 18:30 | 材料精简（删旧 PNG/归档） |
| `fb8f09cba` | 08-27 18:47 | 运行日志按组合归档 |
| `87960ff1e` | 08-27 19:03 | 材料重组 + 设计/更改/性能文档 |
| `badf21ccc` | 08-27 19:05 | 混合关键性定位与边界说明 |
| `f75cb08fc` | 08-27 19:06 | 任务要求逐条对照文档 |

## 开发历史说明

实际开发从 **2026-08-12** 开始，当时基于的 upstream/dev 基线是：

```text
  3d9c9628128032176e3cc83a45ead7bdf1522ffb
  2026-08-12 09:19:43 +0800
  fix(cpu-local): keep AArch64 current independent of TLS (#1970)
```

在此之上累积了 237 个开发 commit（task12 实时性改造 → task123 全栈），
完整历史保留在 `backup/pr-new-pre-rebase` 分支。交付前整体 rebase 到
upstream/dev 最新（`ba252ca67`，2026-08-27），以 squash-集成 + 适配修复
两个核心 commit 的形式线性化，并完成 8 组合复验。

## 仓库与分支

| 项 | 值 |
|---|---|
| 上游仓库 | `github.com/rcore-os/tgoskits`（upstream remote） |
| 提交仓库 | `github.com/qcl-kernel/tgoskits-GoGoGo`（origin remote） |
| 交付分支 | `upstream/pr-new`（已推送 origin，与 dev 无冲突） |
| 备份分支 | `backup/pr-new-pre-rebase`（237-commit 原始历史，仅本地） |
