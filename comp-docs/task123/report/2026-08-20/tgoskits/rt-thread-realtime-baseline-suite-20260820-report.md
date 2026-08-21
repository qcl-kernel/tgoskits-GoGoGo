# RT-Thread 实时性指标补足与 A/B/C 基线报告

日期：2026-08-20  
测试对象：RT-Thread（Linux 仅作为 C 场景的共存负载）  
QEMU：11.0.2，AArch64 `virt`，Cortex-A72，TCG  
原始输出：`tgoskits/tmp/rtthread-realtime-baseline-suite-20260820.wJvMRp/`

## 1. 本轮结论

本轮完成了 RT-Thread 实时性指标补足和 A/B/C 基线对照。三组运行器状态均为
`PASS`，每个已适用指标均为 `expected=1000 collected=1000 missing=0`。这里的
`PASS` 表示功能、样本完整性和结果采集门禁通过；C 场景的严格最坏延迟门禁仍为
`strict_tail_pass=false`，不能据此宣称硬实时保证。

| 场景 | 配置 | 用途 |
|---|---|---|
| A | native RT-Thread，QEMU virt，1 vCPU | RT-Thread 原生基线 |
| B | AxVisor + RT-Thread，RT-Thread vCPU 固定 pCPU 2 | AxVisor 基础开销 |
| C | AxVisor + 2-vCPU Linux + RT-Thread，Linux 使用 pCPU 0/1/3，RT-Thread 固定 pCPU 2 | Linux、virtio-net 和设备路径共存影响 |

Linux 启动确认：`configured=2 online=0-1 nproc=2`。RT-Thread 使用静态 CPU 分区，
不会和 Linux vCPU 争用 pCPU 2。

## 2. 指标覆盖

本轮 suite 已覆盖以下 RTOS 指标：

| 指标 | 含义 |
|---|---|
| `timer_jitter` | 1 ms 周期任务的释放抖动 |
| `callback_exec` | 周期回调执行时间 |
| `preemption` | 低优先级任务释放到高优先级任务运行的延迟 |
| `irq` | 虚拟中断触发到 RT-Thread ISR 入口的延迟 |
| `irq_to_task` | 中断触发到被唤醒高优先级任务运行的延迟 |
| `irq_disabled_duration` | 受控关中断临界区持续时间 |
| `mutex_inversion` | 互斥锁优先级反转路径延迟 |
| `wake_under_load` | CPU 负载下的任务唤醒延迟 |
| `net_event_latency` | Linux UDP probe 经 virtio-net/IP/UDP 到 RT-Thread RX IRQ hook 并完成 ACK 的延迟 |

`net_event_latency` 已通过独立的 `rx_irq_used_idx` 扫描游标修复重复采样问题；本轮
结果为 `irq_dropped=0`、`probe_received=1000`、`probe_acked=1000`、
`probe_no_irq=0`、`probe_duplicates=0`。B 场景只有一个客户机，没有跨客户机网络
对端，因此该指标在 B 中标记为不适用，不作为缺失样本处理。

## 3. 结果数据

单位为 ns。每行依次为 P50、P95、P99、P99.9、最大值；A/B/C 均无缺失样本。

| 指标 | A native | B AxVisor only | C AxVisor + 2-vCPU Linux |
|---|---:|---:|---:|
| `timer_jitter` | 592 / 3,744 / 23,968 / 44,384 / 47,808 | 3,856 / 49,216 / 229,696 / 371,344 / 389,440 | 4,544 / 16,864 / 52,608 / 328,864 / 353,520 |
| `callback_exec` | 96 / 192 / 1,664 / 8,768 / 32,944 | 656 / 928 / 1,312 / 2,720 / 41,376 | 544 / 976 / 1,376 / 5,920 / 44,192 |
| `preemption` | 2,064 / 2,496 / 4,480 / 11,744 / 15,808 | 4,192 / 4,928 / 12,384 / 14,512 / 14,960 | 4,224 / 4,768 / 6,992 / 1,039,920 / 1,040,656 |
| `irq` | 1,712 / 5,136 / 11,280 / 11,568 / 56,656 | 77,472 / 80,240 / 83,888 / 206,736 / 262,560 | 75,440 / 95,616 / 288,368 / 410,528 / 1,529,360 |
| `irq_to_task` | 3,040 / 3,104 / 4,896 / 9,792 / 33,104 | 80,400 / 289,424 / 301,264 / 355,056 / 359,184 | 76,720 / 285,776 / 919,040 / 968,256 / 1,544,784 |
| `irq_disabled_duration` | 288 / 304 / 304 / 2,800 / 23,792 | 224 / 240 / 336 / 27,168 / 229,088 | 224 / 240 / 240 / 2,304 / 21,456 |
| `mutex_inversion` | 8,128 / 13,520 / 15,072 / 28,224 / 33,968 | 11,328 / 11,888 / 47,984 / 264,336 / 276,080 | 11,312 / 13,920 / 247,296 / 1,649,584 / 1,722,688 |
| `wake_under_load` | 1,696 / 1,728 / 1,760 / 11,824 / 19,856 | 1,552 / 1,776 / 2,656 / 219,392 / 231,664 | 1,536 / 1,968 / 3,296 / 7,920 / 199,312 |
| `net_event_latency` | 29,232 / 43,376 / 79,904 / 113,296 / 137,824 | 不适用 | 854,688 / 1,722,720 / 1,907,680 / 1,977,328 / 1,978,272 |

超过阈值的关键计数如下：

| 指标/场景 | >100 us | >500 us | >1 ms |
|---|---:|---:|---:|
| `timer_jitter` A/B/C | 0 / 41 / 4 | 0 / 0 / 0 | 0 / 0 / 0 |
| `preemption` A/B/C | 0 / 0 / 6 | 0 / 0 / 4 | 0 / 0 / 2 |
| `irq` A/B/C | 0 / 2 / 48 | 0 / 0 / 1 | 0 / 0 / 1 |
| `irq_to_task` A/B/C | 0 / 92 / 113 | 0 / 0 / 43 | 0 / 0 / 1 |
| `mutex_inversion` A/B/C | 0 / 10 / 19 | 0 / 0 / 9 | 0 / 0 / 6 |
| `net_event_latency` A/C | 2 / 1000 | 0 / 762 | 0 / 162 |

## 4. 基线对比与评估

相对 A，B 的基础虚拟化开销主要集中在虚拟中断路径：`irq` P50 从 1.712 us 增至
77.472 us，`irq_to_task` P50 从 3.040 us 增至 80.400 us。周期任务和受控关中断
路径仍保持完整采样，但出现了几十到数百微秒的尾部。

相对 B，C 的中位数并未全面恶化：`timer_jitter` P99 为 0.23 倍，`irq_to_task` P50
为 0.95 倍，`wake_under_load` P50 为 0.99 倍。但 C 的最坏值在 `preemption`、`irq`、
`irq_to_task` 和 `mutex_inversion` 中分别达到 1.041 ms、1.529 ms、1.545 ms 和
1.723 ms，说明 Linux/设备共存会放大低频长尾。

网络事件延迟 C 为 P50 854.688 us、P99 1.908 ms、最大 1.978 ms，且 1000 个 probe
全部收到 ACK。它证明网络中断和应用 ACK 链路完整，但不应与 A 的 native 网络路径
直接当作同一拓扑下的 WCET 对比。

本轮结论：

1. RT-Thread 的测试指标已补足，A/B/C 基线对比和数据采集已完成。
2. A 是当前 QEMU TCG 条件下的相对健康基线；B 证明 AxVisor 引入了可测量的虚拟中断开销。
3. C 的功能、样本完整性和网络链路通过，但严格 `max < 1 ms` 不通过，不能称为“非常优秀”的最坏情况实时性。
4. 长尾应归因于组合路径：QEMU TCG 的 main loop/TCG vCPU 调度、虚拟 timer/VGIC 投递、
   virtio-net 设备处理和 Linux 共存负载。静态分区只能消除 AxVisor 内部 vCPU 的直接
   pCPU 竞争，不能隔离 QEMU 线程和宿主调度器。

## 5. 长时间稳定性边界

本轮 A/B/C 对照只执行 1000 样本 suite，没有重新执行 300 秒稳定性测试。因此本报告
不把 suite 结果表述为长时间稳定性结论。已有 300 秒数据仍保留在：

`history-docs/task123/report/2026-08-20/tgoskits/rt-thread-realtime-extended-report.md`

该报告中的长稳数据显示 C 场景存在 QEMU TCG 条件下的毫秒级长尾；后续应在真实
AArch64/KVM 或实时宿主上重复 A/B/C，并拆分 trap、inject、EOI、vCPU wake 时间。

## 6. 复现与证据

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 1000 \
  --skip-stability \
  --output tmp/rtthread-realtime-baseline-suite-20260820-rerun
```

汇总文件：

- `realtime-suite.json`：完整结构化结果和严格尾部评估；
- `realtime-suite.csv`：按指标/场景展开的统计数据；
- `status.tsv`：A/B/C 运行器状态；
- `native-suite.log`、`axvisor-only-suite/console.log`、`axvisor-linux-suite/console.log`：三组原始 guest 输出。

本轮证据已归档到：

`history-docs/task123/evidence/2026-08-20/tgoskits/rtthread-realtime-baseline-suite-1000/`

