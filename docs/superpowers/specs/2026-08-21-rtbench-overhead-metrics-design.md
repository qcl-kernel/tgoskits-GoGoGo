# RTBench 实时性开销指标设计

## 目标

在现有 RTBench 的 9 项实时性指标基础上，补充上下文切换、调度决策、同步原语、IRQ
handler 区间和负载下截止期缺失测试。所有新增样本同时记录 `CNTVCT_EL0` 纳秒、
`PMCCNTR_EL0` cycles 和 PMU 事件 `0x08` instructions，并由现有结果门禁验证。

## 范围

新增以下稳定指标名：

| 指标 | 测量定义 |
|---|---|
| `context_switch` | 两个同优先级线程通过 `rt_thread_yield()` 交替运行的线程交接路径；包含最小 harness 开销，不宣称裸 `switch_to` 指令耗时 |
| `scheduler_decision` | 当前线程仍为最高优先级时调用 `rt_schedule()` 的无切换调度决策路径 |
| `sync_sem` | 无竞争 semaphore take/release 往返 |
| `sync_mutex` | 无竞争 mutex take/release 往返 |
| `sync_mailbox` | mailbox send/receive 往返 |
| `irq_handler_exec` | SGI handler 首次采样到 handler 退出前采样的 handler 区间，不包含硬件异常入口和返回的全部汇编路径 |
| `deadline_miss_under_load` | 1 ms 周期任务与 4 个 CPU 负载线程并行时的周期偏差；`miss_1ms` 表示超过 1 ms 的样本数 |

现有 `timer_jitter`、`callback_exec`、`preemption`、`irq`、`irq_to_task`、
`irq_disabled_duration`、`mutex_inversion`、`wake_under_load` 和 `net_event_latency`
保持兼容。

## 采样和输出

新增指标复用 `struct rtbench_sample`、`struct rtbench_result` 和
`rtbench_print_result()`。每项输出：

```text
RTBENCH metric=<name> run=1 expected=<N> collected=<N> missing=0 ...
  p50_ns=... p95_ns=... p99_ns=... p99_9_ns=... max_ns=... mean_ns=...
  p50_cycles=... p95_cycles=... p99_cycles=... p99_9_cycles=... max_cycles=... mean_cycles=...
  p50_instructions=... p95_instructions=... p99_instructions=... p99_9_instructions=...
  max_instructions=... mean_instructions=...
```

所有指标都要求 `expected == collected` 且 `missing == 0`。cycles 和 instructions 是
QEMU TCG 下的虚拟 PMU 计数，只用于分析 Guest 执行工作量，不能替代真实硬件 PMU 或
消除 QEMU TCG/宿主调度长尾。

## 实现边界

- 只修改 RT-Thread benchmark guest、源码安装脚本、结果门禁、测试夹具和报告工具。
- 不修改 AxVisor 调度器、中断注入和 virtio-net 运行时实现。
- `benchmark N` 和 `benchmark_core N` 都运行新增 guest-local 指标；只有 `benchmark N`
  运行 `net_event_latency`。
- 新增线程和定时器在每项测试结束后停止、等待或删除，不能残留到下一项测试。
- mailbox 使用固定单槽、固定宽度消息；测试必须验证 send/receive 成功，避免把失败路径
  当作开销样本。
- deadline 测试使用固定 4 个负载线程，并在输出中保留样本完整性和 `miss_1ms`，不把
  QEMU TCG 下的严格尾延迟误报为硬实时通过。

## 验收

1. 源码契约测试检查所有新增函数、指标名、同步清理和 suite 调用顺序。
2. 结果门禁测试要求 7 个新增指标各出现一次，并拒绝缺失、重复、样本不完整或字段缺失。
3. host summarizer 将新增指标纳入 suite metric 集合，并保留三计数器统计。
4. RT-Thread A/B/C 真实 QEMU 回归中，新增指标均有 `expected/collected/missing` 证据。
5. 原有 RTBench、RT-IPC、Task 1/2/3 和稳定性门禁继续通过。

