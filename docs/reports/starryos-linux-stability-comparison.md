# StarryOS 与 Linux 长时间稳定性及性能对比报告

## 1. 结论

本轮在同一套 AxVisor、QEMU、RT-Thread、协议、模型和宿主环境中，分别启动 2-vCPU
Linux 和 2-vCPU StarryOS，与固定在独立物理 CPU 集合上的 1-vCPU RT-Thread 进行
3600 秒稳定性测试。两端均正常退出，QEMU 原始退出码为 0，结果目录由分析器完整发布。

功能和可靠性结果通过：

- Task2 三种载荷（64/256/1024 B）均完成 `240000/240000` 请求；应用超时、协议错误、
  重传、传输超时、重复包、乱序包和传输错误均为 0。
- Task3 Linux/StarryOS 均 `6/6` 成功，成功率 100%，分类样本准确率 100%，RT-Thread
  最终状态均为 `requests=9 errors=0 retries=0`。
- RTBench 两端均采集 `3599999/3599999` 周期样本，`missing=0`。
- StarryOS 在本轮 1024 B 全量测试中没有复现上轮约 55685 次请求处的断连。

结果门禁为 `PASS_WITH_QEMU_TIMER_LIMIT`，而不是严格 `PASS`。RTBench 的 1 ms 周期
超限为 Linux 34 次、StarryOS 46 次；最大 jitter 分别为 7.865 ms 和 5.925 ms。
这是 x86_64 宿主上 AArch64 QEMU TCG 的 timer/调度长尾证据，不是物理 AArch64 平台
上的硬实时证明。若要求严格 `miss_1ms=0`，本轮应判为未通过。

相对 Linux，StarryOS 的网络 RTT 平均值约高 200%，有效应用吞吐量低约 64.5%；但
RTBench jitter 的 P99 低 1.84%、P99.9 高 2.24%，最大 jitter 低 24.66%。这说明
StarryOS 的主要瓶颈仍在客户机网络/调度路径，不是本轮 RT-Thread 网络线程被饿死。

## 2. 测试对象和拓扑

- Worktree：`/home/yfblock/Code/hyper-rtos/starryos-replace`
- 分支：`feat/starryos-task123`
- AxVisor：AArch64，QEMU `virt`，GICv3，`cortex-a72`
- QEMU：`qemu-system-aarch64`，4 个 vCPU，8 GiB 内存
- Linux：2 vCPU，512 MiB，客户机地址 `192.168.77.11`
- StarryOS：2 vCPU，512 MiB，客户机地址 `192.168.77.11`
- RT-Thread：1 vCPU，256 MiB，固定在物理 CPU 2，地址 `192.168.77.30`
- Linux/StarryOS vCPU：可在物理 CPU 0、1、3 中调度
- virtio-net：应用客户机 MAC `52:54:00:77:00:01`，RT-Thread MAC
  `52:54:00:77:00:03`，通过 QEMU hub `77` 互通
- Task2：TCP/IP，端口 `9876`
- Task3：UDP/IP，端口 `9877`
- 主数据通道：virtio-net 上的 IP 协议栈；不使用共享内存、HyperCall 或 vsock

因此 Linux 和 StarryOS 使用相同的 2-vCPU、内存、设备、MAC/IP、RT-Thread 和负载
配置；两次运行按 Linux 后 StarryOS 的固定顺序串行执行。

## 3. 代码迭代和根因修复

### 3.1 上轮失败

上轮目录为：

```text
tmp/task123-guest-comparison-full-txrx-fix/
```

当时 RT-Thread benchmark worker 使用优先级 10，RT-IPC/Task3 网络线程使用优先级
15。RT-Thread 中数值越小优先级越高。3600 秒周期采样结束后，worker 在唯一 RTOS
vCPU 上执行两次大规模 `qsort`，阻塞了网络线程。StarryOS 在 1024 B 载荷约
`55685/240000` 时失败，最后统计为：

```text
sent=55685 recv=55684 loss=0%
request_timeouts=0 protocol_errors=1 reconnects=0
transport: retrans=5 timeouts=1 dup=0 reorder=0 errors=0
stall=273ms
```

这不是 QEMU 外部超时，也不是 `SourceMacViolation`；根因是 benchmark 汇总任务的
优先级高于网络服务线程。

### 3.2 本轮修复

在 `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c` 中增加：

```c
#define RTBENCH_WORKER_PRIORITY 20U
```

并将 `rt_thread_create("rtbench", ...)` 的优先级改为该常量。优先级 20 低于网络
线程的 15，因此大规模排序变为后台任务，不会抢占网络服务线程。补丁回归脚本同时
检查该常量存在并确实被 `rtbench_start_job()` 使用。

回归命令：

```bash
os/axvisor/patches/rtthread/test-rtthread-patches.sh \
  tmp/starryos-task123/rt-thread-5.2.2-local
```

结果：`PASS: RT-Thread patch and benchmark invariants`。

## 4. 可复现实验命令

RT-Thread 源码位于 `tmp/starryos-task123/rt-thread-5.2.2-local`，构建使用 uv 提供
的 SCons。正常镜像、故障注入镜像和共享缓存已经准备好；重建故障镜像的命令为：

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

正式对比的一条命令：

```bash
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --full \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-cache-bench-priority.IQYicb" \
  --output "$PWD/tmp/task123-guest-comparison-full-bench-priority"
```

本轮结果目录：

```text
tmp/task123-guest-comparison-full-bench-priority/
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

## 5. 3600 秒结果

### 5.1 Task2 网络

| 载荷 | 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---:|---|---:|---:|---:|
| 64 B | RTT avg | 2 ms | 6 ms | +200.0% |
| 64 B | RTT P95/P99/P99.9 | 3/3/11 ms | 9/10/46 ms | +200.0%/+233.3%/+318.2% |
| 64 B | RTT max | 62 ms | 55 ms | -11.3% |
| 64 B | 吞吐量 | 25.16 KiB/s | 8.82 KiB/s | -64.9% |
| 256 B | RTT avg | 2 ms | 6 ms | +200.0% |
| 256 B | RTT P95/P99/P99.9 | 3/4/15 ms | 9/10/46 ms | +200.0%/+150.0%/+206.7% |
| 256 B | RTT max | 67 ms | 58 ms | -13.4% |
| 256 B | 吞吐量 | 99.30 KiB/s | 35.18 KiB/s | -64.6% |
| 1024 B | RTT avg | 2 ms | 6 ms | +200.0% |
| 1024 B | RTT P95/P99/P99.9 | 3/4/14 ms | 9/10/47 ms | +200.0%/+150.0%/+235.7% |
| 1024 B | RTT max | 59 ms | 58 ms | -1.7% |
| 1024 B | 吞吐量 | 391.92 KiB/s | 139.31 KiB/s | -64.5% |

三种载荷两端的发送和接收均为 `240000/240000`。所有应用层和传输层错误为 0；
64 B 的一次 reconnect 是测试客户端建立首个连接时的正常记录，两端一致。

### 5.2 Task3 AI 控制闭环

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 成功率 | 100% (6/6) | 100% (6/6) | 0% |
| 分类准确率 | 100% (3/3) | 100% (3/3) | 0% |
| 推理 mean | 487 us | 815 us | +67.4% |
| 推理 max | 842 us | 1439 us | +70.9% |
| 控制往返 mean | 2568 us | 5652 us | +120.1% |
| 控制往返 max | 2671 us | 6383 us | +139.0% |
| RTOS 处理 mean | 93 us | 195 us | +109.7% |

Task3 仍是 3 个 fixed + 3 个 AI 帧，主要用于闭环功能和稳定性验证；不能把 6 个
样本当作完整的 AI 性能分布。

### 5.3 RTBench

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| stability jitter P50 | 5728 ns | 9200 ns | +60.6% |
| stability jitter P95 | 287424 ns | 289856 ns | +0.8% |
| stability jitter P99 | 407104 ns | 399616 ns | -1.8% |
| stability jitter P99.9 | 451296 ns | 461408 ns | +2.2% |
| stability jitter max | 7865072 ns | 5925424 ns | -24.7% |
| jitter mean | 57569 ns | 51568 ns | -10.4% |
| jitter miss_1ms | 34 | 46 | +35.3% |
| callback P99 | 864 ns | 2480 ns | +187.0% |
| callback max | 505344 ns | 364848 ns | -27.8% |
| missing | 0 | 0 | 0 |

两端的 `expected` 和 `collected` 均为 `3599999`。StarryOS 的主体 jitter P95/P99 与
Linux 接近，但 P50 和 callback P99 较高；这表明客户机调度/网络路径对普通延迟分布
有影响，不能只看最大值判断实时性。两端均有 1 ms 超限，严格周期截止期门禁未通过。

### 5.4 宿主资源

| 指标 | Linux | StarryOS | StarryOS 相对 Linux |
|---|---:|---:|---:|
| 墙钟时间 | 3627371 ms | 5140047 ms | +41.7% |
| QEMU CPU 时间 | 7103300 ms | 10123050 ms | +42.5% |
| 峰值 RSS | 302264 KiB | 292644 KiB | -3.2% |
| 最大线程数 | 7 | 7 | 0% |
| 资源采样数 | 35384 | 50150 | +41.7% |

StarryOS 的较高墙钟和 CPU 时间主要来自其网络 RTT/吞吐路径较慢，不代表 RT-Thread
本身占用更多内存或创建更多线程。

## 6. 镜像和证据摘要

本轮共享缓存：

```text
tmp/task123-cache-bench-priority.IQYicb/
```

关键 RT-Thread 镜像 SHA-256：

```text
rtthread-normal.bin       f7bf4fbb5b067c0c73853af45a7fc9e038929b4e20a09ab3a616ceb174161403
rtthread-drop-status.bin   857c934501f6f3ab0ee9a3162b14a061e322a3b2382cac9b20765eab496d80d2
rtthread-delayed-server.bin 25ed8a1a00790ab480dd7ac2eb5f9168dda90df632704fafb7e98b84ceee0bd3
```

完整 artifact、VM 配置、QEMU 退出码和统计数据见两端 `manifest.txt` 及：

```text
tmp/task123-guest-comparison-full-bench-priority/comparison/comparison.json
```

## 7. 限制和后续优化

1. 当前平台是 x86_64 宿主上的 AArch64 QEMU TCG；必须在物理 AArch64 或 KVM 环境中
   重新验证严格 `miss_1ms=0` 和最坏情况响应时间。
2. 本轮只执行一组 Linux→StarryOS 顺序；若要发表统计结论，应交换顺序并重复多轮，
   报告置信区间。
3. StarryOS Task2 平均 RTT 约为 Linux 的 3 倍，吞吐量约为 35.5%；下一轮优化应在
   StarryOS 的 socket wait/wake、virtio-net 收发和 AxVisor 转发边界加入时间戳。
4. RTBench worker 已降低为后台优先级，长测网络稳定性得到验证；仍需单独评估 qsort
   汇总的 CPU 抢占影响以及更细的调度/中断路径延迟。
5. Task3 只使用 6 个端到端样本；如需量化 AI 控制效果，应追加至少 600 帧并报告
   控制误差、稳定时间和端到端延迟分布。
