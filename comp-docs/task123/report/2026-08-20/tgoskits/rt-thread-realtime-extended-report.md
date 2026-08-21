# RT-Thread 实时性扩展测试报告

日期：2026-08-20

本报告测试对象是 RT-Thread；Linux 只作为 C 场景的 2-vCPU 共存负载。测试使用真实
QEMU 11.0.2 AArch64 `virt`，宿主为 x86_64，QEMU 使用 TCG。报告中的“通过”表示样本
完整和功能门禁通过，不代表物理硬实时 WCET 证明。

## 场景和配置

| 场景 | 配置 | 目的 |
|---|---|---|
| A | native RT-Thread on QEMU，1 vCPU | RT-Thread 相对基线 |
| B | AxVisor + RT-Thread，RT-Thread vCPU 固定 pCPU 2 | 虚拟化基础开销 |
| C | AxVisor + 2-vCPU Linux + RT-Thread，Linux 使用 pCPU 0/1/3，RT-Thread 固定 pCPU 2 | Linux、virtio-net 和设备路径共存影响 |

C 场景确认 Linux 启动标记为 `LINUX_SMP_READY configured=2 online=0-1 nproc=2`，并
完成 RT-IPC 网络压力和 Task 3 AI 控制闭环。RT-Thread 仍采用静态 CPU 分区，Linux
vCPU 不使用 pCPU 2。

## 指标覆盖

正式 suite 每个指标采集 100000 个样本：

- `timer_jitter`、`callback_exec`：各运行 3 轮，汇总器保留最大尾延迟轮次；
- `preemption`、`irq`、`irq_to_task`、`irq_disabled_duration`、`mutex_inversion`、
  `wake_under_load`、`net_event_latency`：各运行 1 轮；
- 每条记录包含 expected/collected/missing、P50/P95/P99/P99.9/max/mean 和
  100us/500us/1ms 超时计数。

`irq_disabled_duration` 是受控临界区的持续时间，不是整个系统所有关中断区间的 WCET。
`net_event_latency` 是 Linux probe 经 virtio-net/IP/UDP 到 RT-Thread RX IRQ hook，再到
RT-Thread ACK 的测量；它不使用共享内存、HyperCall、裸 MMIO 或 vsock。

## 正式 Suite 结果

单位为 ns；A/B/C 均为 `100000/100000`、`missing=0`。表中给出 P99/max，重复指标按
最大 max 的轮次比较。

| 指标 | A native | B AxVisor | C AxVisor + 2-vCPU Linux |
|---|---:|---:|---:|
| timer_jitter | 14,608 / 180,192 | 20,656 / 523,424 | 385,888 / 2,502,288 |
| callback_exec | 448 / 32,464 | 5,744 / 257,472 | 1,936 / 371,136 |
| preemption | 6,256 / 13,216 | 4,736 / 137,472 | 5,344 / 134,112 |
| irq | 5,808 / 46,544 | 116,592 / 388,176 | 89,424 / 297,632 |
| irq_to_task | 3,120 / 39,328 | 282,704 / 503,904 | 286,944 / 537,552 |
| irq_disabled_duration | 240 / 20,144 | 320 / 227,456 | 320 / 198,080 |
| mutex_inversion | 12,656 / 49,360 | 22,720 / 402,016 | 19,504 / 393,216 |
| wake_under_load | 1,568 / 12,448 | 2,960 / 233,488 | 2,992 / 299,216 |
| net_event_latency | 79,680 / 1,201,248 | 不适用：无第二个客户机 | 504,944 / 948,912 |

相对比较：

- C/B 的 `preemption` P99 为 `1.13x`，`irq` 为 `0.77x`，`irq_to_task` 为 `1.02x`；
- C/B 的 `timer_jitter` P99 为 `18.68x`，最大值为 `4.78x`，是共存场景最明显的尾延迟；
- C/B 的 `mutex_inversion` P99 为 `0.86x`，`wake_under_load` 为 `1.01x`；
- C 的 `net_event_latency` P99 为 `504.944 us`，最大值为 `948.912 us`，样本完整且
  `irq_dropped=0`、`probe_received=100000`、`probe_acked=100000`。

严格 `max <= 1 ms` 不是所有指标都满足：C 的 timer jitter 三轮分别出现 1ms 以上尾部，
汇总最大值为 `2.502 ms`；A 的网络 probe 最大值也为 `1.201 ms`。因此本轮不能称为
严格硬实时通过，但 C 的数据完整性和实时路径功能门禁通过。

## C 场景功能结果

- Linux 2-vCPU：`configured=2 online=0-1 nproc=2`；
- Task 2：64B/256B/1024B 均 `30000/30000`，丢包 0、请求超时 0、协议错误 0，完成
  1 次预期重连；
- Task 3：`6/6` 成功，分类 `3/3`，准确率 `100%`，RT-Thread 最终
  `requests=9 errors=0 duplicates=0 applied_steps=3 retries=0`；
- RTBench：`RTBENCH_END status=PASS`，9 类指标全部完整；
- C 场景 QEMU 退出码为 0，结果 gate 为 `PASS`。

## 评估

RT-Thread 的普通调度、互斥和负载唤醒路径在 A/B/C 中都能完整采样；但虚拟 IRQ 到任务
路径约 280us 的 P99，以及 Linux 共存时 timer jitter 达到 2.5ms 的最大值，说明当前
平台不能宣称“非常优秀”的最坏情况实时性。静态分区只消除了 AxVisor 内部 Linux vCPU
与 RT-Thread vCPU 的直接 CPU 竞争，不能消除 QEMU TCG 主循环、TCG vCPU 线程、虚拟
timer/VGIC 投递、virtio-net/NVMe 设备模拟和宿主调度带来的长尾。

因此结论为：

1. 实时指标覆盖和 A/B/C 基线对比已完成，C 场景正式 suite 通过；
2. RT-Thread 的功能和跨客户机网络链路已通过 100000 次网络事件样本验证；
3. 当前 QEMU TCG 平台仍不满足严格毫秒级最坏延迟保证，需在 KVM/真实 AArch64 硬件上
   复测，才能区分 TCG 长尾和 AxVisor 本身开销。

## 证据和复现

原始证据目录：

`history-docs/task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-extended/`

其中包含 A/B/C console、host metrics、manifest、Task 3 CSV、比较 CSV/JSON 和
`SHA256SUMS`。汇总命令：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
python3 os/axvisor/scripts/summarize_rtthread_realtime.py \
  --native tmp/rtthread-realtime-formal-20260820-deadline.pWYJ0N/native-suite.log \
  --axvisor-only tmp/rtthread-realtime-formal-20260820-deadline.pWYJ0N/axvisor-only-suite/console.log \
  --axvisor-linux tmp/rtthread-realtime-c-20260820.jLCp7A/console.log \
  --suite-samples 100000 --axvisor-only-core
```

C 场景使用最新 Alpine Linux `Image`/`rootfs.cpio.gz`，RT-Thread 源码来自持久缓存
`tmp/source-cache/rt-thread/ddf52e2cdd977f14fc04035c88672ac204aec713/source`。运行器的
阶段命令现在通过 `run_timed_foreground.sh` 保持实时输出，并在超时时回收整个阶段进程组。

## 后续优化

1. 在 AxVisor 虚拟 GIC 路径分别记录 trap、inject、EOI 和 vCPU wake 时间；
2. 在 KVM/真实硬件上重复 A/B/C，并交换客户机启动顺序；
3. 隔离 QEMU TCG main loop、设备模拟线程和 RT-Thread vCPU 的宿主调度；
4. 针对 timer jitter 的 2.5ms 长尾做宿主调度和设备负载归因；
5. 保留 `net_event_latency` 的 ACK 驱动 probe，继续测试网络中断丢失、重复和恢复。
