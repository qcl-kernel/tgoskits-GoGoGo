# GoGoGo 成果材料：Axvisor 混合关键性系统 Task123

本目录是「在 Axvisor 上运行混合关键性系统」的最终成果材料，覆盖 Task 1 实时性、
Task 2 客户机通信与 Task 3 AI 控制闭环，在 QEMU 与 ROCK 4D（RK3576）真机上
各验证 2 种 RTOS × 2 种应用客户机共 8 个组合。

## 目录结构

```text
GoGoGo-成果材料/
├── README.md                          ← 本文件：总览与导航
├── docs/
│   ├── design.md                      ← 系统设计与架构
│   ├── changes.md                     ← 相对 upstream/dev 的全部更改
│   ├── performance.md                 ← 性能数据与分析
│   ├── results-report.md              ← 最终验证报告（8 组合门禁与 RTBench 表）
│   └── reproduce.md                   ← 复现指南（命令与判定）
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
| 系统怎么设计的（双 VM 拓扑、virtio-net、AI 闭环） | [docs/design.md](docs/design.md) |
| 这个分支相对 upstream/dev 改了什么 | [docs/changes.md](docs/changes.md) |
| 实测性能如何（timer jitter、网络延迟、推理耗时） | [docs/performance.md](docs/performance.md) |
| 8 组合验收结论与完整指标表 | [docs/results-report.md](docs/results-report.md) |
| 如何复现这些结果 | [docs/reproduce.md](docs/reproduce.md) |

## 基线信息

| 项 | 值 |
|---|---|
| 数据批次 | 2026-08-27 |
| 分支 | `upstream/pr-new` |
| 基线 | upstream/dev `ba252ca67` |
| 集成提交 | `87eb3fcc5` + 适配 `621a063a9` |

## 一句话结论

8 个组合（QEMU × 4 + ROCK 4D × 4）全部通过 Task 2 通信、Task 3 AI 闭环
（分类准确率 3/3）与 Task123 门禁；ROCK 4D 上 RT-Thread 的 timer jitter
p99 为 28–29 µs（16 项纳秒指标全部 10/10 完整），证明 Axvisor 可在真实
硬件上以可接受的隔离开销承载混合关键性负载。
