# AxVisor + RT-Thread 实时性与网络通信测试报告

> 更新日期：2026-08-17
>
> 集成分支：`feat/axvisor-task123`
>
> 受测 runtime 提交：`7e25b6ceeb8a1613705b90d47969482479a10dda`
>
> 平台：Ubuntu 24.04，QEMU 11.0.2 TCG，AArch64 `virt`，
> 4 个外层 vCPU

测试完成后的提交只修改三份报告、文档契约和三行导入历史日志的行尾空格，
没有修改 AxVisor、RT-Thread、Linux workload、协议、模型、配置或 runner
运行逻辑。因此运行证据绑定到受测 runtime commit，而报告所在 HEAD 可以更晚。
`git diff --name-only 7e25b6cee..HEAD` 可审计该边界。

## 1. 结论

AxVisor 已完成 RT-Thread 专用核、busy WFI 快速路径、绝对定时器期限、
VM-scoped TLBI、即时虚拟中断投递和低干扰证据采集。1000 样本综合测试中，
周期抖动、抢占和 SGI 中断响应均为 `miss_1ms=0`。但是四轮 300 秒测试都出现
了 1 ms 以上离群值，所以当前实现不宣称硬实时，也不能证明 1 ms WCET。

任务一当前完成度为 95%：功能、指标、基线和长时采样均已完成，剩余差距是
普通 Ubuntu + QEMU TCG 环境下严格长稳门禁未通过。原始失败数据保留，没有
通过重复运行挑选单一 PASS 结果。

## 2. CPU、内存与中断拓扑

| 对象 | vCPU | AxVisor pCPU 集合 | 内存 | 空闲策略 |
|---|---:|---|---|---|
| Linux VM[1] | 2 | 两个 vCPU 均可在 pCPU 0/1/3 调度，mask `0b1011` | 512 MiB，`0x80000000..0x9fffffff` | periodic/halt |
| RT-Thread VM[3] | 1 | 固定 pCPU 2，mask `0b0100` | 256 MiB，`0xa0000000..0xafffffff` | busy WFI |

Linux 没有实时性要求，因此不固定到单一物理核，只排除 RTOS 使用的 pCPU 2。
RT-Thread 的 `phys_cpu_ids=[2]` 和 `phys_cpu_sets=[0b0100]` 形成静态亲和性；
Linux 的 `phys_cpu_ids=[0,1]` 仅是初始放置，`phys_cpu_sets=[0b1011,0b1011]`
允许两个 Linux vCPU 在三个非实时核之间调度。

Linux 与 RT-Thread 各使用一块 AxVisor virtio-net，帧经过内部 L2 switch。
设备有数据时由 AxVisor 发布 ingress 状态、唤醒目标 vCPU，并通过 VGIC SPI
注入客户机 ISR。这是网络事件驱动路径，不是 VirtIO RX 轮询，也不是共享内存、
HyperCall、raw MMIO 或 vsock 数据通道。

## 3. 实时性改造

1. trapped busy WFI 在 AArch64 异常入口快速返回，避免完整 world switch 和
   `yield_now()`。
2. RT-Thread generic timer 使用绝对 `CNTV_CVAL` deadline，并补偿跨过周期。
3. 周期测试使用 hard timer；抢占和 SGI 中断路径分别独立测量。
4. Linux TLBI 使用 VM-scoped CPU mask，不广播到 RT-Thread pCPU 2。
5. RTOS timer 虚拟优先级高于网络 SPI；网络中断由 VGIC 即时注入。
6. 删除 RT-IPC 与 Task 3 的周期调试 UART telemetry，保留 READY、ERROR、FINAL。
7. QEMU 子进程在 exec 前写 `/proc/self/timerslack_ns=1`；写失败时 runner
   失败闭合。该设置只是宿主调度控制变量，不是实时优先级。

## 4. 1000 样本综合测试

证据目录：`tmp/task123-results/realtime-suite-r5-final`。该轮
`result_gate=PASS`、`raw_qemu_exit=0`、`termination_reason=marker-complete`。
这是提交前一轮综合证据；后续提交只加强证据排空、失败 marker 和 UART 干扰控制。

| 指标 | P50/P95/max | P99/P99.9 | >1 ms |
|---|---:|---:|---:|
| timer run 1 | 5.456/36.592/464.912 us | 68.208/463.520 us | 0 |
| timer run 2 | 5.872/34.288/301.456 us | 50.912/246.448 us | 0 |
| timer run 3 | 6.240/42.832/349.664 us | 249.200/327.920 us | 0 |
| preemption | 4.448/5.120/698.016 us | 7.296/670.288 us | 0 |
| IRQ/SGI | 76.800/86.784/270.000 us | 172.368/266.704 us | 0 |

全部项目都是 `expected=1000 collected=1000 missing=0`，且
`miss_1ms=0`。IRQ 从写 GIC redistributor pending 开始，到 RT-Thread ISR
读取 architectural counter 结束，包含 VGIC 注入和 guest ISR 入口。

该轮并发 Task 2 网络 RTT：

| 载荷 | avg/P95/max |
|---|---:|
| 64 B | 3/8/61 ms |
| 256 B | 3/7/57 ms |
| 1024 B | 2/3/11 ms |

每种载荷均为 `1000/1000`。当前 HEAD 的 Task 3 normal 轮也同时运行 Task 2，
得到：

| 载荷 | avg/P95/max |
|---|---:|
| 64 B | 3/4/30 ms |
| 256 B | 1/3/11 ms |
| 1024 B | 2/3/31 ms |

三种载荷仍均为 `1000/1000`，64 B 阶段在第 500 个请求强制断连后一次重连成功，
恢复耗时 221 ms，请求超时和协议错误均为 0。

### 4.1 CPU 负载分布

同类 300 秒并发轮的宿主采样去掉启动点后，Linux vCPU0 对应 TCG 线程平均
99.28%，Linux vCPU1 为 0.54%，RT-Thread pCPU2 对应 TCG 线程为 99.56%，
保留 pCPU3 为 0.00%。这说明当前 initramfs 网络应用主要在 Linux vCPU0 上运行，
但 `LINUX_SMP_READY configured=2 online=0-1 nproc=2` 和内核启动日志证明两个
Linux vCPU 都已上线。RT-Thread 的 TCG 线程在测试窗口持续繁忙，符合 busy WFI
设计；这些百分比是宿主线程 CPU 时间，不等于真实 ARM 核利用率。

### 4.2 同 QEMU 历史对比

与集成前同 QEMU/Cortex-A72 的 1000 样本历史轮比较：

| 指标 | 历史 P50/P95/P99 | 当前 P50/P95/P99 | 说明 |
|---|---:|---:|---|
| timer run 1 | 21.024/83.248/98.240 us | 5.456/36.592/68.208 us | 中高分位改善 |
| preemption | 5.056/5.472/6.080 us | 4.448/5.120/7.296 us | P50/P95 改善，单轮 P99 +20% |
| IRQ/SGI | 77.552/86.192/180.640 us | 76.800/86.784/172.368 us | 基本持平至改善 |

preemption P99 的单轮增幅没有被描述为可重复回归，但当前 max=698.016 us
明显高于历史轮，必须与 300 秒失败一并保留。由于缺少第二个当前 suite 对照轮，
这里不做“无退化”结论，Task 1 仍保持 95%。

### 4.3 原生 RT-Thread 基线

相同 QEMU `virt`/GICv3/Cortex-A72 上直接启动 1-vCPU RT-Thread 5.2.2，
运行相同 1 ms hard-timer 300 秒：

| 指标 | 原生 RT-Thread |
|---|---:|
| P50 | 8.432 us |
| P95 | 16.640 us |
| P99 | 27.456 us |
| P99.9 | 57.728 us |
| max | 692.672 us |
| >1 ms | 0 |

基线命令是
`RTBENCH_STABILITY_SECONDS=300 os/axvisor/scripts/run_rtthread_native_baseline.sh`。
它用于估算二级地址转换、VM exit/entry、VGIC 和额外 TCG 线程的开销，不等同
于真实 ARM 裸机。

### 4.4 关键镜像及 SHA-256

| 文件 | SHA-256 |
|---|---|
| `realtime-suite-r5-final/manifest.txt` | `ee54a3d3da08eeb5a0c07cad991644eb0899facc8bfe8d0c7b9969f42a125179` |
| `realtime-suite-r5-final/summary.json` | `9523aead29759787e7bed3241ba7f4fef7421c43b15583853bf92bf39b073241` |
| `realtime-suite-r5-final/frames.csv` | 由 manifest 与目录原始数据共同保存 |
| `realtime-suite-r5-final/console.log` | 包含完整 marker 和实时样本 |
| QEMU | `5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9` |
| AxVisor binary | `d6109d6ad3ec99a8fc14089b0e152b21fa6dea1395c7440e067be8f4e950d635` |
| Linux Image | `431b99c2512e8f8010de41000ba648fc9eb8d289c5fb5e5dc59ea8dd788998d3` |
| Linux initramfs | `ba3059d4f8e9ba3d1b01fcdb9cb03f1cc7c22dd3cb94de4e725540768fea4296` |
| RT-Thread normal image | `e5ddbbd147ee3ee786d18efa7e31f0bdca1ff337304cfc3063bf80b24a5ab7b2` |
| model weights | `2cb5da281d088bd7650659db74914aa35642e9e0fc93489c6d7479d369315ca2` |
| RT-IPC source/header | `38a65d69608a5907e64fe4ba43df2faa5af173d3aa90f1300923fcebc77a2e03` / `e22da1b00dc144fb0c3ad5771bbcf4d9d8068f94d304fd4c70c0cb2dd75c1b60` |

## 5. 300 秒稳定性

门禁要求 `expected=299999 collected=299999 missing=0`，并且
`miss_1ms=0`。四轮都完整采集 299999 个周期样本，同时 Task 2 完成
`90000/90000` 请求，但严格实时门禁均为 FAIL：

| 原始证据 | P50/P95/P99/P99.9 | max | >1 ms | 状态 |
|---|---:|---:|---:|---|
| `stability-300s/console.log` | 20.800/324.944/419.264/466.256 us | 3.636208 ms | `miss_1ms=14` | FAIL |
| `stability-300s-r2-timerslack1/console.log` | 24.848/294.304/400.080/462.144 us | 2.722352 ms | `miss_1ms=4` | FAIL |
| `stability-300s-r3-timerslack1/console.log` | 21.104/332.320/414.816/462.832 us | 5.406368 ms | `miss_1ms=29` | FAIL |
| `stability-300s-r4-low-host-load/console.log` | 20.816/343.568/423.440/450.224 us | 2.353616 ms | `miss_1ms=2` | FAIL |

短时 A/B 控制变量：

| 控制 | max | >1 ms |
|---|---:|---:|
| timer slack 1 ns | 811.904 us | 0 |
| timer slack 50000 ns | 1.698896 ms | 1 |

1 ns timer slack 改善了部分短时最坏值，但不能保证 300 秒
`miss_1ms=0`。它因此保留为降低宿主合并定时器延迟的措施，而不是硬实时证明。

## 6. 根因与限制

QEMU 边界探针把剩余长尾主要定位在 QEMU timer assert 前，以及虚拟 PPI assert
之后的 TCG 调度等待。PPI 已进入 CPU2 异常路径后，到 guest 读取 IAR 的时间仍是
微秒级，因此继续修改 AxVisor VGIC 优先级没有证据支持。已确认的 AxVisor
Busy-WFI 长路径已经修复。

当前用户的 `ulimit -r=0`、`ulimit -e=0`，不能使用宿主实时调度策略。
固定 QEMU main-loop/TCG 线程的宿主 affinity 反而退化到更多 1 ms 离群值，所以
没有采用。普通 Ubuntu + QEMU TCG 不能建立硬 1 ms WCET；最终硬实时验收应在
PREEMPT_RT、隔离物理 CPU 和硬件/KVM 条件下复验。

## 7. 复现命令

统一 runner：

```bash
env \
LINUX_KERNEL_IMAGE="$PWD/tmp/task123-linux-build-v3/images/linux/Image" \
LINUX_INITRAMFS_IMAGE="$PWD/tmp/task123-linux-build-v3/images/linux/rootfs.cpio" \
ROOTFS_IMAGE=/path/to/rootfs.img \
RTTHREAD_REPOSITORY=/path/to/rt-thread-5.2.2 \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
os/axvisor/scripts/run_task123.sh \
  --mode realtime-suite --rtbench-samples 1000 --task2-count 1000 \
  --output tmp/task123-results/realtime-suite

# 严格长稳门禁可能按本文所述返回非零；失败原始数据仍应保留。
env LINUX_KERNEL_IMAGE=... LINUX_INITRAMFS_IMAGE=... ROOTFS_IMAGE=... \
RTTHREAD_REPOSITORY=... QEMU=... \
os/axvisor/scripts/run_task123.sh \
  --mode stability --seconds 300 --task2-count 30000 \
  --output tmp/task123-results/stability-300s
```

完整环境、构建步骤、故障诊断和哈希复核见
`task123-reproduction-cn.md`。

## 8. 本地不可变证据归档

按计划，运行日志、CSV、JSON、二进制和 manifest 保留在 `tmp`，不提交 Git。
共享工作区中的交付归档为：

```text
tmp/task123-results/task123-evidence-7e25b6cee.tar.gz
SHA-256 5e2f220eeb7e22bbd540172c77d9818a606f9d0228e81ae8025acc792c5a62ba
```

归档包含 runtime commit 元数据、realtime suite、四轮 300 秒长稳、Task 3
normal 和五个 fault profile，共 99 个条目。使用
`gzip -t`、`tar -tzf` 和 `sha256sum` 可独立校验。
