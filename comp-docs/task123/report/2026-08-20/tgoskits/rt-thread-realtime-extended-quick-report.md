# RT-Thread 实时性扩展指标 Quick 对照报告

日期：2026-08-20  
测试目录：`tgoskits/tmp/rtthread-realtime-current-quick-20260820`  
QEMU：`/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`，QEMU 11.0.2，AArch64 `virt`，GICv3，Cortex-A72，TCG

## 1. 本轮结论

本轮真实 QEMU quick 测试完整通过，A/B/C 三组均完成，所有实时性样本没有缺失：

| 场景 | 配置 | suite | stability | 结论 |
|---|---|---:|---:|---|
| A | native RT-Thread | 10 样本，PASS | 10 秒，9999/9999，PASS | 基线 |
| B | AxVisor + RT-Thread only，RT-Thread 固定 pCPU 2 | 10 样本，PASS | 10 秒，9999/9999，PASS | 核心实时性对照 |
| C | AxVisor + 2-vCPU Linux + RT-Thread | 10 样本，PASS | 10 秒，9999/9999，功能 PASS，严格 1 ms 长尾 FAIL | 共存压力对照 |

C 场景的 Linux 启动确认：`configured=2 online=0-1 nproc=2`。Linux 使用两个 vCPU，允许在 AxVisor 的非 RT-Thread CPU 集合中调度；RT-Thread 保持单 vCPU、固定到 pCPU 2。

## 2. 指标范围

核心 RTOS 指标包括：

- `timer_jitter`，三次周期定时抖动；
- `callback_exec`，周期回调执行时间；
- `preemption`，任务抢占延迟；
- `irq`，中断响应延迟；
- `irq_to_task`，中断释放信号到高优先级任务运行的延迟；
- `irq_disabled_duration`，受控临界区关中断持续时间；
- `mutex_inversion`，互斥锁优先级反转路径延迟；
- `wake_under_load`，负载线程存在时的任务唤醒延迟；
- `net_event_latency`，virtio-net RX 中断到 RT-Thread 网络事件处理的延迟。

B 没有第二个客户机，无法执行跨客户机 UDP 网络探针，因此 B 使用 `benchmark_core`，仅跳过 `net_event_latency`。这不是丢测量数据：报告和 JSON 将该项标记为 `not_applicable_for_B`。A 的 native 网络指标和 C 的跨客户机网络指标仍然完整采集。

## 3. Quick suite 数据

所有 suite 指标均为 `expected=10 collected=10 missing=0`。代表性结果如下，单位为 ns：

| 指标 | A P50 / max | B P50 / max | C P50 / max |
|---|---:|---:|---:|
| timer_jitter | 1,408 / 41,632 | 3,632 / 16,224 | 6,368 / 85,808 |
| preemption | 1,712 / 8,240 | 4,112 / 12,768 | 4,512 / 12,096 |
| irq | 1,424 / 41,456 | 81,296 / 363,712 | 77,264 / 240,064 |
| irq_to_task | 2,480 / 18,640 | 81,808 / 276,976 | 78,400 / 262,048 |
| irq_disabled_duration | 240 / 16,736 | 368 / 19,872 | 240 / 19,824 |
| mutex_inversion | 6,336 / 18,976 | 7,296 / 22,928 | 656 / 40,880 |
| wake_under_load | 1,440 / 7,056 | 1,520 / 7,616 | 1,696 / 8,672 |
| net_event_latency | 25,136 / 60,816 | N/A | 212,752 / 379,120 |

网络中断诊断：C 为 `irq_dropped=0`、`probe_received=10`、`probe_acked=10`、`probe_no_irq=0`、`probe_duplicates=0`。这确认网络通信和即时中断路径在 quick 场景中均工作。

## 4. Stability 数据

10 秒稳定性任务周期为 1 ms，共期望 9999 个样本，A/B/C 均完整收集。

| 场景 | P50 | P95 | P99 | P99.9 | max | miss_100us | miss_500us | miss_1ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| A native | 656 ns | 3,776 ns | 16,944 ns | 42,480 ns | 76,240 ns | 0 | 0 | 0 |
| B AxVisor only | 3,264 ns | 12,608 ns | 20,384 ns | 141,824 ns | 234,720 ns | 20 | 0 | 0 |
| C AxVisor + Linux | 4,736 ns | 250,336 ns | 385,936 ns | 530,896 ns | 2,422,080 ns | 1,339 | 16 | 1 |

相对 A，B 的最大抖动约为 3.08 倍；C 相对 B 的最大抖动约为 10.32 倍，P95 约为 19.86 倍。C 的严格 `max <= 1 ms` 门限失败，但这不影响样本完整性、网络功能或 Task 2/3 功能门禁。

## 5. 通信和闭环验证

C 场景同时完成：

- Linux 2-vCPU SMP 启动：`online=0-1 nproc=2`；
- RT-IPC 三种 payload，各 30000 次请求，丢包 0、协议错误 0、超时 0；
- 注入一次断线，重连成功，恢复时间约 202 ms；
- Task 3 6 个控制请求全部成功，分类准确率 3/3，RT-Thread 最终状态 `errors=0 retries=0`；
- RT-Thread 网络探针 10/10 ACK。

## 6. 解释和限制

本轮是在 x86_64 宿主上使用 QEMU TCG 仿真 AArch64，不是物理 ARM 实时硬件。C 的毫秒级长尾主要可能来自 QEMU TCG vCPU/main-loop 获得宿主 CPU 的时机、虚拟 timer 到 VGIC/PPI 的投递，以及 NVMe/virtio-net 设备模拟和 Linux 共存负载。RT-Thread 固定 pCPU 2 只能隔离 AxVisor 内部 vCPU 竞争，不能隔离 QEMU 线程和宿主调度，因此当前结果不能作为硬实时 WCET 证明。

本轮是 quick smoke，仅用于确认测试链路和数据采集可运行；正式评估仍应执行 100000 样本 suite 和 300 秒 stability，并将其与本报告一起比较。

## 7. 复现命令

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
RTTHREAD_NATIVE_SRC="$PWD/tmp/rt-thread-5.2.2-native-current" \
RTTHREAD_AXVISOR_SRC="$PWD/tmp/rt-thread-5.2.2-axvisor-extended-current" \
ROOTFS_IMAGE="$PWD/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img" \
LINUX_KERNEL_IMAGE="$PWD/tmp/task3-alpine-linux-current/images/linux/Image" \
LINUX_INITRAMFS_IMAGE="$PWD/tmp/task3-alpine-linux-current/images/linux/rootfs.cpio.gz" \
os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --quick --output "$PWD/tmp/rtthread-realtime-current-quick-20260820-rerun"
```

原始证据归档于：`history-docs/task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-extended/quick-20260820/`。
