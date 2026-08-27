# RT-Thread 实时性 1000 样本同批次复测报告

日期：2026-08-20

本报告是新增实时性指标后的同批次快速复测，用于确认 native 基线、AxVisor-only 和
AxVisor + 2-vCPU Linux 的采集链路一致。它不是对已有 100000 样本正式报告的替代。

## 场景

| 场景 | 配置 | 网络指标 |
|---|---|---|
| A | native RT-Thread，QEMU virt，1 vCPU | native hostfwd UDP probe |
| B | AxVisor + RT-Thread，RT-Thread 固定 pCPU 2 | N/A：没有第二个客户机 |
| C | AxVisor + 2-vCPU Linux + RT-Thread，Linux pCPU 0/1/3，RT-Thread pCPU 2 | Linux UDP probe，经 virtio-net/IP/UDP 到 RT-Thread |

QEMU 版本为 11.0.2，使用 x86_64 宿主上的 AArch64 TCG 仿真。C 场景启动确认：
`LINUX_SMP_READY configured=2 online=0-1 nproc=2`。

## 数据完整性

所有适用指标均为 `expected=1000 collected=1000 missing=0`。C 场景网络探针为
`1000/1000`，`irq_dropped=0`、`probe_no_irq=0`，最终 `RTBENCH_END status=PASS`。
Task 2 和 Task 3 也通过了 C 场景功能门禁。

## 核心指标

单位为 ns，表中为 P99 / 最大值：

| 指标 | A native | B AxVisor-only | C AxVisor + Linux |
|---|---:|---:|---:|
| `timer_jitter` | 26,320 / 50,080 | 153,232 / 276,752 | 24,304 / 605,136 |
| `preemption` | 6,304 / 13,152 | 4,960 / 135,712 | 5,472 / 12,384 |
| `irq` | 11,008 / 55,600 | 81,840 / 270,144 | 82,752 / 246,144 |
| `irq_to_task` | 4,176 / 31,168 | 304,256 / 357,168 | 282,736 / 296,864 |
| `irq_disabled_duration` | 320 / 22,000 | 368 / 227,920 | 352 / 20,144 |
| `mutex_inversion` | 19,776 / 39,392 | 18,144 / 272,704 | 224,320 / 262,880 |
| `wake_under_load` | 2,976 / 9,152 | 3,072 / 250,432 | 4,976 / 1,652,368 |
| `net_event_latency` | 57,760 / 109,968 | N/A | 2,461,776 / 4,692,128 |

## 评估

AxVisor-only 的中断和 IRQ-to-task P99 分别约为 native 的 7.4 倍和 72.9 倍，说明
虚拟 GIC 注入和 vCPU 唤醒是固定开销来源。C 场景的 IRQ P99 与 B 接近，但
`wake_under_load` 出现 1.652 ms 最大值，网络事件 P99 达到 2.462 ms。故本轮 C 的
数据完整性和功能链路通过，严格 `max < 1 ms` 不通过，不能称为非常优秀的最坏情况实时性。

长尾主要受 QEMU TCG main loop、TCG vCPU 调度、虚拟 timer/VGIC 注入、virtio-net/NVMe
设备模拟和宿主调度影响。RT-Thread 固定到 pCPU 2 只能消除 AxVisor 内部 Linux vCPU
对该 pCPU 的直接竞争，不能隔离 QEMU 线程和宿主调度。

## 复现

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
RTTHREAD_NATIVE_SRC="$PWD/tmp/rt-thread-5.2.2-native-current" \
RTBENCH_MODE=suite RTBENCH_SUITE_SAMPLES=1000 \
NATIVE_GUEST_LOG="$PWD/tmp/rtthread-realtime-native-1000-20260820/console.log" \
NATIVE_QEMU_LOG="$PWD/tmp/rtthread-realtime-native-1000-20260820/qemu.log" \
os/axvisor/scripts/run_rtthread_native_baseline.sh

QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
ROOTFS_IMAGE="$PWD/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img" \
os/axvisor/scripts/run_rtthread_axvisor_only.sh \
  --image "$PWD/tmp/rtthread-realtime-run.7pUcwM/rt-thread/bsp/qemu-virt64-aarch64/rtthread.bin" \
  --suite-samples 1000 --core-suite \
  --output "$PWD/tmp/rtthread-realtime-axvisor-only-1000-20260820-rerun"
```

C 场景使用：

```bash
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
ROOTFS_IMAGE="$PWD/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img" \
RTTHREAD_IMAGE="$PWD/tmp/rtthread-realtime-run.7pUcwM/rt-thread/bsp/qemu-virt64-aarch64/rtthread.bin" \
LINUX_KERNEL_IMAGE="$PWD/tmp/task3-alpine-linux-current/images/linux/Image" \
LINUX_INITRAMFS_IMAGE="$PWD/tmp/task3-alpine-linux-current/images/linux/rootfs.cpio.gz" \
os/axvisor/scripts/run_task123.sh --app-guest linux --mode realtime-suite \
  --rtbench-samples 1000 --task2-count 1000 \
  --output "$PWD/tmp/rtthread-realtime-axvisor-linux-1000-20260820"
```

原始日志和汇总数据：

`history-docs/task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-rerun-1000/`
