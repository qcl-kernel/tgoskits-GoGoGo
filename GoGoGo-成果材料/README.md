# GoGoGo 成果材料：Axvisor 混合关键性系统 Task123

本目录是「在 Axvisor 上运行混合关键性系统」的最终成果材料，覆盖 Task 1 实时性、
Task 2 客户机通信与 Task 3 AI 控制闭环，在 QEMU 与 ROCK 4D（RK3576）真机上
各验证 2 种 RTOS × 2 种应用客户机共 8 个组合。

> **分支说明**：当前分支（`upstream/pr-new`，即 origin 的 `dev`）为**成果归档
> 分支**，源码与材料文档合在一起提交。后续会切换到独立工作分支，将源码按
> 子系统拆分成多个 PR 分别提交；本材料目录不属于源码 PR 的一部分。

## 我们做了什么（概览）

- 在 Axvisor（Type-1 hypervisor）上构建了混合关键性系统：GPOS（Linux/StarryOS）
  与 RTOS（RT-Thread/Zephyr）同板共存，空间/时间隔离 + 受控网络通信
- 将 RT-Thread v5.2.2 移植为 Axvisor guest（12 个补丁：virtio-net、lwIP、GIC、
  定时器、ROCK 4D 板级），并移植 Zephyr v4.4.2（overlay 路线）
- 实现两个客户机间的 IP 通信：内部 VirtualSwitch + virtio-net + 自研 RT-IPC v2
  协议（UDP 之上的 ACK/重传/去重/会话管理，20 字节头含版本/序号/校验）
- 部署 AI 应用闭环：应用侧 TinyCNN int8 推理（三分类）→ 跨客户机发送 → RTOS
  侧实时控制（PWM/转向）→ 状态回传，全链可观测
- 实时性改造与验证：16 项纳秒级 RTBench 指标，真机 RT-Thread timer jitter
  p99 达 8.9–28 µs（亚毫秒共存）
- 排查并修复了 7 个板级 bring-up 深层问题（timer PPI 电平发布、SPI 中断风暴、
  nested-vCPU 冲突、virtio vendor 身份等，见工程实录）
- 修复上游工具链 bug：ostool 的 serde-flatten 字段遮蔽导致板级复位命令永不
  执行，提交上游 PR [drivercraft/ostool#172](https://github.com/drivercraft/ostool/pull/172)
  （已获评审批准）
- 完成整体验证矩阵：QEMU × 4 + ROCK 4D 真机 × 4 共 8 个组合全部门禁通过，
  指标 16/16 完整，正式数据与全部日志归档于本材料

## 目录结构

```text
GoGoGo-成果材料/
├── README.md                          ← 本文件：总览与导航
├── docs/
│   ├── 任务对照.md                    ← 任务要求逐条实现情况与指标对照
│   ├── 提交基线.md                    ← 提交基线与提交链说明
│   ├── 工程实录.md                    ← 工程实录（怎么做、做了哪些事）
│   ├── 系统设计.md                    ← 系统设计与架构
│   ├── 更改说明.md                    ← 相对 upstream/dev 的全部更改
│   ├── 性能数据.md                    ← 性能数据与分析
│   ├── 验证报告.md                    ← 最终验证报告（8 组合门禁与 RTBench 表）
│   ├── 复现指南.md                    ← 复现指南（命令与判定）
│   └── 协议对比分析.md                ← RT-IPC(UDP) vs HRPC(TCP) 基准对比
├── logs/                              ← 本批次完整运行日志（按组合命名）
│   ├── log-qemu-<rtos>-<guest>.log        （4 份 QEMU 主跑）
│   └── log-rock4d-<rtos>-<guest>.log      （4 份板级主跑 + 6 份 retry）
├── plots/                             ← 图表与解析数据
│   ├── plots/*.svg                    ← 9 张对比图（SVG 为唯一图源）
│   ├── qemu/<组合>/                    ← QEMU 串口日志与矩阵汇总
│   ├── rock4d/                        ← 板级串口日志（主 + retry）
│   ├── *-metrics.csv / parsed-data.json
│   ├── plot_task123.py                ← 解析与绘图脚本
│   └── index.html                     ← 图表浏览入口
└── AxVisor智能工控混合系统产品说明书_V1.0.pdf
```

## 快速导航

| 想了解 | 看 |
|---|---|
| 系统怎么设计的（双 VM 拓扑、virtio-net、AI 闭环） | [docs/系统设计.md](docs/系统设计.md) |
| 这个分支相对 upstream/dev 改了什么 | [docs/更改说明.md](docs/更改说明.md) |
| 实测性能如何（timer jitter、网络延迟、推理耗时） | [docs/性能数据.md](docs/性能数据.md) |
| 8 组合验收结论与完整指标表 | [docs/验证报告.md](docs/验证报告.md) |
| 任务要求逐条实现情况与指标对照 | [docs/任务对照.md](docs/任务对照.md) |
| 基于 upstream 哪个 commit、提交链与时间 | [docs/提交基线.md](docs/提交基线.md) |
| 工程怎么做：工作流、关键问题定位实录 | [docs/工程实录.md](docs/工程实录.md) |
| 如何复现这些结果 | [docs/复现指南.md](docs/复现指南.md) |
| RT-IPC(UDP) 与 HRPC(TCP) 的延迟/吞吐/内存对比 | [docs/协议对比分析.md](docs/协议对比分析.md) |

## 基线信息

| 项 | 值 |
|---|---|
| 数据批次 | 2026-08-27 |
| 分支 | `upstream/pr-new` |
| 基线 | upstream/dev `ba252ca67` |
| 集成提交 | `87eb3fcc5` + 适配 `621a063a9` |

## 系统定位

基于 Type-1 hypervisor 的**混合关键性系统验证平台**：用空间与时间隔离让
GPOS（AI 推理）与 RTOS（实时控制）安全共存于单板并跑通感知→决策→控制
闭环。采用隔离式（static partitioning）路线，未做安全认证（详见
[docs/系统设计.md](docs/系统设计.md) 的定位与边界说明）。

## 一句话结论

8 个组合（QEMU × 4 + ROCK 4D × 4）全部通过 Task 2 通信、Task 3 AI 闭环
（分类准确率 3/3）与 Task123 门禁；ROCK 4D 上 RT-Thread 的 timer jitter
p99 为 28–29 µs（16 项纳秒指标全部 10/10 完整），证明隔离式混合关键性
负载可在此平台上以可接受的开销运行。
