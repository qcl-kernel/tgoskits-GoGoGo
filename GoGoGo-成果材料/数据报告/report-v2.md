# AxVisor 任务一、任务二、任务三实现与性能汇总（StarryOS 2-vCPU 版本）

> 汇总范围：`history-docs/task12` 与 `history-docs/task123`
>
> 汇总日期：2026-08-19
>
> 本版重点：记录 StarryOS 替代 Linux 后，与 RT-Thread 共同运行并完成长期压力测试的结果。

## 1. 版本结论

在原有 Linux 版本基础上，项目进一步完成了 StarryOS 2-vCPU 客户机接入 AxVisor，并
复用 RT-Thread 客户机、virtio-net 内部交换、RT-IPC v2 和 Task 3 AI 控制链路。StarryOS
版本不是独立的双 QEMU 演示，而是 AxVisor 内的正式客户机替换路径。

| 任务 | StarryOS 版本实现度 | 长期压力测试状态 | 结论 |
|---|---:|---|---|
| 任务一：实时性改造与验证 | **95%** | `PASS_WITH_QEMU_TIMER_LIMIT` | StarryOS 和 RT-Thread 均完成 3600 秒周期采样，但仍有 QEMU TCG timer 长尾，严格 `miss_1ms=0` 未通过 |
| 任务二：客户机间通信 | **100%** | **PASS** | Linux/StarryOS 与 RT-Thread 的三种 payload 均完成 240000/240000 请求 |
| 任务三：AI 模型与控制联动 | **100%** | **PASS** | Linux/StarryOS 均完成 AI 控制闭环、状态回传和功能门禁 |

这里的任务一 95% 表示实时功能和采集体系完整，但在当前测试平台上没有得到严格最坏
延迟保证。`PASS_WITH_QEMU_TIMER_LIMIT` 允许记录网络和功能通过，同时明确周期 timer
结果受到 QEMU TCG/宿主调度长尾限制。

主要长期压力报告：

- [StarryOS 与 Linux 长时间稳定性及性能对比报告](task123/report/2026-08-18/starryos-replace/docs/reports/starryos-linux-stability-comparison.md)
- [任务一/二/三集成测试报告](task123/report/2026-08-17/starryos-replace/docs/docs/build/axvisor/task123-test-report.md)
- [RT-Thread A/B/C 实时性隔离对照报告](task123/report/2026-08-19/tgoskits/rt-thread-realtime-isolation-report.md)
- [RT-Thread 实时性扩展指标报告（2026-08-20）](task123/report/2026-08-20/tgoskits/rt-thread-realtime-extended-report.md)
- [当前版本任务汇总](report.md)

## 2. StarryOS + RT-Thread 架构

### 2.1 客户机和 CPU 配置

| 对象 | 配置 |
|---|---|
| AxVisor/QEMU | QEMU 11.0.2，AArch64 `virt`，GICv3，Cortex-A72，4 个外层 vCPU |
| StarryOS | 2 vCPU，512 MiB，客户机 IP `192.168.77.11` |
| RT-Thread | 1 vCPU，256 MiB，客户机 IP `192.168.77.30` |
| RT-Thread 亲和性 | 静态固定到 AxVisor pCPU 2，独占实时 CPU 集合 |
| StarryOS 亲和性 | 可在 pCPU 0、1、3 中调度，不占用 RT-Thread pCPU 2 |
| StarryOS/RT-Thread 网络 | virtio-net + IPv4 + UDP + RT-IPC v2 |
| Task 2 | UDP 9876 |
| Task 3 | UDP 9877 |

StarryOS 保持与 Linux 版本相同的 2-vCPU、512 MiB、IP、MAC、RT-Thread 和应用负载边界，
因此可以进行相对可比的客户机替换测试。两次运行按 Linux 后 StarryOS 的固定顺序串行
执行；这组结果仍需通过交换顺序和多轮重复来形成更严格的统计结论。

### 2.2 数据和中断路径

```text
StarryOS 2-vCPU VM
  Task 2 client: UDP/9876
  Task 3 AI client: UDP/9877
             |
    AxVisor virtio-net + internal L2 switch
             |
RT-Thread 1-vCPU VM, pCPU 2
  Task 2 server + Task 3 controller
```

应用主数据通道只使用 virtio-net 上的 IP 协议栈。RT-IPC v2 负责版本、消息类型、长度、
序号、session ID、ACK、CRC、重传、重连和幂等。网络 ingress 由 AxVisor 发布状态并唤醒
目标 vCPU，virtqueue 处理后通过 VGIC 注入客户机中断；不使用共享内存、HyperCall、裸
MMIO 或 vsock 传递控制数据。

### 2.3 A/B/C 实时性隔离定位（2026-08-19）

在 Linux/StarryOS 共存数据之外，进一步增加三组 300 秒隔离实验：

- A：native RT-Thread，P99 10.912us，max 145.696us，miss_1ms=0；
- B：AxVisor + RT-Thread only，P99 18.048us，max 488.032us，miss_1ms=0；
- C：AxVisor + 2-vCPU Linux + RT-Thread，P99 396.848us，max 2.803ms，miss_1ms=2。

这说明 QEMU TCG 和 AxVisor 基础虚拟化都不是当前毫秒级长尾的主要来源；主要问题
集中在 Linux 共存时的外层 QEMU/宿主线程调度、virtio-net/NVMe 设备模拟以及网络
中断投递路径。详见 [RT-Thread A/B/C 实时性隔离对照报告](task123/report/2026-08-19/tgoskits/rt-thread-realtime-isolation-report.md)。

## 3. StarryOS 版本的实现功能

### 3.1 StarryOS 客户机替换

StarryOS 版本完成了以下接入内容：

1. 增加 AArch64 AxVisor guest 构建配置，启用 2 CPU 和 virtio-net。
2. 增加 StarryOS 专用 VM 配置，复用 Linux 的非实时 CPU 池和网络身份。
3. 使用显式的 `axvisor-guest` 构建特性和嵌入式 CPIO rootfs，不依赖 virtio-blk/NVMe
   作为该客户机的主根文件系统。
4. 提供 StarryOS 启动、SMP、网络探测、Task 2 和 Task 3 应用启动标记。
5. 复用 AxVisor RT-IPC v2、Linux ABI 应用、模型资源和 RT-Thread 控制服务。
6. 保持 RT-Thread 绑定 pCPU 2，StarryOS 两个 vCPU 在 `{0,1,3}` 中自由调度。

主要实现路径记录在设计和计划中：

- `os/StarryOS/configs/axvisor/task123-aarch64.toml`
- `os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml`
- `os/axvisor/guests/starryos-task123/`
- `os/axvisor/configs/board/qemu-aarch64-starryos-task123.toml`
- `os/axvisor/configs/qemu/qemu-aarch64-starryos-task123.toml`
- `os/axvisor/scripts/run_task123.sh`
- `os/axvisor/scripts/run_task123_guest_comparison.sh`

对应归档设计：

- [StarryOS Task 1/2/3 设计](task123/design/2026-08-18/starryos-replace/docs/superpowers/specs/2026-08-18-starryos-task123-design.md)
- [StarryOS 实施计划](task123/plan/2026-08-18/starryos-replace/docs/superpowers/plans/2026-08-18-starryos-task123-implementation.md)
- [Linux/StarryOS 稳定性对比设计](task123/design/2026-08-18/starryos-replace/docs/superpowers/specs/2026-08-18-starryos-linux-stability-comparison-design.md)

### 3.2 RT-Thread 实时服务保持不变

StarryOS 替换的是 Linux 客户机，RT-Thread 实时客户机仍承担：

- 1 ms 周期任务和 RTBench 采样；
- UDP/9876 RT-IPC 服务；
- UDP/9877 Task 3 控制服务；
- 虚拟 PWM/位置执行器更新；
- ACK、状态回传、幂等和故障恢复。

长期测试中发现 RTBench 汇总 worker 曾经优先级高于网络服务线程，在周期采样结束时执行
大规模 `qsort`，导致 StarryOS 1024 B 网络测试中断。修复方式是将 worker 调整为后台优先级
20，低于网络线程优先级 15，使排序不会阻塞网络服务。该修复由 RT-Thread patch invariant
测试验证。

## 4. 3600 秒长期压力测试

### 4.1 测试范围和通过条件

Linux 和 StarryOS 分别与同一个 RT-Thread 客户机配置串行运行，每轮持续 3600 秒，执行：

- Task 2：64 B、256 B、1024 B 三种 payload 的网络压力；
- Task 3：固定参数和 AI 控制闭环；
- RTBench：1 ms 周期任务和 callback 采样；
- 宿主资源：墙钟时间、QEMU CPU 时间、峰值 RSS、线程数和采样数；
- QEMU 原始退出码、运行终止原因和结果门禁。

长期测试命令：

```bash
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --full \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-cache-bench-priority.IQYicb" \
  --output "$PWD/tmp/task123-guest-comparison-full-bench-priority"
```

关键结果文件：

```text
comparison/comparison.json
comparison/comparison-report.md
linux/manifest.txt
linux/console.log
linux/summary.json
linux/host-metrics.txt
starryos/manifest.txt
starryos/console.log
starryos/summary.json
starryos/host-metrics.txt
```

### 4.2 功能和可靠性结果

两种客户机的长期测试均通过基础功能和可靠性检查：

- Task 2 三种 payload 均完成 `240000/240000`；
- 应用超时、协议错误、传输超时、重复包、乱序包和传输错误均为 0；
- Task 3 Linux 和 StarryOS 均完成 `6/6`，成功率 100%；
- 分类样本准确率均为 100%；
- RT-Thread 最终状态均为 `requests=9 errors=0 retries=0`；
- RTBench 两端均采集 `3599999/3599999` 周期样本，`missing=0`；
- StarryOS 在本轮 1024 B 全量测试中没有复现之前约第 55685 个请求处的断连。

因此，StarryOS + RT-Thread 的长期网络、AI 控制和服务存活能力已得到真实 QEMU 长测验证。

### 4.3 Task 2 网络结果

| payload | 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---:|---|---:|---:|---:|
| 64 B | RTT 平均 | 2 ms | 6 ms | +200.0% |
| 64 B | RTT P95/P99/P99.9 | 3/3/11 ms | 9/10/46 ms | +200.0%/+233.3%/+318.2% |
| 64 B | RTT 最大 | 62 ms | 55 ms | -11.3% |
| 64 B | 吞吐量 | 25.16 KiB/s | 8.82 KiB/s | -64.9% |
| 256 B | RTT 平均 | 2 ms | 6 ms | +200.0% |
| 256 B | RTT P95/P99/P99.9 | 3/4/15 ms | 9/10/46 ms | +200.0%/+150.0%/+206.7% |
| 256 B | RTT 最大 | 67 ms | 58 ms | -13.4% |
| 256 B | 吞吐量 | 99.30 KiB/s | 35.18 KiB/s | -64.6% |
| 1024 B | RTT 平均 | 2 ms | 6 ms | +200.0% |
| 1024 B | RTT P95/P99/P99.9 | 3/4/14 ms | 9/10/47 ms | +200.0%/+150.0%/+235.7% |
| 1024 B | RTT 最大 | 59 ms | 58 ms | -1.7% |
| 1024 B | 吞吐量 | 391.92 KiB/s | 139.31 KiB/s | -64.5% |

StarryOS 网络平均 RTT 约为 Linux 的 3 倍，有效吞吐量约为 Linux 的 35.5%。这说明
StarryOS 的 socket wait/wake、virtio-net 收发或客户机调度路径仍有性能差距，但没有造成
RT-Thread 服务饿死或长期压力测试失败。

### 4.4 Task 3 AI 控制结果

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 成功率 | 100% (6/6) | 100% (6/6) | 0% |
| 分类准确率 | 100% (3/3) | 100% (3/3) | 0% |
| 推理平均 | 487 us | 815 us | +67.4% |
| 推理最大 | 842 us | 1439 us | +70.9% |
| 控制往返平均 | 2568 us | 5652 us | +120.1% |
| 控制往返最大 | 2671 us | 6383 us | +139.0% |
| RTOS 处理平均 | 93 us | 195 us | +109.7% |

该长期对比中的 Task 3 为 3 个 fixed + 3 个 AI 帧，适合验证长期运行中的闭环存活和功能
正确性，不足以替代 600 + 600 帧的完整 AI 性能分布。完整 AI 统计见 [任务三集成报告](task123/report/2026-08-17/starryos-replace/docs/docs/build/axvisor/task123-test-report.md)。

### 4.5 RTBench 实时性结果

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| jitter P50 | 5728 ns | 9200 ns | +60.6% |
| jitter P95 | 287424 ns | 289856 ns | +0.8% |
| jitter P99 | 407104 ns | 399616 ns | -1.8% |
| jitter P99.9 | 451296 ns | 461408 ns | +2.2% |
| jitter 最大 | 7865072 ns | 5925424 ns | -24.7% |
| jitter 平均 | 57569 ns | 51568 ns | -10.4% |
| `miss_1ms` | 34 | 46 | +35.3% |
| callback P99 | 864 ns | 2480 ns | +187.0% |
| callback 最大 | 505344 ns | 364848 ns | -27.8% |
| missing | 0 | 0 | 0 |

两端完整采集 3,599,999 个周期样本，但 Linux 有 34 个、StarryOS 有 46 个超过 1 ms，
最大 jitter 分别为 7.865 ms 和 5.925 ms。因此该轮实时性门禁只能判为
`PASS_WITH_QEMU_TIMER_LIMIT`，不能判为严格 `PASS`，也不能据此宣称硬实时 WCET。

本轮测试运行在 x86_64 宿主上的 AArch64 QEMU TCG 仿真环境。周期 timer 的长尾主要受
QEMU TCG main-loop timer callback、TCG vCPU 线程获得宿主 CPU 的时机，以及 QEMU 虚拟
timer 到 VGIC/PPI 的投递链路影响；这些因素会在 guest 之外引入毫秒级延迟。RT-Thread
固定到 AxVisor pCPU 2 的静态分区仍然有效，但它只消除了 AxVisor 内部实时 vCPU 与 Linux
vCPU 的竞争，不能隔离 QEMU main loop 和宿主调度。因此这里的长尾不能直接归因于
StarryOS/RT-Thread 的任务调度或 guest ISR 执行时间。

值得注意的是，StarryOS 的 P99 比 Linux 低 1.8%，P99.9 仅高 2.2%，最大 jitter 反而低
24.7%；但 P50 和 callback P99 较高。这说明普通延迟分布接近，主要差距集中在客户机网络
和调度路径，而不是 RT-Thread 实时服务失效。

### 4.6 宿主资源结果

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 墙钟时间 | 3,627,371 ms | 5,140,047 ms | +41.7% |
| QEMU CPU 时间 | 7,103,300 ms | 10,123,050 ms | +42.5% |
| 峰值 RSS | 302,264 KiB | 292,644 KiB | -3.2% |
| 最大线程数 | 7 | 7 | 0% |
| 资源采样数 | 35,384 | 50,150 | +41.7% |

StarryOS 更高的墙钟时间和 CPU 时间主要对应其较慢的网络 RTT/吞吐路径；峰值 RSS 和线程
数量没有增加，说明长期运行中没有观察到明显的内存泄漏或线程膨胀证据。

## 5. 实现和修复路径

### 阶段一：从 Linux 兼容路径到 StarryOS guest

1. 保留已经通过任务一/二/三的 Linux 2-vCPU 默认路径。
2. 为 StarryOS 增加明确的 AxVisor guest build feature、2-vCPU VM 配置和嵌入式 CPIO rootfs。
3. 增加启动 marker，验证两个 StarryOS vCPU online、网络 ready、Task 2/Task 3 服务 ready。
4. 复用现有 AxVisor virtio-net 内部交换和 RT-IPC v2，不改变主通信约束。

### 阶段二：网络和 AI 应用迁移

1. StarryOS 侧复用 Linux ABI 的 Task 2/Task 3 客户端和模型资源。
2. Task 2 使用 UDP/9876；Task 3 使用 UDP/9877，两个服务生命周期分离。
3. 通过 RT-IPC v2 发送控制命令，RT-Thread 返回状态、PWM、执行器位置和处理时间。
4. 先运行 smoke、协议和故障测试，再进入长期压力测试。

### 阶段三：长期测试暴露并修复 RT-Thread 优先级问题

之前的长期测试在 1024 B 负载约第 55,685 个请求处断连，表现为一个协议错误和 273 ms
stall。分析排除了 QEMU 外部超时和 MAC 来源错误，定位到 RT-Thread benchmark worker
优先级高于网络服务线程：周期任务结束时进行两次大规模 `qsort`，阻塞了唯一 RTOS vCPU
上的网络处理。

修复为 `RTBENCH_WORKER_PRIORITY=20`，低于网络线程优先级 15。修复后重新执行完整对比，
StarryOS 在 1024 B 负载完成 `240000/240000`，且应用与传输错误均为 0。

### 阶段四：3600 秒 Linux/StarryOS/RT-Thread 联合压力测试

按 Linux 后 StarryOS 顺序，使用相同 RT-Thread、网络、模型和测试门禁执行 3600 秒运行，
并保存 `comparison.json`、双方 `manifest.txt`、`summary.json`、`console.log` 和
`host-metrics.txt`。该阶段同时确认了功能可靠性、RTOS 长期服务存活、客户机资源和 timer
长尾边界。

## 6. 复现入口

### 6.1 构建和故障镜像

```bash
bsp=tmp/starryos-task123/rt-thread-5.2.2-local/bsp/qemu-virt64-aarch64

uv run --with scons scons -C "$bsp" -c
TASK3_FAULT_DROP_STATUS_ONCE=1 \
  uv run --with scons scons -C "$bsp" -j"$(getconf _NPROCESSORS_ONLN)"
cp "$bsp/rtthread.bin" tmp/task123-cache-bench-priority.IQYicb/rtthread-drop-status.bin

uv run --with scons scons -C "$bsp" -c
TASK3_FAULT_DELAY_START_MS=3000 \
  uv run --with scons scons -C "$bsp" -j"$(getconf _NPROCESSORS_ONLN)"
cp "$bsp/rtthread.bin" tmp/task123-cache-bench-priority.IQYicb/rtthread-delayed-server.bin
```

### 6.2 3600 秒长期压力测试

```bash
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --full \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-cache-bench-priority.IQYicb" \
  --output "$PWD/tmp/task123-guest-comparison-full-bench-priority"
```

`--allow-qemu-timer-limit` 的含义是允许在 timer 长尾门禁未严格通过时继续发布网络和
功能结果；它不会把实时性失败伪装成成功。

## 7. 证据索引和限制

长期压力测试的关键证据：

- [长期对比报告](task123/report/2026-08-18/starryos-replace/docs/reports/starryos-linux-stability-comparison.md)
- [StarryOS 正常运行证据目录](task123/evidence/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/evidence/normal/summary.json)
- [StarryOS 故障运行证据目录](task123/evidence/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/evidence/faults/fault-summary.json)
- [任务三协议](task123/spec/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/protocol.md)
- [StarryOS/Linux 稳定性对比计划](task123/plan/2026-08-18/starryos-replace/docs/superpowers/plans/2026-08-18-starryos-linux-stability-comparison.md)

当前限制：

1. 测试平台是 x86_64 宿主上的 AArch64 QEMU TCG，不是物理 AArch64 或 KVM；当前观察到的
   timer 长尾主要是 QEMU TCG 仿真、main loop 和普通宿主调度的影响，不能作为硬实时 WCET。
   静态 CPU 分区无法消除这些宿主侧延迟。
2. Linux 与 StarryOS 按固定顺序各执行一轮；需要交换顺序并重复多轮，才能给出更稳定的
   统计置信区间。
3. StarryOS 的网络 RTT 约为 Linux 的 3 倍，吞吐约为 Linux 的 35.5%；后续应在 StarryOS
   socket wait/wake、virtio-net 收发和 AxVisor 转发边界增加时间戳并优化。
4. 长期 Task 3 对比仅有 3 个 fixed + 3 个 AI 帧，完整 AI 性能仍以 600 + 600 帧集成为准。
5. 任务三连续稳定时间在当前数据中没有有效样本，不能据此宣称收敛时间改善。

## 8. 最终判断

StarryOS + RT-Thread 的客户机替换和长期压力测试已经形成闭环：StarryOS 能以 2 vCPU
运行在 AxVisor 中，RT-Thread 保持独立实时 CPU，二者通过 virtio-net/IP/RT-IPC 通信，
并能在 3600 秒压力下完成大规模网络请求、AI 控制和周期采样。

当前最明确的性能结论是：功能可靠性和网络长期存活已通过；StarryOS 网络路径明显慢于
Linux；实时周期任务仍受 QEMU TCG timer 长尾限制。因而该版本适合作为任务一、二、三的
StarryOS 集成与长期稳定性证据，不应被表述为已经完成物理硬实时认证。

## 9. RT-Thread 扩展实时性 A/B/C Quick 复测（2026-08-20）

本轮在真实 QEMU 11.0.2/TCG AArch64 `virt` 上完成了新增 RTOS 指标的 quick 对照。新增指标包括 `preemption`、`irq_to_task`、`irq_disabled_duration`、`mutex_inversion`、`wake_under_load` 和 `net_event_latency`。A 为 native RT-Thread，B 为 AxVisor + RT-Thread only，C 为 AxVisor + 2-vCPU Linux + RT-Thread。

三组 suite 均完整收集，C 的 Linux 启动确认 `configured=2 online=0-1 nproc=2`。C 的跨客户机网络探针 `10/10` ACK，`irq_dropped=0`，Task 2 90000 次请求全部成功并完成一次断线重连，Task 3 AI 控制闭环 `6/6` 成功。

10 秒稳定性结果为：A 最大抖动 `76.240 us`，B `234.720 us`，C `2.422 ms`；C 有 1 个周期超过 1 ms，严格长尾门限仍失败。该长尾来自当前 x86_64 宿主上的 QEMU TCG、main-loop/宿主调度、虚拟 timer/VGIC 投递及设备模拟，静态绑定 RT-Thread 到 pCPU 2 不能消除这些宿主侧延迟。B 没有第二个 guest，网络事件指标按设计标记为不适用，不能将其误读为网络丢测量。

详细报告和原始数据：

- [RT-Thread 扩展实时性 Quick 报告](task123/report/2026-08-20/tgoskits/rt-thread-realtime-extended-quick-report.md)
- [RT-Thread 扩展实时性 Quick 证据](task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-extended/quick-20260820/)

## 10. RT-Thread 扩展实时性正式 Suite（2026-08-20）

在 Quick 复测后，使用真实 QEMU 11.0.2/TCG、最新 Alpine Linux 2-vCPU 镜像和最新
RT-Thread benchmark 重新完成 C 场景 `100000` 样本 suite。A native 和 B AxVisor-only
复用同批次正式数据，C 的 Linux 启动确认为 `configured=2 online=0-1 nproc=2`。

| 场景 | 实时 suite | 网络事件 | Task 2 | Task 3 |
|---|---|---|---|---|
| A native RT-Thread | `100000/100000` | `100000/100000` | 隔离 suite 未运行 Task 2 | 隔离 suite 未运行 Task 3 |
| B AxVisor + RT-Thread | `100000/100000` | 不适用：无 peer guest | 隔离 suite 未运行 Task 2 | 隔离 suite 未运行 Task 3 |
| C AxVisor + 2-vCPU Linux + RT-Thread | `100000/100000`，`RTBENCH_END=PASS` | `100000/100000`，`irq_dropped=0` | 3 种 payload 全部 `30000/30000` | `6/6`，分类 `3/3` |

C 的关键实时尾延迟为：timer jitter P99/max `385.888 us / 2.502 ms`，IRQ P99/max
`89.424 us / 297.632 us`，IRQ-to-task P99/max `286.944 us / 537.552 us`，mutex
inversion P99/max `19.504 us / 393.216 us`，wake-under-load P99/max
`2.992 us / 299.216 us`。C/B 的 P99 比值分别为：preemption `1.13x`、irq `0.77x`、
irq-to-task `1.02x`、mutex inversion `0.86x`、wake-under-load `1.01x`、timer jitter
`18.68x`。

这组数据说明 RT-Thread 的调度、互斥和唤醒路径在静态 CPU 分区下没有因 Linux 共存而
整体失控，但 timer jitter 的共存长尾仍明显。最大 `2.502 ms` 使严格毫秒级最坏延迟门禁
不通过；长尾来自当前 x86_64 宿主上的 QEMU TCG main loop、TCG vCPU/设备仿真、虚拟
timer/VGIC 投递和宿主调度，不能直接归因于 RT-Thread 内核调度。该结果也不能替代真实
AArch64/KVM 平台上的硬实时 WCET 测试。

详细报告和正式证据：

- [RT-Thread 扩展实时性正式报告](task123/report/2026-08-20/tgoskits/rt-thread-realtime-extended-report.md)
- [RT-Thread 扩展实时性正式证据](task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-extended/)

同批次 1000 样本复测、AxVisor-only 生命周期修复后的 B 组证据和三组比较结果见：

- [RT-Thread 1000 样本同批次复测报告](task123/report/2026-08-20/tgoskits/rt-thread-realtime-rerun-1000-report.md)
- [RT-Thread 1000 样本复测证据](task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-rerun-1000/)

## 11. RT-Thread 全指标基线复测（2026-08-20）

为补足 RTOS 实时性指标并与基线对比，使用真实 QEMU 11.0.2 TCG、相同 RT-Thread
benchmark 和 1000 个 suite 样本完成三组测试：A 为原生 RT-Thread，B 为 AxVisor +
RT-Thread only，C 为 AxVisor + 2-vCPU Linux + RT-Thread。所有 RTOS 指标均为
`expected=1000 collected=1000 missing=0`。

### 11.1 1000 样本结果

下表给出最坏值；分位数单位为微秒。C 场景确认 Linux 为
`LINUX_SMP_READY configured=2 online=0-1 nproc=2`，RT-Thread vCPU 固定在 pCPU 2，
Linux vCPU 使用 `{0,1,3}`。

| 指标 | A native max | B AxVisor-only max | C AxVisor+Linux max | C P50/P99 |
|---|---:|---:|---:|---:|
| timer jitter | 64.288 us | 458.784 us | 264.608 us | 5.408/120.800 us |
| callback execution | 32.608 us | 41.568 us | 129.632 us | 0.464/0.736 us |
| preemption | 31.024 us | 14.448 us | 1.057 ms | 4.656/7.440 us |
| IRQ response | 68.768 us | 268.416 us | 417.120 us | 78.672/297.616 us |
| IRQ-to-task | 31.104 us | 454.688 us | 1.646 ms | 82.976/1,023.488 us |
| IRQ-disabled duration | 24.720 us | 19.952 us | 1.730 ms | 0.240/0.416 us |
| mutex inversion | 54.176 us | 258.704 us | 293.744 us | 11.232/37.280 us |
| wake under load | 9.888 us | 217.136 us | 1.711 ms | 1.488/5.728 us |
| network event latency | 193.136 us | N/A | 10.337 ms | 1.540/2.927 ms |

网络事件在 B 中按设计为 N/A，因为 AxVisor-only 只有一个 guest，没有 Linux peer。C 的
网络探针 `probe_received=2998 probe_acked=2998 probe_no_irq=0 irq_dropped=0`；Task 2
1000 请求/每种 payload 全部成功，主动断线后恢复一次；Task 3 为 `6/6` 成功、分类
准确率 `3/3`、推理平均 `737 us`、控制往返平均 `4.054 ms`。

三组 suite 的严格尾部结论为：A `PASS`，B `PASS`，C `FAIL`。C 的失败不是样本缺失，
而是共存场景出现了 `preemption=1.057 ms`、`irq_to_task=1.646 ms`、
`wake_under_load=1.711 ms` 和网络事件最大 `10.337 ms`。这直接说明静态分区有效地
隔离了 RT-Thread 的运行核心，但没有消除 QEMU TCG 主循环、TCG vCPU 线程、设备模拟和
宿主调度造成的长尾。

### 11.2 180 秒稳定性结果

三组均完整采集 `179999/179999` 个 1 ms 周期样本，结果如下：

| 指标 | A native | B AxVisor-only | C AxVisor+Linux |
|---|---:|---:|---:|
| stability jitter P50 | 0.576 us | 3.504 us | 2.976 us |
| stability jitter P95 | 4.784 us | 11.952 us | 18.128 us |
| stability jitter P99 | 11.616 us | 21.216 us | 201.840 us |
| stability jitter P99.9 | 37.456 us | 151.008 us | 382.128 us |
| stability jitter max | 264.064 us | 297.632 us | 628.928 us |
| stability `miss_1ms` | 0 | 0 | 0 |
| callback max | 34.272 us | 149.776 us | 163.136 us |

180 秒窗口内三组均没有超过 1 ms 的周期样本。C 的 P99 相比 A 约为 `17.38x`，最大值
约为 `2.38x`；相比 B，C 的 P99 约为 `9.51x`，最大值约为 `2.11x`。因此静态分区在
本窗口内保持了毫秒级稳定性，但不能据此证明物理平台上的硬实时 WCET。

### 11.3 宿主资源和复现位置

C 组 180 秒运行的宿主采样为：墙钟 `184896 ms`、QEMU CPU 时间 `356000 ms`、峰值
RSS `1307504 KiB`、最大线程数 `7`、资源采样 `1804`。QEMU 进程 CPU 时间约为墙钟的
`1.93x`，反映了多 vCPU TCG 仿真和设备线程开销；不能把该值解释为 guest CPU 利用率。

复现命令（使用本地 source cache，不重新下载 RT-Thread/rootfs）：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
TASK2_COUNT=1000 \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
RTTHREAD_NATIVE_SRC="$PWD/tmp/rt-thread-5.2.2-native-current" \
RTTHREAD_IMAGE="$PWD/tmp/rtthread-net-fixed-entry.bin" \
ROOTFS_IMAGE="$PWD/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img" \
os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --suite-samples 1000 --skip-stability \
  --output "$PWD/tmp/rtthread-realtime-comparison-1000-20260820-rerun"

TASK2_COUNT=1000 \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
RTTHREAD_NATIVE_SRC="$PWD/tmp/rt-thread-5.2.2-native-current" \
RTTHREAD_IMAGE="$PWD/tmp/rtthread-net-fixed-entry.bin" \
ROOTFS_IMAGE="$PWD/tmp/source-cache/rootfs/qemu-aarch64/rootfs.img" \
os/axvisor/scripts/run_rtthread_realtime_baseline.sh \
  --stability-seconds 180 --skip-suite \
  --output "$PWD/tmp/rtthread-realtime-stability-180-20260820"
```

关键结果文件：

- `tmp/rtthread-realtime-comparison-1000-20260820-rerun/realtime-suite.md`
- `tmp/rtthread-realtime-comparison-1000-20260820-rerun/realtime-suite.json`
- `tmp/rtthread-realtime-stability-180-20260820/realtime-stability.md`
- `tmp/rtthread-realtime-stability-180-20260820/realtime-stability.json`

### 11.4 采集器修复记录

真实串口日志中 AxVisor 主机日志可能插入 RTBENCH 行、数字字段甚至结束标记中间。已在
`os/axvisor/scripts/verify_task123_results.sh` 和
`os/axvisor/scripts/summarize_rtthread_realtime.py` 中加入相同的规范化规则：剥离带
`ESC[37m[` 前缀的 AxVisor 主机日志及其日志换行，重新拼接 guest 字节，再按字段名重建
RTBENCH 记录。结果门禁仍严格要求 `expected=collected`、`missing=0`，没有通过忽略指标
来放宽验收。新增回归夹具覆盖了 RT-IPC 日志插入、字段数字内部插入和结束标记拆分。

这次修复解释了此前出现的“irq benchmark missing or incomplete”：原始数据实际完整，
失败来自串口并发输出造成的解析误报。修复后 1000 样本 C suite 的所有指标均能被门禁和
汇总器识别。稳定性 wrapper 仍记录了一次 `TASK3_RTOS_FINAL` 提取门禁误判，但原始
`console.log` 中该标记存在，且稳定性 RTBENCH 数据完整；该集成日志提取问题不影响本节
RTOS 实时性结论，后续应单独修复 runner 的 attached-console 提取路径。

### 11.5 评估

按 RTOS 实时性而不是 Linux 负载能力评估：A/B 的周期、抢占、中断、锁和唤醒指标保持在
微秒到亚毫秒范围；C 在 1000 样本短 suite 中出现毫秒级长尾，在 180 秒稳定性窗口内
仍保持 `miss_1ms=0`。因此当前 AxVisor + RT-Thread 实时性是“功能完整、短时稳定、尾部
受 TCG 仿真影响”，不是“非常优秀的硬实时结果”。下一步优化重点应是使用真实 AArch64
硬件或 KVM 重测，并继续缩短虚拟 timer/VGIC、vCPU 唤醒、virtio-net 事件和 AxVisor
后台任务的临界路径；不能仅通过静态 CPU 绑定宣称已经消除最坏情况延迟。

## 12. vCPU 线程亲和性优化复测（2026-08-20）

在上一轮全 QEMU 进程固定 CPU 的基础上，新增 QEMU vCPU 线程级绑定：QEMU 外层线程使用
宿主 CPU `2-5`，QEMU guest vCPU 线程映射为 `0=3,1=4,2=2,3=5`。真实 QEMU 短测和
1000 样本 B 组均通过，B 组四个线程分别报告 `QEMU vCPU affinity applied`，9 项 RTOS
指标全部完整。A/B/C 对照使用同一 RT-Thread benchmark；C 为 2-vCPU Linux 共存场景。

### 12.1 1000 样本数据

单位为 ns，重复指标按最大尾延迟轮次保留；C 的 `net_event_latency` 是 Linux 经
virtio-net/IP/UDP 到 RT-Thread 的网络事件延迟，B 因无 peer 为 N/A。

| 指标 | A native P99/max | B AxVisor-only P99/max | C AxVisor+Linux P99/max |
|---|---:|---:|---:|
| timer_jitter | 24,704 / 55,808 | 11,904 / 155,008 | 202,704 / 510,704 |
| callback_exec | 2,784 / 38,480 | 608 / 41,264 | 976 / 44,592 |
| preemption | 6,064 / 16,016 | 5,216 / 16,432 | 6,640 / 49,296 |
| irq | 10,800 / 55,744 | 82,416 / 397,248 | 82,368 / 472,528 |
| irq_to_task | 4,272 / 31,168 | 295,008 / 319,296 | 288,320 / 606,336 |
| irq_disabled_duration | 304 / 21,824 | 320 / 19,952 | 368 / 21,904 |
| mutex_inversion | 16,592 / 47,728 | 22,752 / 253,600 | 22,368 / 261,408 |
| wake_under_load | 1,968 / 10,560 | 4,032 / 215,632 | 6,352 / 1,608,896 |
| net_event_latency | 108,048 / 122,592 | N/A | 2,414,560 / 3,980,448 |

数据完整性为 A/B/C 全部 `1000/1000`、`missing=0`。C 的严格最大值门禁仍不通过，主要
原因是 `wake_under_load` 达到 `1.609 ms`，网络事件达到 `3.980 ms`；这不是样本丢失或
RT-Thread 崩溃。与上一轮全进程 affinity 组相比，vCPU 线程绑定使普通调度和 timer
分位数保持在微秒到数百微秒范围，但没有消除共存场景的设备/定时器长尾。

### 12.2 本轮发现并修复的运行器问题

1. AxVisor-only runner 原先在 FIFO 阻塞打开阶段把后台 shell PID 当成 QEMU PID，导致
   vCPU 线程绑定失败、控制台为空。现在先 `exec 3<> "$fifo"`，再以 `<&3` 启动真实
   QEMU，已用真实 QEMU 复现通过。
2. vCPU 线程创建可能晚于 QEMU 主进程启动，控制脚本将发现窗口从固定 200 ms 改为默认
   30 s，并支持 `QEMU_VCPU_AFFINITY_WAIT_S`。
3. RTBENCH 串口输出可能被 RT-IPC ANSI 日志、换行和 NUL 交错。汇总器现在清除这些
   有界插入并恢复 `mutex_inversion`，避免将完整数据误报为缺失；新增契约测试覆盖该
   原始损坏形式。

原始证据、比较 JSON/CSV/Markdown 和校验和见：

- [vCPU 线程亲和性 1000 样本证据](task123/evidence/2026-08-20/tgoskits/rt-thread-realtime-vcpu-pinned-1000/)

复现 B 组的关键环境变量：

```bash
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
QEMU_CPU_AFFINITY=2-5 \
QEMU_VCPU_AFFINITY=0=3,1=4,2=2,3=5 \
QEMU_VCPU_AFFINITY_WAIT_S=30
```

本轮结论保持不变：静态分区和 vCPU 线程亲和性能够降低直接 CPU 竞争，但在 x86_64
宿主上的 AArch64 QEMU TCG 中，虚拟 timer、VGIC/vCPU 唤醒、virtio-net/NVMe 模拟和
宿主调度仍会制造毫秒级长尾。当前结果可称为“功能完整、可重复、短时稳定”，不能称为
严格硬实时或非常优秀的最坏情况性能；最终判断仍需 KVM 或真实 AArch64 硬件复测。

## 13. virtio-net 兼容性修复与完整链路复测（2026-08-20）

### 13.1 问题与修复

完整 Linux + RT-Thread 场景此前出现 RT-Thread 无网卡、Linux TX 超时或通信链路未建立。
复核 RT-Thread QEMU BSP 后确认，其 virtio-mmio 网卡驱动要求 vendor ID 为 `0x554d4551`
（QEMU 的 virtio-mmio 设备标识）；AxVisor 的通用 virtio-net 传输原先返回
`0x1af4`，导致 RT-Thread 在设备匹配阶段跳过网卡初始化。该问题不是 DMA 轮询或共享内存
通信问题。

修复内容：

- 在 `virtualization/axvirtio-net/src/device.rs` 增加 `new_with_vendor_id()`，保留原有
  `new()` 的默认 vendor ID `0x1af4`，避免改变其他设备的既有 ABI。
- 在 `os/axvisor/src/virtio_net.rs` 为 RT-Thread 使用 `0x554d4551`，并固定其 virtio-mmio
  资源到 guest MMIO `0x0a00_0000`、GIC 输入 `48`，与 RT-Thread QEMU BSP 的设备布局一致。
- 增加构造函数、设备身份和资源要求回归测试。

### 13.2 修复后功能验证

真实 QEMU 为 `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64` 11.0.2，Linux
客户机为 2 vCPU，RT-Thread 为 1 vCPU 并固定到宿主 CPU 2；QEMU vCPU 线程映射为
`0=3,1=4,2=2,3=5`。修复后的 native、AxVisor-only、完整 Linux + RT-Thread 三组场景
均为 `PASS`，每个实时性指标采集 `1000/1000`，`missing=0`。

完整链路证据：

- RT-Thread 发布 `RTIPC_SERVER_READY ip=192.168.77.30 port=9876`。
- Task 2 的三种 payload 均为 `sent=10 recv=10 loss=0%`，强制断连后重连成功。
- Task 3 为 `requests=6 successes=6`，分类准确率 `3/3`，`RTBENCH_END status=PASS`。
- 三组场景状态文件均为 `PASS`，无 `no_network_device` 或持续 `NotReady`。

### 13.3 修复后实时性数据（1000 样本）

单位为 ns；B 组没有 Linux 对端，因此 `net_event_latency` 不适用。

| 指标 | A native P99 / max | B AxVisor + RT-Thread P99 / max | C AxVisor + 2-vCPU Linux + RT-Thread P99 / max |
|---|---:|---:|---:|
| timer_jitter | 57,552 / 1,051,600 | 34,432 / 165,200 | 85,936 / 673,440 |
| callback_exec | 224 / 35,024 | 640 / 47,200 | 1,904 / 41,856 |
| preemption | 3,568 / 15,616 | 6,144 / 17,616 | 5,728 / 11,632 |
| irq | 4,384 / 56,256 | 83,376 / 265,472 | 80,960 / 260,784 |
| irq_to_task | 3,536 / 29,440 | 304,160 / 384,352 | 287,200 / 509,168 |
| irq_disabled_duration | 304 / 23,216 | 320 / 252,512 | 384 / 219,136 |
| mutex_inversion | 14,688 / 45,504 | 16,528 / 248,448 | 220,368 / 263,056 |
| wake_under_load | 1,824 / 9,552 | 2,864 / 220,608 | 2,416 / 206,832 |
| net_event_latency | 52,752 / 99,792 | N/A | 1,227,760 / 6,788,768 |

### 13.4 结论与复现

vendor ID 修复已经解决了 RT-Thread 网卡识别和 Linux/RT-Thread IP 链路问题；本次完整
场景不是仅启动成功，而是完成了双向 RT-IPC、断连恢复和 AI 控制闭环。C 组网络延迟仍有
毫秒级长尾，原因主要是 x86_64 宿主上 AArch64 QEMU TCG 对多 vCPU、虚拟 timer、VGIC
唤醒和 virtio-net 的仿真开销，不能据此判定 AxVisor 在真实硬件上的硬实时上限。

原始证据、CSV/JSON/Markdown 汇总及校验和：

`history-docs/task123/evidence/2026-08-20/tgoskits/rtthread-realtime-vendor-fix-1000/`

核心回归命令：

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
cargo test -p axvirtio-net
os/axvisor/scripts/test_rtbench_net_probe.sh
os/axvisor/scripts/test_rtbench_net_irq_capture.sh
os/axvisor/scripts/test_qemu_realtime_controls.sh
```

### 13.5 修复后 180 秒稳定性复测

为排除短时 1000 样本测试的偶然性，使用当前持久 source cache 构建出的 RT-Thread 镜像
进行了完整 Linux + RT-Thread 的 180 秒稳定性窗口。镜像为
`tmp/rt-thread-5.2.2-native-current/bsp/qemu-virt64-aarch64/rtthread.bin`，其 SHA-256
为 `5e7ba27894f2b602bae3245e3b1e97f0696f2dcc7df9b35a3ae194f889584937`，BSP vendor ID 为
`0x554d4551`。

结果为：`expected=179999 collected=179999 missing=0`，周期抖动
`p50=3.376 us`、`p95=21.120 us`、`p99=215.536 us`、`p99.9=391.776 us`、最大
`905.168 us`，`miss_1ms=0`；回调执行 `p99=0.880 us`、最大 `167.232 us`、
`miss_1ms=0`。同一窗口内 Task 2 三种 payload 均为 `1000/1000` 且断连恢复成功，Task 3
为 `6/6`，最终结果门禁为 `PASS`。

复测过程中曾误用旧的 `tmp/rtthread-net-fixed-entry.bin`，该镜像编译时间为 21:02，
BSP vendor ID 仍为 `0x1AF4`，因此重现了 `RTIPC_FAILURE reason=no_network_device` 和
`virtio-net ... NotReady`。这不是修复代码的回退，而是外部传入过期 RT-Thread 镜像导致
的输入不一致；使用当前 source cache 镜像后网络和稳定性均通过。后续复现必须使用当前
构建输出或不传 `RTTHREAD_IMAGE` 让脚本选择默认路径。

180 秒原始证据：

`history-docs/task123/evidence/2026-08-20/tgoskits/rtthread-realtime-vendor-fix-1000/stability-180-post-vendor/`

### 13.6 镜像一致性保护回归（2026-08-20）

为避免旧 RT-Thread 镜像再次进入 QEMU 后才出现 `no_network_device`，新增了
`os/axvisor/scripts/rtthread_image_metadata.py` 旁车元数据契约。元数据记录镜像 SHA-256、
大小、RT-Thread 源 commit、AxVisor patch-set 摘要、virtio vendor ID 和 IRQ。AxVisor-only
runner 默认在构建 AxVisor/QEMU 前校验；Task123 runner 在
`RTTHREAD_REQUIRE_IMAGE_METADATA=1` 严格模式下校验。默认 fixture 测试保持兼容，不会被
强制要求旁车文件。

本次真实 QEMU 11.0.2/TCG 短测使用正确镜像：

- 元数据校验：`PASS`，vendor ID `0x554d4551`，IRQ `48`；
- RT-Thread suite：`10/10`，`RTBENCH_END status=PASS`；
- timer jitter 最大值 `20.432 us`，IRQ 最大值 `504.880 us`，无样本缺失；
- 旧 `tmp/rtthread-net-fixed-entry.bin` 在 QEMU 启动前被拒绝，未执行 AxVisor 构建，原因是
  缺少对应元数据，避免再次产生运行期 `no_network_device`。

随后使用同一镜像执行了严格模式的 Linux 2-vCPU + RT-Thread smoke：Task 2 三种 payload
均为 `2/2`，断连恢复成功；Task 3 为 `6/6`、分类 `3/3`；RT-Thread 最终状态为
`requests=9 errors=0`，结果门禁 `PASS`。该轮还确认 Linux 侧 `SMP=2`、RT-Thread
vCPU 仍固定在 pCPU 2。

证据目录：

`history-docs/task123/evidence/2026-08-20/tgoskits/rtthread-image-metadata-quick/`

严格模式 smoke 证据：

`history-docs/task123/evidence/2026-08-20/tgoskits/rtthread-image-metadata-smoke/`

相关回归包括元数据正/负测试、RT-Thread runner 契约测试、Task123 生命周期测试和真实
QEMU 短测。该保护解决的是镜像输入一致性问题，不改变 QEMU TCG 造成的实时性长尾；已有
180 秒稳定性数据仍以第 13.5 节为准。

## 14. RT-Thread 全指标 100000 样本与 300 秒稳定性复测（2026-08-21）

本轮使用真实 QEMU 11.0.2/TCG 完成 A/B/C 三组 RT-Thread 实时性对照。A 为 native
RT-Thread，B 为 AxVisor + RT-Thread only，C 为 AxVisor + 2-vCPU Linux + RT-Thread；
RT-Thread 固定在 pCPU 2，Linux vCPU 使用 `{0,1,3}`。所有核心指标均为
`100000/100000`、`missing=0`。另有三组 300 秒稳定性采样，均为 `299999/299999`，
`miss_1ms=0`。

| 场景 | suite 数据 | suite 严格尾部 | 稳定性 300 秒 | 稳定性 jitter P99 / max |
|---|---|---|---|---:|
| A native RT-Thread | 完整 | PASS | PASS | 10.608 / 176.432 us |
| B AxVisor + RT-Thread | 完整 | PASS | PASS | 23.056 / 421.280 us |
| C AxVisor + 2-vCPU Linux + RT-Thread | 完整 | FAIL：mutex 1.036 ms、网络 1.787 ms | PASS | 422.208 / 827.280 us |

C 场景同时完成 Linux 2-vCPU 启动、RT-IPC 64B/256B/1024B 各 `30000/30000`、断连恢复、
Task 3 `6/6` 控制请求和分类 `3/3`。该轮没有网络丢包或协议错误，QEMU 退出码为 0。

这组数据说明静态分区对直接 CPU 竞争有效，但不能消除 x86_64 宿主上的 QEMU TCG 主
循环、TCG vCPU/设备线程、虚拟 timer/VGIC 投递、virtio-net/NVMe 模拟和宿主调度长尾。
因此当前结果适合证明功能、数据完整性和相对性能，不足以宣称物理硬实时 WCET；最终结论
仍需在 KVM 或真实 AArch64 硬件上复测。

详细报告与证据：

- [RT-Thread 全指标扩展复测报告（2026-08-21）](task123/report/2026-08-21/tgoskits/rt-thread-realtime-extended-20260821-report.md)
- [RT-Thread 全指标扩展复测证据（2026-08-21）](task123/evidence/2026-08-21/tgoskits/rt-thread-realtime-extended/)
