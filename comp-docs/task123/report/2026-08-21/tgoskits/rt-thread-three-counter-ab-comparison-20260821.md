# RT-Thread 三计数器 A/B 对比报告

日期：2026-08-21

## 1. 结论

本次对比为：

- A：native RT-Thread on QEMU；
- B：AxVisor + RT-Thread only，RT-Thread vCPU 固定在 AxVisor pCPU 2；
- C：AxVisor + 2-vCPU Linux + RT-Thread，本轮 RT-IPC 在测试开始阶段失败，因此不纳入本报告的有效 A/B 数据。

本轮结果表明，AxVisor-only 场景中部分 RT-Thread 执行路径的 `cycles` 和
`instructions` 与 native 基线接近，但 `CNTVCT_EL0` 测得的 wall-clock 延迟仍出现明显
长尾：`irq` P99 为 6.23 ms，`timer_jitter` P99 为 3.64 ms，`irq_to_task` P99 为
49.96 ms。按 1 ms 严格截止期，本轮 B 不能通过。

这不是“RT-Thread 执行了同等工作却需要更多 CPU cycles”的单一问题。三计数器联合结果显示，
多个异常主要表现为纳秒延迟增加，而 cycles/instructions 没有同步增加，符合 QEMU TCG
主循环、虚拟中断/定时器投递、vCPU 唤醒和宿主调度造成的等待长尾。cycles 可以帮助区分
Guest 执行工作量与等待时间，但不能在 TCG 中消除宿主仿真造成的 wall-clock 延迟。

## 2. 测试方法

每个 RT-Thread 样本同时读取：

| 计数器 | 报告单位 | 含义 |
|---|---|---|
| `CNTVCT_EL0` | ns | Guest 观察到的虚拟计时器时间，用于实时截止期判断 |
| `PMCCNTR_EL0` | cycles | QEMU PMU 提供的虚拟 CPU cycle 计数 |
| `PMEVCNTR0_EL0` | instructions | 事件 `0x08`，`INST_RETIRED`，表示退休指令数 |

QEMU 配置为：

```text
-cpu cortex-a72,pmu=on
-icount shift=3
-accel tcg,thread=single
```

执行环境为真实 QEMU 11.0.2、AArch64 `virt`、GICv3、x86_64 宿主。这里的 `cycles` 是
虚拟 PMU 观测值，不是宿主物理 CPU 的真实执行 cycle，也不能当作物理平台 WCET 证明。

本轮每项指标期望 2 个样本；`timer_jitter` 和 `callback_exec` 各执行 3 轮，汇总器保留
最大值最差的一轮。因此本轮 P99 与 max 基本相同，数值仅用于确认路径和定位异常，不能
作为稳定统计分位数。

原始日志：

- A：`tgoskits/tmp/rtthread-three-counter-joint-real-final/native-suite.log`
- B：`tgoskits/tmp/rtthread-three-counter-joint-real-final/axvisor-only-suite/console.log`

## 3. P99 对比

P99 以 `B / A` 表示相对变化；`1.00x` 表示基本不变。

### 3.1 wall-clock 延迟

| 指标 | A ns | B ns | B/A |
|---|---:|---:|---:|
| `callback_exec` | 1,088 | 5,520 | 5.07x |
| `irq` | 1,552 | 6,228,576 | 4,013.26x |
| `irq_disabled_duration` | 3,344 | 3,344 | 1.00x |
| `irq_to_task` | 6,608 | 49,956,160 | 7,559.95x |
| `mutex_inversion` | 18,192 | 32,848 | 1.81x |
| `preemption` | 4,896 | 4,880 | 1.00x |
| `timer_jitter` | 8,720 | 3,636,176 | 416.99x |
| `wake_under_load` | 4,880 | 4,896 | 1.00x |

### 3.2 cycles 与 instructions

| 指标 | A P99 cycles | B P99 cycles | B/A | A P99 instructions | B P99 instructions | B/A |
|---|---:|---:|---:|---:|---:|---:|
| `callback_exec` | 1,080 | 5,520 | 5.11x | 135 | 690 | 5.11x |
| `irq` | 1,544 | 1,536 | 0.99x | 193 | 192 | 0.99x |
| `irq_disabled_duration` | 3,336 | 3,336 | 1.00x | 417 | 417 | 1.00x |
| `irq_to_task` | 6,608 | 685,768 | 103.78x | 826 | 85,721 | 103.78x |
| `mutex_inversion` | 18,192 | 32,848 | 1.81x | 2,274 | 4,106 | 1.81x |
| `preemption` | 4,888 | 4,888 | 1.00x | 611 | 611 | 1.00x |
| `timer_jitter` | 1,008,708 | 95,792 | 0.09x | 1,552 | 11,974 | 7.72x |
| `wake_under_load` | 4,888 | 4,888 | 1.00x | 611 | 611 | 1.00x |

### 3.3 最大值和 1 ms 截止期

| 指标 | A max ns | B max ns | B `miss_1ms` | B 是否满足 max <= 1 ms |
|---|---:|---:|---:|---:|
| `callback_exec` | 1,088 | 5,520 | 0 | 是 |
| `irq` | 1,552 | 6,228,576 | 2 | 否 |
| `irq_disabled_duration` | 3,344 | 3,344 | 0 | 是 |
| `irq_to_task` | 6,608 | 49,956,160 | 2 | 否 |
| `mutex_inversion` | 18,192 | 32,848 | 0 | 是 |
| `preemption` | 4,896 | 4,880 | 0 | 是 |
| `timer_jitter` | 8,720 | 3,636,176 | 2 | 否 |
| `wake_under_load` | 4,880 | 4,896 | 0 | 是 |

A 组所有核心指标的最大值均小于 1 ms；B 组有 3 项超过 1 ms。由于样本量只有 2，不能
据此估计真实概率，但可以确认本轮确实出现了毫秒级长尾。

## 4. 三计数器联合归因

均值效率比用于判断执行工作量和 wall-clock 等待的变化。该归因是启发式分析，不是形式
化证明。

| 指标 | B/A ns/instruction | B/A cycles/instruction | B/A ns/cycle | 归因 |
|---|---:|---:|---:|---|
| `callback_exec` | 1.00x | 1.00x | 1.00x | path expansion |
| `irq` | 2,925.39x | 1.00x | 2,925.39x | latency only |
| `irq_disabled_duration` | 1.00x | 1.00x | 1.00x | stable |
| `irq_to_task` | 85.35x | 1.00x | 85.35x | path expansion |
| `mutex_inversion` | 1.00x | 1.00x | 1.00x | path expansion |
| `preemption` | 1.00x | 1.00x | 1.00x | stable |
| `timer_jitter` | 72.56x | 0.01x | 7,457.51x | mixed |
| `wake_under_load` | 1.00x | 1.00x | 1.00x | stable |

重点解释：

1. `irq` 的 B 组 P99 ns 增加到 6.23 ms，但 cycles 和 instructions 约为 A 的 0.99x，
   说明延迟主要不是 Guest 处理函数执行了更多指令，而是中断到达/唤醒前后的等待。
2. `irq_to_task` 的 cycles 和 instructions 同时增加，说明该测量点包含了更长的虚拟化
   中断、调度或唤醒路径；其 ns 增幅进一步放大，仍叠加了 TCG/宿主等待。
3. `timer_jitter` 的 cycles 与 ns 不同向，说明该样本受虚拟计时器推进和宿主调度影响，
   不能把 `PMCCNTR_EL0` 简单换算成真实纳秒，也不能用 cycle 数直接“抵消” TCG。

## 5. 与正式长时间结果的关系

本报告不是正式稳定性统计。此前同一项目已经完成 100000 样本和 300 秒 A/B/C 测试：

| 场景 | stability jitter P99 | max | 1 ms 样本 |
|---|---:|---:|---:|
| A native RT-Thread | 10.608 us | 176.432 us | 0 |
| B AxVisor + RT-Thread | 23.056 us | 421.280 us | 0 |
| C AxVisor + 2-vCPU Linux + RT-Thread | 422.208 us | 827.280 us | 0 |

这组长时间结果显示静态分区能降低 Linux 对 RT-Thread 的直接 CPU 竞争；但它并不消除
QEMU TCG、虚拟 timer/VGIC、virtio 设备路径和宿主调度引入的长尾。当前 A/B 联合计数器
复测中的异常长尾尤其需要在 100000 样本窗口中重复确认，不能用 2 个样本替代。

## 6. 测试状态和限制

- A 的 RTBench 记录完整，`RTBENCH_END status=PASS`。
- B 的八项核心 RTBench 记录均包含完整三计数器字段，但本次 QEMU 结束前未形成干净的
  `RTBENCH_END` 门禁记录，runner 状态为 `FAIL-CONTINUE`；因此本报告将 B 标记为“有
  效样本、运行门禁未通过”。
- C 的 `axvisor-linux-suite` 在 RT-IPC 连接阶段失败，未生成可比较的 RTBench 联合数据，
  不纳入本报告。
- 本轮没有使用 fake QEMU。
- 需要在真实 AArch64 硬件或 KVM 上复测，并记录物理 PMU/调度数据，才能评估 AxVisor
  本身的实时性上界；QEMU TCG 结果只能用于工程回归和路径定位。

## 7. 复现与解析

解析本次 A/B 日志：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
PYTHONPATH=os/axvisor/scripts python3 - <<'PY'
from pathlib import Path
from summarize_rtthread_realtime import parse_log, compare_joint

root = Path("tmp/rtthread-three-counter-joint-real-final")
native = parse_log(root / "native-suite.log")
axvisor = parse_log(root / "axvisor-only-suite/console.log")

for metric in sorted(set(native) & set(axvisor)):
    print(metric, compare_joint(native[metric], axvisor[metric]))
PY
```

正式的 100000 样本/300 秒复现入口仍为：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
bash os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 100000 --stability-seconds 300 \
  --output "$PWD/tmp/rtthread-realtime-stability-300-20260821-rerun"
```

