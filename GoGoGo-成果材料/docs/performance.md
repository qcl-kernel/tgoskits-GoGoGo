# 性能数据

> 本文档属于 [GoGoGo 成果材料](../README.md) ｜ 文档集：[设计](design.md) · [更改](changes.md) · [性能](performance.md) · [验证报告](results-report.md) · [任务对照](task-coverage.md) · [提交基线](commits.md) · [工程实录](walkthrough.md) · [复现](reproduce.md)

数据批次：2026-08-27，分支 `upstream/pr-new`（`87eb3fcc5` + `621a063a9`）。
8 组合 × 16 项纳秒 RTBench 指标 × 10 样本全部完整（10/10，missing=0）。
原始数据：`../plots/rtbench-metrics.csv`、`../plots/task2-metrics.csv`、
`../plots/task3-metrics.csv`；图表：`../plots/plots/*.svg`。

## 1. Timer jitter（核心实时性指标）

| 平台 | RTOS | 应用客户机 | p50 (ns) | p99 (ns) |
|---|---|---|---:|---:|
| QEMU | RT-Thread | Linux | 4,896 | 244,720 |
| QEMU | RT-Thread | StarryOS | 8,768 | 83,472 |
| QEMU | Zephyr | Linux | 647,584 | 1,295,168 |
| QEMU | Zephyr | StarryOS | 398,352 | 797,104 |
| ROCK 4D | RT-Thread | Linux | 1,000 | **28,125** |
| ROCK 4D | RT-Thread | StarryOS | 459 | **8,875** |
| ROCK 4D | Zephyr | Linux | 1,038,625 | 2,081,625 |
| ROCK 4D | Zephyr | StarryOS | 1,039,583 | 2,083,166 |

要点：

- **真机 RT-Thread 的 p50 达到亚微秒级**（0.5–1 µs），p99 在 9–28 µs——
  hypervisor 隔离开销对轻量 RTOS 是可接受的。
- Zephyr 的 jitter 在两个平台上都是毫秒级（p50 ≈ 1 ms）：其 tickless
  内核以 1 ms 级粒度调度 idle 退出，属于 guest 侧设计权衡而非 hypervisor
  开销；同一平台上 Zephyr 与 RT-Thread 的差异主要来自 guest 内核本身。
- QEMU TCG 的单线程翻译显著放大延迟（RT-Thread p99 245 µs vs 真机 28 µs），
  QEMU 数据只用于功能闭环与同平台相对比较。

## 2. 网络（virtio-net guest-to-guest）

### RTBench net_event_latency（事件到处理的端到端延迟）

| 平台 | RTOS | 应用客户机 | p50 (ns) | p99 (ns) |
|---|---|---|---:|---:|
| QEMU | RT-Thread | Linux | 84,096 | 359,184 |
| QEMU | RT-Thread | StarryOS | 158,528 | 639,056 |
| QEMU | Zephyr | Linux | 118,640 | 1,098,816 |
| QEMU | Zephyr | StarryOS | 118,640 | 122,000 |
| ROCK 4D | RT-Thread | Linux | 179,666 | 550,958 |
| ROCK 4D | RT-Thread | StarryOS | 347,666 | 431,666 |
| ROCK 4D | Zephyr | Linux | 334,250 | 727,125 |
| ROCK 4D | Zephyr | StarryOS | 333,375 | 356,708 |

### Task 2 RT-IPC 往返（64 B payload，10 次请求）

| 平台 | RTOS | 应用客户机 | 平均 RTT |
|---|---|---|---:|
| QEMU | RT-Thread | Linux | 2 ms |
| QEMU | RT-Thread | StarryOS | 3 ms |
| QEMU | Zephyr | Linux | 2 ms |
| QEMU | Zephyr | StarryOS | 4 ms |
| ROCK 4D | RT-Thread | Linux | 2 ms |
| ROCK 4D | RT-Thread | StarryOS | 12–15 ms（retry 合并多轮） |
| ROCK 4D | Zephyr | Linux | 6 ms |
| ROCK 4D | Zephyr | StarryOS | 17 ms |

真机 RT-Thread + Linux 的 64 B RTT 平均 2 ms，与 QEMU 持平；StarryOS 作为
应用客户机时 RTT 更长（12–17 ms），主要是该 guest 的调度与网络栈路径差异。

## 3. Task 3 AI 控制闭环

| 平台 | RTOS | 应用客户机 | 推理 p50 (µs) | 往返 p50 (µs) | 分类 |
|---|---|---|---:|---:|---|
| QEMU | RT-Thread | Linux | 1,813 | 1,677 | 3/3 |
| QEMU | RT-Thread | StarryOS | 1,748 | 3,792 | 3/3 |
| QEMU | Zephyr | Linux | 1,567 | 1,440 | 3/3 |
| QEMU | Zephyr | StarryOS | 1,740 | 3,527 | 3/3 |
| ROCK 4D | RT-Thread | Linux | 943 | — | 3/3 |
| ROCK 4D | RT-Thread | StarryOS | 982 | — | 3/3 |
| ROCK 4D | Zephyr | Linux | 947 | 3,386 | 3/3 |
| ROCK 4D | Zephyr | StarryOS | 970 | — | 3/3 |

- 所有 8 组合分类准确率 100%（AI 模式 truth == predicted，逐帧 3/3）。
- 真机 TinyCNN int8 推理 p50 约 **0.95 ms**（QEMU TCG 约 1.6–1.8 ms）。
- 跟踪误差 Q15 p50 = 1461 全组合一致（确定性负载的设计目标）。
- “—” 表示该组合的 summary JSON 被串口截断，往返值从逐帧 CSV 无法完全
  重建；推理与分类由逐帧行恢复，门禁不受影响。

## 4. 其余 RTBench 指标代表性数据（ROCK 4D）

| 指标 | RT-Thread (p50) | Zephyr (p50) |
|---|---:|---:|
| callback_exec | 291 ns | 291 ns |
| sync_sem / sync_mutex | 583 ns | 583 ns |
| irq_disabled_duration | 1,166 ns | 291 ns |
| context_switch | 291 ns | 291 ns |
| irq_handler_exec | 3,208 ns | 3,208 ns |
| deadline_miss_under_load | 750–1,625 ns | ~233,000 ns |

同步原语与上下文切换在亚微秒级；Zephyr 的 deadline_miss_under_load 高值
同样源于其 tickless 调度粒度。

完整 16 指标 × 8 组合数据见 `../plots/rtbench-metrics.csv` 与
[results-report.md](results-report.md)。
