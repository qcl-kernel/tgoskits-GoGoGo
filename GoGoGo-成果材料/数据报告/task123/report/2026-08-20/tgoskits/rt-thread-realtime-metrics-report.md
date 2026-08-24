# RT-Thread 实时性指标补足与 A/B/C 基线报告

日期：2026-08-20  
代码基线：`origin/dev` 工作区（AxVisor + RT-Thread + 2-vCPU Linux/StarryOS）  
RT-Thread：commit `ddf52e2cdd977f14fc04035c88672ac204aec713`  
QEMU：`/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`，11.0.2，TCG 模式

## 1. 测试对象与场景

本报告的实时性对象是 RT-Thread，不是 Linux/StarryOS。Linux 仅作为共存负载存在。

| 场景 | 定义 | CPU/内存布局 | 用途 |
|---|---|---|---|
| A | native RT-Thread on QEMU virt | 1 vCPU，1 GiB | 无虚拟化基线 |
| B | AxVisor + RT-Thread only | RT-Thread vCPU 绑定 CPU2，GPA `0xa0000000-0xb0000000` | AxVisor 基础虚拟化开销 |
| C | AxVisor + 2-vCPU Linux + RT-Thread + 网络/Task3 负载 | Linux vCPU affinity CPU0/1/3，RT-Thread 绑定 CPU2 | 共存与设备路径干扰 |

C 场景包含 RT-IPC TCP 压测 30,000×3 请求和 Task3 闭环，不能把 Linux 的调度延迟或应用层 RTT 混同为 RTOS 实时性指标。

## 2. 指标覆盖

### 已实现指标

| 指标 | 测量路径 | 样本数 |
|---|---|---:|
| `timer_jitter` | 1 ms 周期定时器回调释放抖动，3 轮 | 每轮 100,000 |
| `callback_exec` | 定时器回调执行时间 | 每轮 100,000 |
| `preemption` | 低优先级线程释放到高优先级线程首条采样指令 | 100,000 |
| `irq` | 软件 SPI/SGI 触发到 ISR 首条采样指令 | 100,000 |
| `irq_to_task` | IRQ 到 ISR、唤醒高优先级任务并执行首条采样指令 | 100,000 |
| `irq_disabled_duration` | 受控关中断临界区持续时间 | 100,000 |
| `mutex_inversion` | 低优先级持锁 + 中优先级干扰 + 高优先级等待，含优先级继承 | 100,000 |
| `wake_under_load` | CPU 负载下唤醒高优先级任务 | 100,000 |
| `stability_jitter` | 连续 300 s 周期任务抖动 | 299,999 |

`timer_jitter` 和 `callback_exec` 在 suite 中重复 3 轮，汇总取最差 max 的轮次；稳定性测试单独运行 300 s。

### 本报告快照中的未实现项

本报告原始快照生成时，`net_event_latency` 尚未接入，因此原有表格不包含该项。随后已在
RT-Thread virtio-net RX 路径中加入 IRQ hook 和独立的 `rx_irq_used_idx` 扫描游标，覆盖
virtio-net RX 中断到 RT-Thread ACK 的网络事件延迟，并修复了重复扫描导致的失真。

更新后的 A/B/C 结果、1000 样本原始 JSON/CSV 和证据见：

[RT-Thread A/B/C 指标补足与基线报告](rt-thread-realtime-baseline-suite-20260820-report.md)

## 3. 结果

### 3.1 100,000 样本 suite

表中数值单位为 ns。`miss_100us/500us/1ms` 表示超过对应阈值的样本数。

| 指标 | 场景 | p50 | p95 | p99 | p99.9 | max | mean | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| timer_jitter | A | 448 | 2,976 | 11,168 | 36,624 | 177,184 | 1,029 | 5 | 0 | 0 |
| timer_jitter | B | 3,264 | 12,720 | 19,776 | 140,288 | 1,905,136 | 4,756 | 165 | 1 | 1 |
| timer_jitter | C | 56,528 | 375,776 | 442,512 | 493,472 | 816,576 | 109,290 | 36,960 | 45 | 0 |
| callback_exec | A | 112 | 176 | 496 | 9,552 | 38,960 | 173 | 0 | 0 | 0 |
| callback_exec | B | 432 | 512 | 672 | 4,272 | 129,888 | 453 | 3 | 0 | 0 |
| callback_exec | C | 512 | 704 | 2,576 | 15,104 | 253,120 | 650 | 45 | 0 | 0 |
| preemption | A | 1,952 | 2,048 | 4,272 | 11,872 | 15,024 | 2,038 | 0 | 0 | 0 |
| preemption | B | 5,136 | 5,344 | 5,536 | 7,312 | 133,376 | 4,977 | 13 | 0 | 0 |
| preemption | C | 5,104 | 5,344 | 5,792 | 118,160 | 133,424 | 5,285 | 153 | 0 | 0 |
| irq | A | 1,680 | 1,744 | 3,552 | 11,616 | 44,448 | 1,759 | 0 | 0 | 0 |
| irq | B | 81,392 | 83,952 | 85,504 | 120,384 | 410,944 | 81,759 | 288 | 0 | 0 |
| irq | C | 76,672 | 106,160 | 111,488 | 128,224 | 251,328 | 79,773 | 10,197 | 0 | 0 |
| irq_to_task | A | 2,416 | 2,432 | 2,816 | 9,632 | 27,936 | 2,441 | 0 | 0 | 0 |
| irq_to_task | B | 85,616 | 281,424 | 287,584 | 301,600 | 461,200 | 106,776 | 11,436 | 0 | 0 |
| irq_to_task | C | 79,872 | 264,464 | 273,088 | 376,080 | 424,752 | 98,165 | 9,721 | 0 | 0 |
| irq_disabled_duration | A | 224 | 240 | 240 | 432 | 20,320 | 228 | 0 | 0 | 0 |
| irq_disabled_duration | B | 224 | 256 | 336 | 1,088 | 254,592 | 263 | 14 | 0 | 0 |
| irq_disabled_duration | C | 224 | 256 | 320 | 1,616 | 189,648 | 256 | 11 | 0 | 0 |
| mutex_inversion | A | 5,040 | 10,816 | 12,208 | 22,112 | 233,632 | 5,687 | 1 | 0 | 0 |
| mutex_inversion | B | 7,664 | 12,688 | 22,800 | 232,256 | 380,240 | 8,425 | 924 | 0 | 0 |
| mutex_inversion | C | 11,168 | 12,768 | 22,288 | 216,096 | 360,112 | 8,273 | 886 | 0 | 0 |
| wake_under_load | A | 1,488 | 1,520 | 1,536 | 7,984 | 11,760 | 1,504 | 0 | 0 | 0 |
| wake_under_load | B | 1,680 | 1,904 | 3,072 | 204,960 | 251,872 | 2,172 | 231 | 0 | 0 |
| wake_under_load | C | 1,664 | 1,888 | 3,072 | 190,016 | 301,696 | 2,118 | 223 | 0 | 0 |

所有 suite 指标均完成采样，样本缺失为 0。

### 3.2 300 秒稳定性

| 指标 | 场景 | p50 | p95 | p99 | p99.9 | max | mean | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| stability_jitter | A | 368 | 2,416 | 9,584 | 30,384 | 180,592 | 764 | 6 | 0 | 0 |
| stability_jitter | B | 2,272 | 8,240 | 15,232 | 137,872 | 386,544 | 3,401 | 638 | 0 | 0 |
| stability_jitter | C | 27,648 | 315,984 | 413,056 | 446,704 | 816,960 | 83,455 | 90,742 | 20 | 0 |
| callback_exec | A | 112 | 176 | 432 | 9,488 | 34,080 | 179 | 0 | 0 | 0 |
| callback_exec | B | 448 | 528 | 688 | 1,344 | 132,032 | 467 | 3 | 0 | 0 |
| callback_exec | C | 544 | 656 | 912 | 3,792 | 197,888 | 611 | 120 | 0 | 0 |

三个场景稳定性样本均为 299,999/299,999，缺失 0。

## 4. 评估

采用当前项目门禁：

- 数据完整性：样本缺失 0；
- 良好：p99 < 100 us；
- 可接受：p99.9 < 500 us；
- 严格尾部：max < 1 ms。

### A：native 基线

除个别尾部外，native RT-Thread 的 p50 在数百 ns 到数 us，p99 基本小于 12 us，300 s 内无 >1ms 事件。作为 QEMU TCG 下的相对基线，它是健康的。

### B：AxVisor 基础开销

B 的周期抖动 p50 约 3.3 us，p99 约 19.8 us，仍可接受。但 `irq` 和 `irq_to_task` 出现约 80-106 us 的平台，说明虚拟中断注入路径存在固定开销。100,000 样本 suite 中出现 1 次 1.905 ms 周期抖动长尾，导致严格门禁失败；300 s 稳定性中未复现 >1ms。

### C：Linux/网络共存

C 的周期抖动显著退化：p50 约 56.5 us，p95 约 375.8 us，p99 约 442.5 us，mean 约 109.3 us；虽然本轮 suite 和 300 s 稳定性均无 >1ms，但 30% 样本超过 100 us。相比 B，这说明主要退化来自共存/设备路径，而不是 RT-Thread 调度器本身。

### 结论

当前结果不能称为“非常优秀”：

1. A 作为相对基线表现好；
2. B 的 p99 仍可接受，但虚拟中断路径固定开销和罕见毫秒级长尾需要优化；
3. C 未达到严格实时系统的期望分布，p99 已接近 0.5 ms，且大量样本超过 100 us。

QEMU TCG 会放大绝对延迟并引入宿主机调度长尾，因此这些数据用于 A/B/C 相对比较，不应当作硬件 WCET。

## 5. 问题定位

1. **虚拟中断注入开销**：B 的 `irq`/`irq_to_task` p50 从 A 的 1.7/2.4 us 增至约 81/86 us，主要指向 AxVisor 拦截 SPI 并经虚拟 GIC 注入的路径。
2. **C 的周期任务退化**：C 相比 B 的 p50 增大一个数量级以上，且与网络压测共存，优先怀疑 virtio-net/NVMe 设备仿真、vCPU 唤醒、宿主机 QEMU 线程调度和共享设备路径。
3. **罕见毫秒级长尾**：B suite 出现 1.905 ms 单次事件，而 300 s 稳定性未复现，具有低频突发特征，需硬件平台或更长时间统计确认。
4. **关中断临界区本身很小**：B/C 的 p50 约 224 ns，说明受控临界区不是主要瓶颈；但其尾部可能被异常/设备路径打断。

## 6. 后续优化计划

1. 在 AxVisor 虚拟 GIC 注入路径中区分 trap、inject、EOI、vCPU wake 的耗时，目标是把 B 的 `irq`/`irq_to_task` p50 从约 80 us 降到 20 us 内；
2. 为 RT-Thread virtio-net RX 路径增加 `net_event_latency`，覆盖 IRQ/used-ring 到 lwIP 输入的耗时；
3. 将 C 的设备仿真线程与 RT-Thread vCPU 的宿主机线程隔离，减少 QEMU TCG 线程相互抢占；
4. 降低 AxVisor 周期调度 tick 对静态分区 CPU 的干扰，扩大 tickless 覆盖范围；
5. 对 B 的毫秒级长尾做长时间硬件复测，并在 AxVisor 中记录 vCPU exit/inject 时间戳；
6. 保留严格门禁：p99 < 100 us、p99.9 < 500 us、max < 1 ms。

## 7. 复现方式

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 100000 \
  --stability-seconds 300 \
  --output tmp/rtbench-formal-20260820T054500Z
```

原始数据和汇总：

- `tmp/rtbench-formal-20260820T054500Z/realtime-suite.csv`
- `tmp/rtbench-formal-20260820T054500Z/realtime-suite.json`
- `tmp/rtbench-formal-20260820T054500Z/stability/realtime-stability.csv`
- `tmp/rtbench-formal-20260820T054500Z/stability/realtime-stability.json`
