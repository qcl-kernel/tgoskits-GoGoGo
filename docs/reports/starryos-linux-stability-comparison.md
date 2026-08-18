# StarryOS 与 Linux 长时间稳定性及性能对比报告

## 1. 结论

本次验证在同一套 AxVisor、QEMU、RT-Thread、网络协议、模型和宿主资源约束下，
分别使用 2 vCPU Linux 与 2 vCPU StarryOS 作为应用客户机。300 秒快速回归已完成：
两端 Task2、Task3 和 RTBench 样本完整，应用超时、协议错误、重复包和乱序包均为 0，
Task3 成功率均为 100%。

快速回归中，StarryOS 的 Task2 平均 RTT 约为 6 ms，Linux 约为 2 ms；StarryOS
有效吞吐量低约 62%。Task3 控制往返平均时延由 Linux 的 3401 us 增加到 5785 us，
增加约 70.1%。RT-Thread 周期任务 jitter P99 在 StarryOS 负载下为 379840 ns，
比 Linux 负载下的 404944 ns 低约 6.2%；callback execution P99 则高约 22.9%。

两次 300 秒运行均出现 8 个大于 1 ms 的周期 jitter 样本，因此严格硬实时门禁未通过，
结果状态为 `PASS_WITH_QEMU_TIMER_LIMIT`。这表示功能、样本完整性和除 1 ms 周期截止期
外的稳定性门禁通过，不表示当前 x86_64 宿主上的 AArch64 QEMU TCG 达到物理硬实时要求。

3600 秒正式对比正在同一 worktree 中运行。本报告在其最终门禁完成后补充正式数据，
当前不得把 300 秒结果当作 3600 秒稳定性结论。

## 2. 测试对象

- Git 分支：`feat/starryos-task123`
- 快速回归代码提交：`44d5dd0de`
- 虚拟机监控器：AxVisor，AArch64
- 模拟器：`qemu-system-aarch64`，`cortex-a72`，QEMU `virt`，GICv3
- QEMU 配置：4 CPU、8 GiB 内存、两个 virtio-net hub 端点
- 应用客户机：Linux 或 StarryOS，2 vCPU、512 MiB
- 实时客户机：RT-Thread，1 vCPU、256 MiB
- 传输：virtio-net 上的 TCP/UDP/IP；不使用共享内存、HyperCall 或 vsock 作为主通道
- 网络：应用客户机 `192.168.77.11`，RT-Thread `192.168.77.30`
- Task2 端口：TCP `9876`
- Task3 端口：UDP `9877`

## 3. CPU、内存和设备拓扑

| 对象 | vCPU | 物理 CPU 约束 | 内存 | 网络设备 |
|---|---:|---|---:|---|
| Linux/StarryOS | 2 | 初始放置在 CPU 0/1；两个 vCPU 的可运行集合均为 CPU 0/1/3 | 512 MiB | virtio-net，MAC `52:54:00:77:00:01` |
| RT-Thread | 1 | 固定在 CPU 2，idle policy 为 `busy` | 256 MiB | virtio-net，MAC `52:54:00:77:00:03` |
| QEMU/AxVisor | 4 host CPU | QEMU 启动参数 `-smp 4` | 8 GiB | hub `77` |

应用客户机允许在非 RTOS CPU 集合中调度，RT-Thread 则使用静态 CPU 亲和性隔离。
Linux 和 StarryOS 使用相同的 vCPU 数量、物理 CPU 集合、网络 MAC、IP 和负载参数。
比较顺序固定为 Linux 后 StarryOS；宿主热状态和 TCG 翻译缓存状态可能造成顺序偏差。

## 4. 测量方法和门禁

### 4.1 Task2 网络

每个客户机依次发送 64、256、1024 字节请求。协议记录发送和接收数量、RTT 的
min/avg/P50/P95/P99/P99.9/max、有效吞吐量、应用超时、协议错误、连接恢复、传输重传、
重复包、乱序包和传输错误。每种载荷必须完整收回全部请求。

### 4.2 Task3 AI 控制闭环

应用客户机执行模型推理，通过 UDP/IP 把控制结果发送给 RT-Thread；RT-Thread 执行控制
并回传状态。报告记录推理时延、请求往返时延、RTOS 处理时延、成功率和错误计数。
稳定性对比使用相同模型、协议源码和 `task3.frames=3`，用于验证闭环持续可用，不用 3 帧
样本推断长期 AI 精度分布。

### 4.3 RTBench

RT-Thread 在网络负载并发期间运行 1 ms 周期基准，记录 `stability_jitter` 和
`callback_exec` 的 P50/P95/P99/P99.9/max、均值、缺失样本以及 100 us、500 us、1 ms
超限次数。严格门禁要求样本完整且 `miss_1ms=0`。

### 4.4 两级结果状态

- `PASS`：全部功能门禁和严格 `miss_1ms=0` 门禁通过。
- `PASS_WITH_QEMU_TIMER_LIMIT`：仅显式启用诊断模式时允许周期 jitter 存在 1 ms 超限；
  panic、assert、fatal、请求缺失、应用失败、QEMU 非零退出仍然失败。
- `FAIL`：任何必需标记、请求、样本或功能门禁缺失，或运行异常退出。

## 5. 300 秒快速回归结果

原始结果目录：

```text
tmp/task123-guest-comparison-quick-diagnostic-final.6DVqWU/
```

有效输入为该目录中的 `linux/` 和 `starryos-current/`。目录中的旧 `starryos/` 使用过期
镜像，缺少正常退出认证标记，已被结果门禁拒绝，不参与本报告。

### 5.1 Task2 网络结果

| 载荷 | 客户机 | 完成请求 | RTT avg | RTT P95 | RTT P99 | RTT P99.9 | RTT max | 有效吞吐量 |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 64 B | Linux | 30000/30000 | 2 ms | 3 ms | 5 ms | 12 ms | 43 ms | 24.36 KiB/s |
| 64 B | StarryOS | 30000/30000 | 6 ms | 8 ms | 10 ms | 43 ms | 58 ms | 9.22 KiB/s |
| 256 B | Linux | 30000/30000 | 2 ms | 3 ms | 4 ms | 12 ms | 83 ms | 96.69 KiB/s |
| 256 B | StarryOS | 30000/30000 | 6 ms | 8 ms | 10 ms | 45 ms | 1635 ms | 36.73 KiB/s |
| 1024 B | Linux | 30000/30000 | 2 ms | 3 ms | 4 ms | 14 ms | 63 ms | 385.04 KiB/s |
| 1024 B | StarryOS | 30000/30000 | 6 ms | 8 ms | 10 ms | 44 ms | 68 ms | 146.53 KiB/s |

三种载荷的应用超时、协议错误、重复包、乱序包和传输错误均为 0。两端在首个载荷均有
一次预期连接建立/恢复记录。StarryOS 256 B 测试出现 3 次传输重传，但最终请求完整，
没有上升为应用超时。256 B 的 1635 ms 最大值是长尾异常点；P99.9 为 45 ms，不能用
平均值掩盖该最坏样本。

### 5.2 Task3 结果

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 成功率 | 100% | 100% | 0% |
| 推理时延 mean | 492 us | 831 us | +68.90% |
| 推理时延 P99 | 898 us | 1077 us | +19.93% |
| 控制往返 mean | 3401 us | 5785 us | +70.10% |
| 控制往返 P99 | 8532 us | 6506 us | -23.75% |
| RTOS 处理 mean | 130 us | 123 us | -5.38% |

Task3 每端只有 6 次事务，P99 实际等于有限样本中的最大值，主要作为功能闭环和异常恢复
验证。性能趋势应结合 Task2 大样本和后续更大 Task3 样本运行判断。

### 5.3 RTBench 结果

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| jitter P50 | 22608 ns | 9056 ns | -59.94% |
| jitter P95 | 328992 ns | 277136 ns | -15.76% |
| jitter P99 | 404944 ns | 379840 ns | -6.20% |
| jitter P99.9 | 445456 ns | 445328 ns | -0.03% |
| jitter max | 5539344 ns | 5551824 ns | +0.23% |
| jitter miss_1ms | 8 | 8 | 0% |
| callback P99 | 2448 ns | 3008 ns | +22.88% |
| callback max | 203408 ns | 164432 ns | -19.16% |

两端均采集 `299999/299999` 个周期样本，没有 missing。主体分布低于 1 ms，但最大 jitter
约 5.5 ms，说明普通 Ubuntu 宿主加 QEMU TCG 的调度和 timer path 仍产生毫秒级长尾。
因此不能把本结果作为 AxVisor 在物理 AArch64 平台上的 WCET 或硬实时证明。

### 5.4 宿主资源

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 墙钟时间 | 305020 ms | 622397 ms | +104.05% |
| CPU 时间 | 596720 ms | 1224820 ms | +105.26% |
| 峰值 RSS | 244072 KiB | 239372 KiB | -1.93% |
| 最大线程数 | 7 | 7 | 0% |

StarryOS 的网络请求 RTT 较高，使固定请求数的运行时间和 QEMU CPU 时间约为 Linux 的
两倍；内存占用和线程数没有相应增加。

## 6. 3600 秒正式运行

运行目录：

```text
tmp/task123-guest-comparison-full-diagnostic.C0ceB3/
```

运行参数为每种 Task2 载荷 240000 次、RTBench 3600 秒、Task3 3 帧。Linux 已完成并通过
诊断门禁；StarryOS 正在执行。本节将在 `comparison/comparison.json` 和
`comparison/comparison-report.md` 通过分析器原子发布后替换为正式对比数据。

## 7. 复现命令

在仓库根目录运行：

```bash
# 300 秒快速回归
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --quick \
  --allow-qemu-timer-limit \
  --output "$PWD/tmp/task123-guest-comparison-quick"

# 3600 秒正式对比
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --full \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-comparison-cache" \
  --output "$PWD/tmp/task123-guest-comparison-full"
```

需要验证严格实时门禁时去掉 `--allow-qemu-timer-limit`。输出目录必须为空，缓存目录必须
和输出目录分离。运行完成后至少保留：

```text
comparison/comparison.json
comparison/comparison-report.md
linux/manifest.txt
linux/console.log
linux/linux.log
linux/rtthread.log
linux/summary.json
linux/host-metrics.txt
starryos/manifest.txt
starryos/console.log
starryos/starryos.log
starryos/rtthread.log
starryos/summary.json
starryos/host-metrics.txt
```

## 8. 限制和后续优化方向

1. 当前结果来自 x86_64 宿主上的 AArch64 QEMU TCG，宿主调度、TCG 翻译、timerfd 和
   线程唤醒共同影响最大延迟；需在物理 AArch64 或 KVM 环境重复严格门禁。
2. Linux 固定在 StarryOS 之前运行，未执行 ABBA 顺序和多轮置信区间测试；平均差异可用于
   定位工程瓶颈，但不能等同于统计显著性。
3. StarryOS 的 Task2 RTT 和吞吐量明显落后，而 RT-Thread jitter 主体分布没有同步恶化，
   瓶颈更可能位于 StarryOS 用户态网络/调度路径，而非 RT-Thread 控制回调。
4. 应对 256 B 极端长尾增加用户态调度、socket wait/wake、virtio-net TX/RX 和 AxVisor
   转发分段时间戳，再决定优化位置。
5. Task3 稳定性模式只运行少量功能帧；若要评价 AI 闭环性能分布，应追加至少 600 帧的
   独立 Task3 对比，并报告置信区间和异常恢复样本。
