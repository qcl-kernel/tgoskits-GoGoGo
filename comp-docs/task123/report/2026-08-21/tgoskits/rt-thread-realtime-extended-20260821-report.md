# RT-Thread 实时性扩展正式复测报告

日期：2026-08-21

本报告对象是 RT-Thread。Linux 仅作为 C 场景的 2-vCPU 共存负载。测试使用真实 QEMU
11.0.2、AArch64 `virt`、GICv3 和 TCG；宿主为 x86_64。因此结果用于比较和定位，不是
物理 AArch64 平台上的硬实时 WCET 证明。

## 1. 场景与配置

| 场景 | 配置 | 目的 |
|---|---|---|
| A | native RT-Thread on QEMU，1 vCPU | RT-Thread 基线 |
| B | AxVisor + RT-Thread，RT-Thread vCPU 固定 pCPU 2 | 虚拟化基础开销 |
| C | AxVisor + 2-vCPU Linux + RT-Thread，Linux 使用 pCPU 0/1/3，RT-Thread 固定 pCPU 2 | Linux、virtio-net 和设备路径共存影响 |

C 场景确认 Linux 输出 `LINUX_SMP_READY configured=2 online=0-1 nproc=2`。RT-Thread
实时客户机保持静态 CPU 分区，Linux vCPU 不使用 pCPU 2。

## 2. 指标覆盖

suite 覆盖 `timer_jitter`、`callback_exec`、`preemption`、`irq`、`irq_to_task`、
`irq_disabled_duration`、`mutex_inversion`、`wake_under_load`、`context_switch`、
`scheduler_decision`、`sync_sem`、`sync_mutex`、`sync_mailbox`、`irq_handler_exec`、
`deadline_miss_under_load` 和 `net_event_latency`。每项记录 expected、collected、missing、
P50/P95/P99/P99.9/max/mean，以及 100 us、500 us、1 ms 超时计数；新增开销指标的短时
A/B/C 对照数据见第 6.2 节。

`irq_disabled_duration` 是受控合成临界区的持续时间，不代表系统全部关中断区间的 WCET。
`net_event_latency` 通过 Linux probe 经 virtio-net/IP/UDP 到 RT-Thread 接收路径并返回
ACK 测量，不使用共享内存、HyperCall、裸 MMIO 或 vsock。

## 3. 100000 样本 suite

单位为 ns；所有核心指标 A/B/C 都是 `100000/100000`，`missing=0`。`net_event_latency`
在 B 中不适用，因为 AxVisor-only 没有第二个客户机。

| 指标 | A P99 / max | B P99 / max | C P99 / max |
|---|---:|---:|---:|
| timer_jitter | 12,240 / 242,096 | 26,576 / 585,232 | 441,824 / 905,040 |
| callback_exec | 448 / 36,976 | 608 / 149,904 | 1,920 / 173,072 |
| preemption | 8,240 / 16,640 | 5,280 / 147,152 | 5,648 / 139,840 |
| irq | 6,144 / 49,552 | 83,136 / 276,176 | 84,064 / 294,528 |
| irq_to_task | 2,704 / 33,840 | 305,744 / 883,840 | 289,088 / 781,776 |
| irq_disabled_duration | 240 / 20,112 | 320 / 234,320 | 368 / 212,240 |
| mutex_inversion | 11,760 / 51,040 | 18,384 / 394,320 | 22,752 / 1,035,504 |
| wake_under_load | 1,392 / 41,152 | 3,088 / 251,536 | 3,232 / 429,984 |
| net_event_latency | 99,200 / 199,776 | N/A | 939,536 / 1,786,752 |

suite 的数据完整性和 RTBench 功能门禁均通过。按严格 `max <= 1 ms` 评估：A、B 通过，
C 不通过，超限项为 `mutex_inversion` 和 `net_event_latency`。C 的 `timer_jitter` 最大值
仍低于 1 ms。

## 4. 300 秒稳定性

三组均采集 `299999/299999` 个周期样本，`missing=0`，且 `miss_1ms=0`；结果门禁为
`PASS`。

| 指标 | A native | B AxVisor-only | C AxVisor + Linux |
|---|---:|---:|---:|
| stability jitter P50 | 0.624 us | 3.472 us | 66.960 us |
| stability jitter P95 | 3.200 us | 14.464 us | 370.080 us |
| stability jitter P99 | 10.608 us | 23.056 us | 422.208 us |
| stability jitter P99.9 | 37.280 us | 148.912 us | 443.392 us |
| stability jitter max | 176.432 us | 421.280 us | 827.280 us |
| callback max | 36.672 us | 150.464 us | 172.048 us |

相对于 A，C 的稳定性抖动 P99 约为 39.8 倍；相对于 B 约为 18.3 倍。300 秒窗口内没有
超过 1 ms 的周期样本，说明本轮运行稳定，但不能推出所有运行条件下的最坏情况保证。

## 5. C 场景网络与控制结果

- RT-IPC 64B、256B、1024B 均为 `30000/30000`，请求超时、协议错误、重传和乱序均为 0。
- 64B 完成 1 次强制断连恢复；256B/1024B 无额外重连。
- Task 3 为 `6/6` 成功，分类 `3/3`，准确率 `100%`，RT-Thread 最终为
  `requests=9 errors=0 duplicates=0 applied_steps=3 retries=0`。
- C 场景 QEMU 退出码为 0，结果 gate 为 `PASS`。

## 6. 结论

静态分区有效隔离了 RT-Thread 与 Linux vCPU 的直接 CPU 竞争，且 300 秒稳定性测试没有
出现样本丢失或 1 ms 周期超时。但 C 场景 suite 的 `mutex_inversion` 最大值约 1.04 ms、
网络事件最大值约 1.79 ms，不能称为严格硬实时通过，也不能称为“非常优秀”的最坏情况
实时性。

当前长尾主要受 x86_64 宿主上的 QEMU TCG 主循环、TCG vCPU/设备线程、虚拟 timer/VGIC
投递、virtio-net/NVMe 模拟和宿主调度影响。静态绑定 pCPU 只能约束 AxVisor 内部调度，
不能消除这些宿主侧延迟。需要在 KVM 或真实 AArch64 硬件上重复 A/B/C，才能把 TCG 长尾
与 AxVisor 本身开销分离，并进一步做 IRQ trap/inject/EOI/vCPU wake 时间归因。

## 6.1 三计数器联合分析方法

RTBench 的每个样本同时读取 `CNTVCT_EL0`、`PMCCNTR_EL0` 和事件 `0x08` 的
`PMEVCNTR0_EL0`。报告将三者联合使用：`ns` 负责实时性截止期判定，`cycles` 负责虚拟
执行工作量，`instructions` 负责 Guest 指令路径工作量。分析器还从同一批样本的均值计算
`ns/instruction`、`cycles/instruction` 和 `ns/cycle`，并比较 A/B/C 的 P99 比例。

归因分类为启发式：延迟单独增大标记 `latency_only`，三者同时增大标记 `path_expansion`，
部分增大标记 `mixed`，三者均稳定标记 `stable`。三类 P99 是独立分布，不能解释为同一个
样本；绝对实时性结论仍以纳秒的 `max` 和 `miss_1ms` 为准。

新增结果文件：

```text
realtime-suite-joint.csv
realtime-stability-joint.csv
```

对应 JSON 的 `joint_analysis` 和 Markdown 的“联合三指标分析”表用于最终报告。

## 6.2 新增开销指标短时 A/B/C 对照

为验证新增测试本身并取得同版本基线，使用当前代码、同一真实 QEMU 参数运行 A/B/C 各
3 个样本。三组新增指标均为 `3/3`、`missing=0`。这轮样本量只用于功能、路径和相对开销
对照，不替代第 3 节的 100000 样本统计。

| 指标 | A P99 / max ns | B P99 / max ns | C P99 / max ns | B/A P99 | C/A P99 |
|---|---:|---:|---:|---:|---:|
| context_switch | 3,360 / 3,360 | 9,728 / 9,728 | 3,360 / 3,360 | 2.90x | 1.00x |
| scheduler_decision | 1,008 / 1,008 | 1,008 / 1,008 | 1,008 / 1,008 | 1.00x | 1.00x |
| sync_sem | 2,704 / 2,704 | 52,912 / 52,912 | 2,704 / 2,704 | 19.57x | 1.00x |
| sync_mutex | 3,584 / 3,584 | 3,584 / 3,584 | 3,584 / 3,584 | 1.00x | 1.00x |
| sync_mailbox | 2,912 / 2,912 | 2,912 / 2,912 | 17,968 / 17,968 | 1.00x | 6.17x |
| irq_handler_exec | 176 / 176 | 176 / 176 | 176 / 176 | 1.00x | 1.00x |
| deadline_miss_under_load | 960 / 960 | 1,756,336 / 1,756,336 | 370,272 / 370,272 | 1829.52x | 385.70x |

新增指标按 `max <= 1 ms` 的短时门槛评估：A 和 C 的 7 项均通过，B 仅
`deadline_miss_under_load` 超限；B 的 `timer_jitter`、`irq`、`irq_to_task` 等既有指标仍
显示明显 TCG 长尾，因此不能把“新增指标通过”解释为 B/C 整体硬实时通过。C 相对 B 在
`context_switch`、`sync_sem` 等指标更低，但 `sync_mailbox` 和截止期测试仍显示共存负载的
调度/设备影响。

同一轮 C 的新增指标还输出了 PMU 工作量。例如 `context_switch` P99 为
`3360 cycles / 420 instructions`，`deadline_miss_under_load` P99 为
`569024 cycles / 71128 instructions`。这些数值用于判断路径执行量；QEMU TCG 下是虚拟
PMU 计数，不能消除 TCG 主循环、虚拟 timer/VGIC、virtio 和宿主调度造成的纳秒长尾。

对照证据和机器生成结果：

```text
tmp/rtthread-realtime-overhead-abcs-20260821/native-suite.log
tmp/rtthread-realtime-overhead-abcs-20260821/axvisor-only-suite-rerun/console.log
tmp/rtbench-overhead-qemu-run6/console.log
tmp/rtthread-realtime-overhead-abcs-20260821/realtime-suite.json
tmp/rtthread-realtime-overhead-abcs-20260821/realtime-suite.csv
tmp/rtthread-realtime-overhead-abcs-20260821/realtime-suite-joint.csv
```

短时对照命令为：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 3 --skip-stability \
  --output "$PWD/tmp/rtthread-realtime-overhead-abcs-20260821"
```

## 7. 证据与复现

原始证据：

`history-docs/task123/evidence/2026-08-21/tgoskits/rt-thread-realtime-extended/`

测试脚本：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
bash os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 100000 --stability-seconds 300 \
  --output "$PWD/tmp/rtthread-realtime-stability-300-20260821-rerun"
```

本次运行复用了本地 RT-Thread、Alpine rootfs、Linux 和 QEMU 缓存；没有使用 fake QEMU。
