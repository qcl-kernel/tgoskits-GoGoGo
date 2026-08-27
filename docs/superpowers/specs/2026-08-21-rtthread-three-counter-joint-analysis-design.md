# RT-Thread 三计数器联合实时性分析设计

## 目标

将 `CNTVCT_EL0`、`PMCCNTR_EL0` 和 `PMEVCNTR0_EL0` 的结果用于同一套实时性分析：

- 纳秒延迟决定周期任务是否满足实时截止期；
- cycles 反映 QEMU/AxVisor 路径的虚拟执行工作量；
- instructions 反映 Guest 执行路径的指令工作量。

三个指标不合成为单一分数，因为它们的物理语义不同。联合结果同时给出达标结论和长尾归因。

## 数据契约

每个 RTBENCH metric 的原始记录仍包含三组独立分布。三个计数器在同一个 start/end 边界读取，
因此 `mean_ns`、`mean_cycles` 和 `mean_instructions` 来自相同的样本集合。

Host 端新增 `joint_analysis`：

- `aggregate_efficiency.mean_ns_per_instruction = mean_ns / mean_instructions`；
- `aggregate_efficiency.mean_cycles_per_instruction = mean_cycles / mean_instructions`；
- `aggregate_efficiency.mean_ns_per_cycle = mean_ns / mean_cycles`；
- `p99` 和 `max` 分别保留三类指标的值；
- 比较结果提供 B/A、C/A 和 C/B 的三类 P99 比例、最大值比例及上述效率比例。

效率比使用同一批样本的均值比值，不能解释为逐样本相关系数。P99 也分别计算，报告会明确其
不是三列 P99 的同一个样本。

## 联合判定

实时性门禁保持现有规则：所有 metric 的 `max_ns <= 1,000,000` 且样本完整。

对候选场景相对于基线的 P99 使用 1.20 的变化阈值：

- `latency_only`: ns 比例大于 1.20，而 cycles 和 instructions 均不大于 1.20；
- `path_expansion`: ns、cycles、instructions 均大于 1.20；
- `mixed`: ns 大于 1.20，但只有部分工作量指标大于 1.20；
- `work_increase_without_latency_regression`: ns 不大于 1.20，但至少一个工作量指标大于 1.20；
- `stable`: 三类 P99 均不大于 1.20；
- `insufficient_baseline`: 基线的某个 P99 为零，无法计算比例。

该分类是定位启发式，不替代硬实时证明。`latency_only` 表示优先检查调度、虚拟中断、
设备模拟和宿主竞争；`path_expansion` 表示优先检查锁、重试、额外处理路径或测量边界。

## 输出

- JSON：保留原有 schema 1，并增加 `joint_analysis` 字段；
- Markdown：增加“联合三指标分析”表，列出比较方向、ns/cycles/instructions P99 比例、
  三类均值效率和归因；
- CSV：保留现有原始结果 CSV，另生成 `--joint-csv-output` 指定的联合分析 CSV，避免破坏
  已有下游读取器。

## 验证

测试必须覆盖：

1. 三类 P99 同步进入 JSON/Markdown/联合 CSV；
2. ns 增大而工作量稳定时分类为 `latency_only`；
3. 三类同时增大时分类为 `path_expansion`；
4. 零基线被标记为 `insufficient_baseline`，不产生除零结果；
5. 原有缺字段、重复 metric、样本不完整和核心模式测试继续通过。
