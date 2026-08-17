# AxVisor + RT-Thread 实时性与客户机通信测试报告

> 最后更新：2026-08-16
> 分支：`rtthread-migration`
> 仓库基线提交：`8e80a17bcbce8fc35020317da2ae53469f349d51`
> cleanup suite/300 s/repeat 运行时 `HEAD`：`5e63f33e203266032ad00a390274409676c7e234`
> 当前报告审计 `HEAD`：`f5c61c734a926931949274f73e82a09151967741`
> 运行时源码身份：运行时 `HEAD` 叠加本文 cleanup allowlist 的未提交改动，不等同于当前共享工作树的全部改动
> RTOS：RT-Thread 5.2.2，固定源码提交 `ddf52e2cdd977f14fc04035c88672ac204aec713`
> Hypervisor：AxVisor release，`qemu-aarch64-two-guest-net`
> 测试平台：QEMU 11.0.2 TCG，AArch64 Cortex-A72，4 vCPU，8 GiB

## 1. 结论与完成度

| 任务 | 实现完成度 | 当前验收状态 | 当前结论 |
|------|-----------:|--------------|----------|
| 任务一：实时性改造与验证 | **100%** | **性能门禁不稳定** | 2-vCPU Linux、RT-Thread 核隔离、基线、suite、300 秒长稳、CPU 负载和复现流程均已完成；Busy-WFI 快速路径最新严格长测因 2 个 `>1 ms` 样本 FAIL |
| 任务二：客户机间通信 | **100%** | **PASS** | virtio-net/IP/UDP/RT-IPC 双向链路、可靠性机制、90,000 请求长测及丢包/重复/乱序/重连注入均通过，FIN 关闭交错缺陷已修复并复验 |
| 任务三：AI 模型与控制联动 | **0%** | **未开始** | 不在本轮任务一、任务二实施范围内 |

完成度表示要求的功能、测试和证据是否齐备，不等于每轮性能门禁的通过率，也不表示
QEMU TCG 已获得硬实时认证。当前优化后有一轮 300 秒严格门禁达到 `miss_1ms=0`、
最大偏差 `997.808 us`；Busy-WFI 快速路径最新 300 秒轮采集完整但仍有 2 次超过 1 ms，
最大值为 `1.193376 ms`。固定宿主 QEMU 线程的反例有 14 次超过 1 ms，说明普通宿主上
“绑核”不等于 CPU 隔离或实时调度。因此：

- AxVisor/RT-Thread 的确定性已明显改善，功能验收完成；
- 普通 Ubuntu 宿主上的 QEMU TCG 结果不是可证明的硬实时最坏界；
- 最终硬实时指标仍应在独占物理 CPU 的硬件/KVM 和实时宿主上复验。

## 2. 系统架构

### 2.1 CPU 与调度

| 对象 | vCPU | AxVisor pCPU 集合 | 策略 |
|------|-----:|-------------------|------|
| Linux VM[1] | 2 | vCPU0、vCPU1 均为 `{0,1}` | 两个 Linux vCPU 可在 pCPU0/1 集合内抢占和迁移，不固定一一绑定 |
| RT-Thread VM[3] | 1 | `{2}` | 静态固定到 pCPU2，`host_vcpu_idle_policy=busy` |
| 余量 | - | pCPU3 | 不分配给客户机实时 vCPU |

Linux 没有实时性要求，因此只限制在非实时 CPU 集合 `{0,1}`，不固定到某一个核心。
RT-Thread 独占 pCPU2，避免 Linux vCPU 在 AxVisor 调度层与实时 vCPU 竞争。
在本测试的嵌套 QEMU 环境中，AxVisor pCPU 对应 QEMU TCG vCPU 线程，不等同于宿主
x86 物理核心绑定。

2026-08-16 的 fresh 双 VM 复验同时记录了 AxVisor 收到 Linux 的
`PSCI_CPU_ON target=0x1`、`VM[1] VCpu[1] running`，Linux 内核输出
`CPU1: Booted secondary processor` 和 `smp: Brought up 1 node, 2 CPUs`，用户态输出
`LINUX_SMP_READY configured=2 online=0-1 nproc=2`。因此 2-vCPU 不仅由 TOML 配置证明，
也由 hypervisor、Linux 内核和 Linux 用户态三个层次的同轮运行证据证明。

### 2.2 内存、设备和启动参数

| 项目 | Linux VM[1] | RT-Thread VM[3] |
|------|-------------|-----------------|
| 内存 | `0x80000000 + 512 MiB` | `0xa0000000 + 256 MiB` |
| 内核入口 | `0x80200000` | `0xa0000000` |
| DTB | `0x8f000000` | `0xaf000000` |
| 网络设备 | AxVisor 虚拟 virtio-net，MAC `34:54:00:4d:00:01` | AxVisor 虚拟 virtio-net，MAC `34:54:00:4d:00:03` |
| 设备直通 | 无 | 无 |
| 网络中断 | 设备图分配的虚拟 GIC SPI，经 VGIC 注入 | 设备图分配的虚拟 GIC SPI，经 VGIC 注入 |

当前嵌套 Linux VM 未配置 `kernel.cmdline`，运行日志中的实际值为：

```text
Kernel command line:
```

Linux 由随 VM 加载的 initramfs 启动默认 `/init`，该脚本配置网络并运行 RT-IPC 客户端。
QEMU 命令行中的 `-append "root=/dev/nvme0n1 rw init=/bin/sh"` 只作用于外层 AxVisor host，
不是嵌套 Linux 的启动参数。AxVisor 为客户机重建 FDT，只暴露配置中的 vCPU、内存、
虚拟 GIC、PL011 和虚拟 virtio-net。网络主数据通道没有使用共享内存、HyperCall 或 vsock。

网络中断不是物理 SPI passthrough。内部 L2 switch 收到目标帧后先发布 ingress 状态，再通过
vCPU runtime notification/IPI 唤醒目标 vCPU；目标 vCPU 的设备进度路径处理 virtqueue，随后
由 `IrqLine::pulse` 向该 VM 的 VGIC 注入设备图自动分配的边沿 SPI，最终进入 Linux 或
RT-Thread 的 virtio-net ISR。该路径由网络事件触发，不依赖周期轮询或共享内存通知。

### 2.3 网络拓扑

```text
Linux 2-vCPU VM
  34:54:00:4d:00:01 / 192.168.77.11/24
                |
       AxVisor virtio-net + internal L2 switch
                |
  34:54:00:4d:00:03 / 192.168.77.30/24
RT-Thread 1-vCPU VM, UDP 9876
```

QEMU backend MAC 为 `52:54:00:77:00:01/03`，接入隔离的 `hubid=77`。测试没有 TAP、NAT 或默认路由，
没有向宿主或外部网络开放端口，因此不依赖宿主防火墙规则。两端在同一 `/24` 网段直接
ARP 和单播通信。

## 3. 实时性改造

1. Linux vCPU 使用 `{0,1}` CPU 集合，RT-Thread vCPU 固定 `{2}`，实现实时核隔离。
2. RT-Thread 空闲策略设为 `busy`；对 trapped WFI 增加 AArch64 汇编快速返回路径，只保存
   临时使用的 `x9/x10`、校验 `ESR_EL2.EC` 和策略位、推进 `ELR_EL2` 后直接 `eret`，不再
   保存完整 guest 上下文、进入 Rust、关闭/恢复 guest CNTV 或执行外层 `yield_now()`。
3. RT-Thread 1 ms 周期基准改用 `RT_TIMER_FLAG_HARD_TIMER`，直接在 hard-timer 中断路径采样。
4. AArch64 generic timer 使用绝对 `CNTV_CVAL` deadline，并补偿已跨过的周期，避免相对
   `TVAL` 累积漂移。
5. SGI/PPI pending 操作使用当前 CPU redistributor；SGI 基准保留并恢复原中断描述符和使能状态。
6. 虚拟 GIC、物理 SPI 路由和 vCPU wakeup 使用 IRQ-safe 发布/注入路径，不使用网络轮询。
7. Linux 的 VM-scoped TLBI 只作用于该 VM 的 pCPU0/1，不向 RT-Thread pCPU2 广播。
8. QEMU 进程及其已有线程应用 `uclamp.min=1024`，减少宿主节能/调度造成的 TCG 供给不足。
9. 长测同时保存实际样本数、缺失样本、P50/P95/P99/P99.9/max 和 100/500/1000 us 超限数，
   门禁拒绝不完整数据。

`uclamp.min` 是宿主调度提示，不是实时优先级，也不能替代 PREEMPT_RT、CPU isolation 或 KVM。

## 4. 实时性测试结果

### 4.1 Benchmark suite，网络并发，1000 样本

运行命令：

```bash
RTIPC_COUNT=1000 \
RTBENCH_SUITE_SAMPLES=1000 \
RTBENCH_START_MODE=concurrent \
QEMU_UCLAMP_MIN=1024 \
CPU_LOAD_LOG=/tmp/rtbench-suite-cpu.log \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
bash os/axvisor/scripts/run_rtipc_test.sh
```

| 指标 | P50 | P95 | P99 | P99.9 | 最大值 | >1 ms |
|------|----:|----:|----:|------:|-------:|-------:|
| 1 ms timer jitter，run 1 | 21.024 us | 83.248 us | 98.240 us | 109.888 us | 115.136 us | 0 |
| 1 ms timer jitter，run 2 | 37.520 us | 83.888 us | 107.200 us | 808.880 us | 997.216 us | 0 |
| 1 ms timer jitter，run 3 | 38.320 us | 66.480 us | 104.112 us | 118.928 us | 188.416 us | 0 |
| 抢占延迟 | 5.056 us | 5.472 us | 6.080 us | 11.344 us | 15.728 us | 0 |
| SGI 中断响应延迟 | 77.552 us | 86.192 us | 180.640 us | 269.632 us | 274.160 us | 0 |

所有指标均为 `expected=1000 collected=1000 missing=0`，最终 `RTBENCH_END status=PASS`。
SGI 指标从写 GIC redistributor pending 到 RT-Thread ISR 读取 `CNTVCT_EL0`，包含虚拟 GIC
陷入、注入和 guest ISR 入口，不是单纯函数调用耗时。

原始日志：
`docs/docs/build/axvisor/task1-2026-08-15-rtbench-suite-1000-pass-guest.log`。

### 4.2 300 秒稳定性

严格门限：`299999` 个 1 ms 周期样本全部采集，且偏差大于 1 ms 的次数必须为 0。

```bash
RTIPC_COUNT=30000 \
RTBENCH_STABILITY_SECONDS=300 \
RTBENCH_START_MODE=concurrent \
QEMU_UCLAMP_MIN=1024 \
CPU_LOAD_LOG=/tmp/rtbench-300s-cpu.log \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
bash os/axvisor/scripts/run_rtipc_test.sh
```

| 轮次 | 网络负载 | P50 | P95 | P99 | P99.9 | 最大 | >1 ms | 状态 |
|------|----------|----:|----:|----:|------:|-----:|------:|------|
| 30 s 控制轮 | 3 x 1000 | 44.432 us | 261.488 us | 740.336 us | 3.164 ms | 16.632 ms | 64 | FAIL |
| 300 s 复验 A | 3 x 1000 | 36.368 us | 91.472 us | 181.808 us | 325.552 us | 2.714 ms | 2 | FAIL |
| 300 s 复验 B | 3 x 30000 | 64.560 us | 288.000 us | 373.872 us | 457.440 us | 997.808 us | 0 | PASS |
| 300 s 复验 C | 3 x 30000 | 54.272 us | 275.088 us | 340.896 us | 440.288 us | 1.107280 ms | 1 | FAIL |
| 300 s 复验 D（2026-08-16） | 3 x 30000 | 50.528 us | 280.208 us | 385.216 us | 478.144 us | 1.512640 ms | 3 | FAIL |
| Busy-WFI 快速路径 v8 | 3 x 30000 | 8.288 us | 241.328 us | 293.712 us | 362.144 us | 1.193376 ms | 2 | FAIL |
| v8 + 宿主线程固定反例 | 3 x 30000 | 37.760 us | 302.640 us | 391.936 us | 476.640 us | 2.872016 ms | 14 | FAIL |

表中各轮均完整采样，没有把零初始化槽位当作数据。复验 B、C、D、v8 和宿主亲和性反例
均同时完成 90,000 个应用请求。
复验 C 的 callback 最大值为 `175.776 us`，callback 本身没有超过 1 ms；该轮稳定运行
`301.607320 s`，采集 `299999/299999` 个周期样本，唯一一次超限比门限高 `107.280 us`。

复验 D 同样采集 `299999/299999` 个样本，运行 `301.645907 s`；callback 最大值为
`164.224 us`，3 个 `>1 ms` 离群值来自周期唤醒链路而非 callback 执行时间。该轮网络门禁
独立 PASS，实时性门禁按预先定义的零容忍规则 FAIL。

Busy-WFI 快速路径 v8 运行 `301.636828 s`，采集 `299999/299999`，callback 最大
`157.312 us`，没有 callback 执行时间超过 1 ms；网络同时完成 `90000/90000`，零请求超时、
零协议错误。QEMU 边界探针把该轮稳定窗口内的两次门限失败定位为：一次 main-loop timer
callback 晚 assert `1.126880 ms`，一次 PPI27 assert 后 CPU2/TCG 晚进入异常
`1.116600 ms`；异常入口到 guest 读取 `ICC_IAR1` 分别只有 `1.320 us` 和 `2.460 us`。

宿主线程固定反例把 main-loop、CPU0/1/2/3 TCG 分别固定到宿主 CPU15/0/1/14/2，CPU2/TCG
的 `379/379` 个宿主采样均在 CPU14，main-loop 的 `379/379` 个采样均在 CPU15。结果反而
出现 14 次 `>1 ms`；探针记录的 12 个 `iar_late > 1 ms` 边界全部来自 deadline 前的晚
assert，`assert_to_entry > 1 ms` 为 0，异常入口到 IAR 的最大值为 `4.520 us`。这证明未隔离
宿主 CPU 上的单纯 affinity 会限制 Linux 调度器避让能力，不是可用的实时性修复。

复验 C 的宿主 CPU 采样（去除首个启动样本）显示：Linux CPU0/TCG 平均 `99.28%`，
Linux CPU1/TCG 平均 `0.54%`，RT-Thread CPU2/TCG 平均 `99.56%`，保留 CPU3/TCG
为 `0.00%`。这反映本次 initramfs 负载主要使用 Linux vCPU0，但 Linux VM 确实按 2-vCPU
启动；RT-Thread 对应 TCG 线程在测试窗口持续获得 CPU。

### 4.3 控制变量与根因

已验证的控制变量：

| 变量 | 结果 |
|------|------|
| RT-Thread soft timer -> hard timer | P95/P99 明显下降，去除 soft-timer 线程调度成分 |
| QEMU 全线程 `uclamp.min=1024` | 10 秒从多次 >1 ms 改善到最大 613.904 us、0 次 >1 ms |
| 仅绑 CPU2/TCG 或绑定全部 QEMU 线程 | 仍出现约 1.27-1.29 ms 最大值，不是有效修复 |
| 移除 `pidstat` | 没有消除离群值，采集器不是根因 |
| Linux EL1 TLBI 限定到 VM pCPU0/1 | CPU2 离群窗口与 TLBI 不重叠 |
| Busy WFI 外层不再 `yield_now()` | 10 秒 P50 从 39.824 us 降到 21.024 us，但完整 world switch 仍保留长尾 |
| Busy WFI 汇编快速返回 | 10 秒 P50/P99/mean 降到 2.528/24.832/4.102 us，`miss_1ms=0` |
| 固定 QEMU main-loop 与各 TCG 线程 | 300 秒退化到 14 次 `>1 ms`，否定“普通宿主仅绑核即可修复” |

三阶段相同 10 秒并发控制结果：

| 阶段 | P50 | P95 | P99 | 最大值 | mean | >1 ms |
|------|----:|----:|----:|-------:|-----:|-------:|
| v6：Busy WFI 完整 world switch | 39.824 us | 169.744 us | 293.584 us | 523.808 us | 55.983 us | 0 |
| v7：外层不再 yield | 21.024 us | 130.800 us | 254.784 us | 3.928992 ms | 35.252 us | 2 |
| v8：汇编快速返回 | 2.528 us | 10.384 us | 24.832 us | 997.392 us | 4.102 us | 0 |

QEMU 源码级低扰动诊断表明，CPU2 generic timer 使用 `QEMU_CLOCK_VIRTUAL`，由 QEMU
main-loop timer list 先执行 callback，再 assert PPI27。探针分别记录 deadline 编程、timer
assert、外层 CPU 异常入口和 `ICC_IAR1` 读取，并附带 TID、wall time 与
`CLOCK_THREAD_CPUTIME_ID`。v6 曾捕获同一 CPU2/TCG 线程
`program_to_assert_wall=1.636470 ms`、`thread_cpu=1.603877 ms`，证明主要 WFI 长尾是 QEMU
真实执行完整 AxVisor world switch，而不是宿主抢占；这部分由 v8 快速路径修复。v8 的剩余
两次 300 秒超限则跨 main-loop/TCG 线程边界，发生在 QEMU assert 前或 assert 后等待 TCG
线程，且与 AxVisor TLBI、global exclusive、CPU2 exclusive-stop 不重叠。

结论：已确认的 AxVisor Busy-WFI 根因已经修复；当前剩余长尾主要受 QEMU TCG main-loop
和普通宿主调度影响。PPI27 一旦进入 QEMU CPU2 异常路径，到 guest IAR 的微秒级数据不支持
继续修改 AxVisor VGIC/中断路径。结果说明 AxVisor 关键路径已经达到较低延迟，但不能据此
宣称硬件上的 WCET 或严格硬实时保证。

### 4.4 原生 RT-Thread 等价基线

同一 QEMU `virt`/GICv3/Cortex-A72 平台直接启动 RT-Thread，不经过 AxVisor；1 vCPU、
1 GiB、相同 1 ms hard-timer benchmark，地址调整为 RAM `0x40000000`、入口 `0x40200000`。

| 指标 | 原生 RT-Thread 300 s | AxVisor 历史最佳门禁 PASS 轮 |
|------|---------------------:|--------------------:|
| P50 | 8.432 us | 64.560 us |
| P95 | 16.640 us | 288.000 us |
| P99 | 27.456 us | 373.872 us |
| P99.9 | 57.728 us | 457.440 us |
| 最大值 | 692.672 us | 997.808 us |
| >1 ms | 0 | 0 |

基线命令：

```bash
cd tmp/rt-thread-5.2.2-native/bsp/qemu-virt64-aarch64
uv run --with scons scons -j4
qemu-system-aarch64 -display none -monitor none \
  -machine virt,gic-version=3 -cpu cortex-a72 -smp 1 -m 1G \
  -serial stdio -kernel rtthread.elf
# RT-Thread shell:
rtbench_stability 300
```

原始结果：`docs/docs/build/axvisor/task1-2026-08-15-native-300s.log`。
平台差异包括 AxVisor 二级地址转换、VM exit/entry、VGIC 和额外 TCG vCPU/main-loop 竞争，
因此原生与虚拟化结果用于开销对比，不等同于真实 ARM 板裸机结果。

## 5. RT-IPC 协议

### 5.1 帧格式

固定头长 20 字节，网络字节序：

| 字段 | 长度 | 说明 |
|------|-----:|------|
| version | 1 B | 当前 `0x02` |
| message type | 1 B | CTRL_CMD、STATUS_REP、ERROR_NOTIFY、ACK、SYN/SYNACK、HEARTBEAT、FIN |
| payload length | 2 B | 最大 1400 B |
| sequence number | 4 B | 可靠传输、去重和乱序恢复 |
| session ID | 8 B | 每个连接化身的随机标识，隔离客户端重启和旧会话报文 |
| error code | 2 B | OK、CRC、版本、长度、超时、断连、缓冲区错误 |
| CRC16-CCITT | 2 B | 覆盖 checksum 清零后的头部及 payload |

协议满足版本、消息类型、载荷长度、序号、错误码和校验字段要求。Linux 发送控制命令，
RT-Thread 执行 echo/control responder 并返回状态；异常使用 ERROR_NOTIFY 和 error code。

### 5.2 可靠性机制

- SYN/SYNACK 会话建立，FIN 关闭，heartbeat/heartbeat ACK 保活；
- 累计 ACK，默认 RTO 500 ms，客户端最多重传 5 次；
- 64 包发送窗口，序号回绕安全比较；
- 重复包只 ACK、不重复交付；
- 64 槽乱序缓存，缺口补齐后按序交付；
- Linux 客户端在 heartbeat 或发送超时后指数退避重连；RT-Thread 固定服务端保持被动监听，
  会话关闭后释放旧客户端的临时 UDP 端口；
- Linux 使用 `getrandom()` 为每次进程启动生成 64 位 session seed，RT-Thread 仅允许完成
  有效 SYN 的 UDP `(IPv4, port)` 对端占有当前会话；connected Linux UDP socket 同时由内核
  丢弃非目标来源数据报；
- RT-Thread 将 32 位毫秒 tick 扩展为带 epoch 的单调 64 位时间，覆盖约 49.7 天回绕；
- RT-Thread 网络配置、接收超时、线程创建和启动错误均返回或输出
  `RTIPC_SERVER_ERROR stage=... code=...`；
- TCP 未使用，因此不存在 TCP 字节流分帧问题；vsock 未使用。

## 6. 网络性能与可靠性结果

### 6.1 300 秒/90,000 请求轮次

下表为 Busy-WFI 快速路径 v8 的 2026-08-16 最终非绑核轮；此前复验数据保留在本节后的
迭代说明中。

| Payload | 请求/响应 | 成功率 | RTT P50 | RTT P95 | RTT P99 | RTT max | 有效吞吐量 |
|--------:|----------:|-------:|--------:|--------:|--------:|--------:|-----------:|
| 64 B | 30000/30000 | 100% | 3 ms | 24 ms | 24 ms | 779 ms | 10.79 KiB/s |
| 256 B | 30000/30000 | 100% | 3 ms | 23 ms | 24 ms | 1642 ms | 57.47 KiB/s |
| 1024 B | 30000/30000 | 100% | 3 ms | 21 ms | 24 ms | 506 ms | 247.10 KiB/s |

三档均为 `request_timeouts=0`、`protocol_errors=0`。64B 档中途强制断连一次，`228 ms`
完成恢复。三档分别观察到 2、4、1 次协议重传，接收端仍为 30000/30000；
这验证了可靠性机制在并发长测中的实际工作。长 RTT 最大值反映 QEMU/guest 调度停顿，
不是请求失败；应用成功率仍为 100%，RT-IPC 结果门禁 PASS。复验 B 的对应吞吐量为
`13.49/66.07/325.41 KiB/s`，最大 RTT 为 `882/603/1633 ms`。

### 6.2 确定性故障注入

运行命令：

```bash
RTIPC_COUNT=1000 \
RTIPC_FAULT_PROFILE=reliability \
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
bash os/axvisor/scripts/run_rtipc_test.sh
```

| 场景 | 注入 | 协议观测 | 应用结果 |
|------|------|----------|----------|
| 丢包 | 丢弃首个 64B CTRL_CMD datagram | `retrans=1` | 1000/1000，0 timeout |
| 重复 | 首个 256B STATUS_REP 向协议层交付两次 | `dup=1` | 1000/1000，只交付一次 |
| 乱序 | 前两个真实 1024B STATUS_REP 交换顺序 | `reorder=1` | 1000/1000，按原序交付 |
| 断连 | 64B 第 500 个请求前强制断连 | `reconnects=1`，恢复 215 ms | 后续请求继续成功 |

三档均为 `request_timeouts=0 protocol_errors=0 errors=0`，客户端退出码 0，结果门禁 PASS。
原始日志：`docs/docs/build/axvisor/task2-2026-08-15-rtipc-reliability-faults-pass-guest.log`。

### 6.3 v2 会话隔离与 FIN 关闭可靠性修复复验

2026-08-16 针对质量复审发现的多对端接管、客户端重启复用旧序号、RT-Thread tick 回绕和
启动错误吞没进行了协议/适配层修复。新增测试覆盖客户端使用不同 session seed 重启后的
首包交付、旧化身报文重放、UDP 对端所有权、`UINT32_MAX-15 -> 5` 的 tick 回绕，以及
RT-Thread 启动失败传播。

后续复审又定位并修复两类关闭/重放交错：协议核心使用 16 槽静态环记录已退役
`session_id`，延迟旧 SYN 不再回滚到旧会话；RT-Thread 适配层保存精确
`(IPv4, port, session_id, FIN seq, deadline)` FIN tombstone，使首个 FIN ACK 丢失后的重复
FIN 能够幂等获得 ACK。进一步的多 peer 复审发现，新 peer 曾可在 FIN 重试窗口内清除
tombstone；最终实现让 `claim` 接收单调时间，在 tombstone 有效期内拒绝新 owner，过期后
才允许接管，并在把 SYN 交给协议核心前执行该门禁。

TDD 的关键 RED 证据为 `new peer displaced a live FIN tombstone`；修复后平台安全测试、严格
C99 `-pedantic-errors -Wall -Wextra -Werror`、ASan/UBSan 和 Linux FIN ACK 丢失关闭测试均
PASS。

双 VM QEMU smoke 使用 v2 当前源码运行，64/256/1024 B 各 `10/10`，三档均为
`request_timeouts=0 protocol_errors=0`，强制断连恢复 `216 ms`，RT-IPC 结果门禁 PASS。
原始日志为
`docs/docs/build/axvisor/task2-2026-08-16-v2-session-final-smoke-10.log`，SHA-256 为
`1f0c9aeef6880ba9e8dac360dc1a07672dc6860d2b9b14e1965a5b3ac80b3784`。

最终多 peer 修复后的双 VM QEMU 复验为 64/256/1024 B 各 `1000/1000`，三档均为
`request_timeouts=0 protocol_errors=0`，强制断连恢复 `216 ms`，结果门禁 PASS。日志为
`docs/docs/build/axvisor/task2-2026-08-16-fin-multipeer-1000.log`，SHA-256 为
`f52d923830e44e337c13693e9c3aeb7ee4cca5e4955f190ace20250d6678df7c`。

## 7. 构建与复现

依赖：`aarch64-linux-gnu-gcc`、`uv`、`socat`、`pidstat`、QEMU AArch64 11.0.2。

| 输入 | 路径/版本 |
|------|-----------|
| 分支 | `rtthread-migration`，基线提交和当前工作树见报告页首 |
| QEMU/AxVisor profile | `os/axvisor/configs/qemu/qemu-aarch64-two-guest-net.toml` |
| Linux VM 配置 | `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml` |
| RT-Thread VM 配置 | `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml` |
| Linux kernel | `tmp/vmconfigs/three-guest-net/current/linux-kernel` |
| Linux initramfs 源 | `tmp/vmconfigs/two-guest-net/current/linux-1-initramfs.cpio` |
| AxVisor host rootfs | `tmp/vmconfigs/two-guest-net/current/rootfs.img` |
| RT-Thread 源码 | `tmp/rt-thread-5.2.2-full`，固定提交 `ddf52e2cdd977f14fc04035c88672ac204aec713` |

每轮 runner 会把实际解析后的输入、生成的 initramfs/VM 配置及 AxVisor/RT-Thread 二进制
SHA-256 写入对应 `*-artifacts.log`，避免只凭路径判断本轮使用的镜像。

```bash
# 协议、可靠性与门禁单测
make -C os/axvisor/guests/rt-ipc/tests clean \
  test test_loopback test_fault_profile
bash os/axvisor/scripts/test_rtipc_result_gate.sh
bash os/axvisor/scripts/test_rtbench_suite_gate.sh
bash os/axvisor/scripts/test_rtbench_stability_gate.sh
bash os/axvisor/scripts/test_host_realtime_contract.sh
bash os/axvisor/scripts/test_qemu_realtime_controls.sh

# 验证并构建 RT-Thread 5.2.2
# 目标目录必须不存在或保持 pinned commit 的完全干净状态。
bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh \
  tmp/rt-thread-5.2.2-full
bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh \
  tmp/rt-thread-5.2.2-full
bash os/axvisor/patches/rtthread/test-rtthread-patches.sh \
  tmp/rt-thread-5.2.2-full
uv run --with scons scons \
  -C tmp/rt-thread-5.2.2-full/bsp/qemu-virt64-aarch64 -j4

# 构建 Linux 客户端
make -C os/axvisor/guests/rt-ipc/linux

# runner 会重建 initramfs、AxVisor 和两个 guest，然后启动 QEMU
RTIPC_COUNT=1000 bash os/axvisor/scripts/run_rtipc_test.sh
```

runner 的结果门禁要求 QEMU、Linux 客户端、三档请求和可选实时 benchmark 同时完成；
缺失 marker、样本、payload 结果、故障计数或出现 panic 都会返回非零状态。
Linux init 还输出 `LINUX_SMP_READY configured=2 online=0-1 nproc=2`；结果门禁要求该完整
标记恰好出现一次。门禁按完整子串计数，允许异步内核 printk 紧接在标记之后，避免把合法
串口交错误判为 SMP 失败。

可选 QEMU 11.0.2 边界探针只用于诊断，不属于运行时依赖：

```bash
cd qemu-11.0.2
patch -p1 < \
  /path/to/tgoskits/docs/docs/build/axvisor/qemu-rtthread-timer-boundary-diagnostic.patch
mkdir build && cd build
../configure --target-list=aarch64-softmmu --disable-docs
ninja qemu-system-aarch64
```

最新版补丁为 336 行，SHA-256
`8525c2c81e8359b0453b22d6fb3c10ad5b825b8fdda62bf2599c727612cfce22`；已在官方 QEMU
11.0.2 干净源码上通过 `patch -p1 --dry-run`，实际应用后的五个文件与本轮探针源码逐字节一致。
本轮探针二进制 SHA-256 为
`98e36db59ef04d96a88d8959f61f7336dcffd8fbd8a5267c7dfedc1953ebc95a`。

## 8. 回归验证

2026-08-16 当前工作树结果：

| 验证项 | 结果 |
|--------|------|
| `arm_vcpu` | 17 tests + 1 doctest PASS，包括 Busy-WFI 汇编顺序和 timer world-switch 契约 |
| `axvmconfig` | 13 tests PASS |
| `axvm --features host-test` | 258 unit + 1 contract PASS |
| `axvirtio-net` | 14 unit + 17 integration PASS |
| AxVisor host realtime contract | PASS |
| RT-Thread patch/benchmark invariants | PASS |
| RT-IPC protocol/responder | 21 + 1 PASS |
| RT-IPC reliability loopback | 4/4 PASS |
| v2 session restart/stale replay | PASS |
| UDP peer ownership、FIN tombstone 交错 + 32-bit tick wrap | PASS |
| RT-Thread startup error contract | PASS |
| deterministic fault profile | PASS |
| RT-Thread fresh patchset + SCons AArch64 build | PASS，存在既有/上游编译警告 |
| 2-vCPU Linux + RT-Thread + RT-IPC QEMU | PASS；内核、AxVisor、用户态三层 SMP 证据齐备 |
| benchmark suite 1000 | PASS |
| 300 s strict stability | v8 样本完整；2 次 `>1 ms` 判 FAIL，最大 1.193376 ms，见第 4.2 节 |
| 300 s concurrent RT-IPC | 90000/90000、0 request timeout、0 protocol error，PASS |
| v2 双 VM QEMU smoke | 3 x 10/10、断连恢复 216 ms，PASS |
| FIN 多 peer 修复后双 VM QEMU | 3 x 1000/1000、断连恢复 216 ms，PASS |

Busy-WFI 快速路径 v8 的 300 秒命令总退出码为 1，仅由严格实时性门禁触发；网络门禁独立
PASS。原始证据位于
`docs/docs/build/axvisor/task12-busy-wfi-fast-v8-300s*.log`。主日志 SHA-256 为
`f77268d0a79d122234c55372edf8295533cc757b18b4ef0968870b3f0ebad5df`，QEMU 探针日志为
`f675c5a1be523ca1bbeb18133f80bf8764379c1ce2ca06bbc1005574d191a256`，CPU 日志为
`09cad3f05c8042d410d786c4f1c0506ff3793854057cd627e1185d555e1b16ad`，宿主计时日志为
`321e994baf924f8e75c0eeae0a30d8ab3d4f00cc28a2cc2144c1d11ec4b13aa4`。该轮 AxVisor
二进制 SHA-256 为 `4c48b44ea92c65df0f2338a7eec722b873b23001e20c6465ef8ea59a2203b0d7`，
RT-Thread 二进制为 `5bdb0417f63aced3d679eed8aca9f0171428a207c09b99c6bfaf2a84495eb5e1`。

宿主亲和性反例证据位于
`docs/docs/build/axvisor/task12-busy-wfi-fast-v10-host-affinity-300s*.log`；亲和性记录、主日志和
QEMU 探针日志 SHA-256 分别为
`c784a780f5c22838ea2bdf9eba994eac6dead104c18076799e61b7f268cf9317`、
`284163ef700de8e5549f99f8740010cfe99af15139070e8af40a9b4d5d1aad09`、
`4be793bb40026a0f54c776b39c68b29dc18bcc8a12bad9d1010f91783acc6fe1`。

直接执行无 feature 的 `cargo test -p axvm` 会因 bare-metal 平台链接符号缺失而失败；
仓库支持的 host 单测入口是 `cargo test -p axvm --features host-test`。

2-vCPU fresh 复验使用当前工作树完整重建 RT-Thread、initramfs 和 AxVisor，64/256/1024 B
各完成 `10/10` 请求，零请求超时、零协议错误，runner 总退出码为 0。主日志、QEMU 日志和
artifact manifest 分别为
`docs/docs/build/axvisor/task12-2026-08-16-2vcpu-runtime-smoke-v2.log`、同前缀
`-qemu.log` 和 `-artifacts.log`，SHA-256 分别为
`a5ac525d1bdf9a42f201a5ef13a155fa54cf36a8dfcac65f83abab2255897f72`、
`c7c310ad0295e1d69c7980d56561a0a71af76e83d145db33c6a6343a1dab4aea`、
`7d2939cd89d5da69f66e4a8aff846a7d07eea1f35d5114a1ff0ddb61636e1979`。

## 9. 限制与后续硬件验收

1. QEMU TCG 的 timer callback 由宿主 main loop 触发，普通宿主调度可在 guest 中断产生前引入毫秒级离群值。
2. `uclamp.min=1024` 改善 CPU 供给，但不是实时调度保证；不要把单轮 `max < 1 ms` 外推为 WCET。
   在未隔离宿主 CPU 上固定 QEMU main-loop/TCG 线程已实测退化，不能作为默认方案。
3. 硬件验收应使用隔离 pCPU、固定频率、IRQ affinity、PREEMPT_RT 或等价实时宿主，至少重复
   3 轮 30 分钟和 1 轮 24 小时，并保留所有最大值而非只报告最佳轮次。
4. 真实网口测试还需记录 PHY/MAC 中断、交换机排队和时钟同步误差；本报告只覆盖隔离虚拟网络。

历史迭代数据保留在同目录的 `rtthread-realtime-report-v3.md` 到 `v13.md` 及
`task1-*`、`task2-*`、`task12-*` 原始日志中。

## 2026-08-16 调试代码清理与回归验证

### 清理范围

本轮清理只删除临时调试资产和成功路径热点诊断，保留产品行为、失败诊断、
结构化 benchmark 记录和本报告引用的历史证据：

- 仓库根目录工作站启动器：`run-debug.sh`、`run-gicv2-test.sh`、`run-head-120.sh`、
  `run-head-test.sh`、`run-main.sh`、`run-rx-debug.sh`、`run-txdbg.sh`、`run-verify.sh`。
- 跟踪备份：`io.rs.bak`、Linux/RT-Thread 的 `*.bak-passthrough` 和 `*.bak-virt`，共 5 个。
- 可重建产物：`os/axvisor/configs/vms/qemu/aarch64/rtthread-net.dtb`。DTS 和生成工具仍是
  单一事实源。
- 明确保留 `qemu-rtthread-timer-boundary-diagnostic.patch`、原始日志、RT-IPC 错误统计和
  benchmark marker。清理后上述 14 个候选资产均不存在，诊断补丁仍存在。

代码和自动化边界的清理如下：

- `validate_qemu_artifact.sh` 不再依赖 `awk`/`nm`，删除 host-policy 调试字符串和导出符号
  witness；仍验证 ELF 重生 raw image 逐字节相等、VM 配置同时嵌入 ELF/raw、输入
  不变以及 manifest 路径和 SHA-256。
- `virtio_net.rs` 删除分配/TX/丢包/no-buffer 热路径累计器和 MMIO debug 输出；
  保留丢包 warning、客户机 RX kick 驱动的 deferred-ingress 行为以及对应的状态/中断测试。
- `init-linux-1` 删除成功路径额外 `ifconfig`、`/proc/net/snmp` 和 `/proc/net/udp` dump；
  保留 `LINUX_SMP_READY`、网络 ready/reachability、失败时接口/邻居诊断和客户端退出码。

本次 cleanup 的文件级审计入口 allowlist 仅包含下表路径。`modified` 标识包含 cleanup hunk
的产品/自动化文件，`deleted candidate` 是批准删除的 14 个候选；报告和
`task12-cleanup-*` 日志属于证据输出，不扩大产品 cleanup 范围。由于 allowlist 文件还包含
预先存在的用户功能改动，路径名单本身不是可安全整文件暂存的 cleanup 身份；共享工作树中的
其他用户改动均保持原样、未提交，本轮没有把它们归入 cleanup 身份：

| 类别 | 精确路径 |
|------|----------|
| modified | `os/axvisor/scripts/test_rtipc_result_gate.sh` |
| modified | `os/axvisor/scripts/test_rtbench_precision.sh` |
| modified | `os/axvisor/scripts/validate_qemu_artifact.sh` |
| modified | `os/axvisor/src/virtio_net.rs` |
| modified | `os/axvisor/guests/linux-net/init-linux-1` |
| deleted candidate | `run-debug.sh` |
| deleted candidate | `run-gicv2-test.sh` |
| deleted candidate | `run-head-120.sh` |
| deleted candidate | `run-head-test.sh` |
| deleted candidate | `run-main.sh` |
| deleted candidate | `run-rx-debug.sh` |
| deleted candidate | `run-txdbg.sh` |
| deleted candidate | `run-verify.sh` |
| deleted candidate | `os/arceos/api/arceos_posix_api/src/imp/io.rs.bak` |
| deleted candidate | `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-passthrough` |
| deleted candidate | `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml.bak-virt` |
| deleted candidate | `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-passthrough` |
| deleted candidate | `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml.bak-virt` |
| deleted candidate | `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.dtb` |

#### Hunk/blob 审计身份

cleanup 必须按 hunk 审计，**禁止整文件 staging**：整文件暂存上述 allowlist 路径会同时纳入
不属于 cleanup 的用户功能改动，因此是不安全的。本任务没有暂存任何 cleanup-scope 文件；
但仓库 index 在任务开始前已经非空，其中
`os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c` 状态为 `AM`，即 staged addition
叠加 unstaged modification。因此直接执行普通 `git commit` 不安全；最终集成必须使用显式
cleanup pathspec/hunk staging，并先检查 `git diff --cached`。下列 before/after
SHA-256 用于固定观测到的内容状态，紧随其后的 hunk 锚点用于从这些文件中隔离 cleanup；
**内容哈希与 hunk 锚点共同构成本次 cleanup 的审计身份**：

| 文件 | scoped before SHA-256 | cleaned after SHA-256 | before 来源 |
|------|-----------------------|--------------------------|-------------|
| `os/axvisor/scripts/test_rtbench_precision.sh` | `ac831454e926f83195c70a5094adf1639abf779f7d4d303b82830a89cde70c66` | `550e4333d5f1a6c6bbaf8586035dcb7e2c57da7c446ad8d98927ff9804f900ba` | `f5c61c734` blob 内容 |
| `os/axvisor/scripts/validate_qemu_artifact.sh` | `be040d958a97d95b981f6b7e8ca64b0e41df225d94b4d991eba424d52bb06a7a` | `b665240fa7313ac6033d9e7caa01066cd94709fe4c16a680d49f07234b455563` | `f5c61c734` blob 内容 |
| `os/axvisor/src/virtio_net.rs` | `9bfaa19f8c02f70f149dffba5546b8783f8a1ddf0e45dd7ee5efa288e6d678f6` | `63af03a44476a19eba667ae26e4d4e28b2c16fb4b7ed141b37a5b4040385745a` | scoped 清理前诊断重构 |
| `os/axvisor/guests/linux-net/init-linux-1` | `52d2cacf5fe8eacc48f8b90d5627d41f5d9dda40ff8649c2e285a76ada15707d` | `706b14b03f4ea46d5d67e1cb0a9f2ca3c91268138fff9494f96177d76cb6b200` | scoped 清理前诊断重构 |
| `os/axvisor/scripts/test_rtipc_result_gate.sh` | `c69df3b36c57dc4933f441f141a2972d3496239a48aa0d49e00375dc3607277e` | `8ac07fecbdd20bd48a47e22e68c861184293eb73baea73a55b756613e4ed5995` | 捕获的 pre-edit block 重构；不是 Git object，当前文件未跟踪 |

精确 scoped hunk 锚点/操作如下：

- `test_rtbench_precision.sh`：只包含 fail-closed stale-debug scan 和 artifact-validator behavior
  fixtures，包括 `verify_generated_set` 测试 fixture 适配。
- `validate_qemu_artifact.sh`：只删除 `awk`/`nm`/debug witness；保留 raw image 重生、VM config
  嵌入、输入不变、canonical path、SHA-256 和 manifest 等核心 artifact checks。
- `virtio_net.rs`：只删除 allocation log、TX/drop/no-buffer counters 及 counter assertions；保留
  deferred ingress 行为和对应状态/中断断言。
- `init-linux-1`：只删除成功路径的 `ifconfig`、`/proc/net/snmp`、`/proc/net/udp` dumps；保留
  既有 SMP marker、网络 ready/reachability 和 client lifecycle 改动。
- `test_rtipc_result_gate.sh`：只把 exact-string stale loop 替换为 structural success-path contract
  及其 fixtures。before 哈希来自捕获的 pre-edit block 重构，不宣称它是 Git object；当前文件
  为 untracked。

### Task6 聚焦测试矩阵与 fresh 构建

| 类别 | 命令/覆盖 | 结果 |
|------|-----------|------|
| 格式 | `cargo fmt --all -- --check` | PASS |
| Rust | `cargo test -p arm_vcpu` | 17 tests + 1 doctest PASS |
| Rust | `cargo test -p axvmconfig` | 13 tests PASS |
| Rust | `cargo test -p axvirtio-net` | 14 unit + 17 integration PASS |
| Rust | `cargo test -p axvm --features host-test` | 258 unit + 1 contract PASS |
| RT-IPC C | `make -C os/axvisor/guests/rt-ipc/tests clean test` | protocol/responder 21 + 1、loopback 4/4、concurrency/fault/lifecycle/safety PASS |
| Shell contracts | host realtime/timing、QEMU controls、precision、suite/stability/result gates、runner lifecycle、native baseline/reproducibility、VM config、marker wait | 12/12 PASS |
| Fresh RT-Thread | prepare + apply patches + invariant test + `uv run --with scons scons ... -j4` | PASS |

首次从网络 clone 的进程被人工中断，因此返回 `130`；这不是产品、补丁集或构建失败。
随后使用完整本地 seed 成功执行 fresh prepare：

```bash
RTTHREAD_REPOSITORY=tmp/rt-thread-5.2.2-full \
bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh \
  tmp/rt-thread-5.2.2-cleanup
```

生成树的 `origin` 为本地 seed，固定提交为
`ddf52e2cdd977f14fc04035c88672ac204aec713`。Task7 在该 fresh 树上重建得到的
RT-Thread image SHA-256 为 suite
`4da57282042e61869b61deed6cbc43100afa7b774bc3c9ccb47b7babc7d97a55`、300 s
`33a768ce68fa8396b13f3c83cda0d4c8456ee3dfb4b6a2b1ca06746ea1478c7a`、300 s repeat
`df6033e433d5075bb9b206eda3a7f6d7c4ff04c256dd9374f55f9d7afd49325e`。cleanup suite、300 s
首轮和 repeat 运行时的主仓库 `HEAD` 均为
`5e63f33e203266032ad00a390274409676c7e234`，并使用上述 allowlist 所限定的未提交 cleanup
工作树。报告本次审计时的实际 `HEAD` 是
`f5c61c734a926931949274f73e82a09151967741`；该提交随后才修订 baseline spec，要求使用
artifact-matched 同 QEMU 控制，因此它不是三轮 cleanup 的运行时源码身份，也不应把
`5e63f33e2` 称为当前 `HEAD`。

### Task7 精确命令和退出码

本轮在 suite 前、首轮 300 s 前和 repeat 前均执行
`pgrep -a -f '[q]emu-system-aarch64'`，均以无匹配状态 `1` 退出；
未终止任何外部 QEMU。实际执行命令如下：

```bash
env RTIPC_COUNT=1000 RTBENCH_SUITE_SAMPLES=1000 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/task12-cleanup-suite-1000.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-suite-1000-cpu.log \
  QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
  /usr/bin/time -f 'TASK12_SUITE_WALL=%e TASK12_SUITE_EXIT=%x' \
  bash os/axvisor/scripts/run_rtipc_test.sh

env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/task12-cleanup-300s.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-300s-cpu.log \
  QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
  /usr/bin/time -f 'TASK12_300S_WALL=%e TASK12_300S_EXIT=%x' \
  bash os/axvisor/scripts/run_rtipc_test.sh

env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/task12-cleanup-300s-repeat.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-300s-repeat-cpu.log \
  QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
  /usr/bin/time -f 'TASK12_300S_REPEAT_WALL=%e TASK12_300S_REPEAT_EXIT=%x' \
  bash os/axvisor/scripts/run_rtipc_test.sh
```

| 轮次 | runner | QEMU | Linux client | 墙钟 | benchmark host timing |
|------|-------:|-----:|-------------:|------:|----------------------:|
| suite 1000 | 0 | 0 | 0 | 36.93 s | 5.292902 s |
| 300 s | 0 | 0 | 0 | 462.64 s | 301.683541 s |
| 300 s repeat | 0 | 0 | 0 | 443.94 s | 301.631976 s |

### Suite 1000 结果

Linux 同轮输出 `LINUX_SMP_READY configured=2 online=0-1 nproc=2`；RT-Thread 输出
`lwIP-2.1.2 initialized!` 并启动 RT-IPC server。三档均完成 `1000/1000`，
`request_timeouts=0 protocol_errors=0 errors=0`：

| payload | RTT min/avg/max | P50/P95/P99/P99.9 | throughput |
|--------:|-----------------|--------------------|-----------:|
| 64 B | 1/4/33 ms | 3/23/24/30 ms | 11.86 KiB/s |
| 256 B | 1/4/26 ms | 3/23/24/24 ms | 48.64 KiB/s |
| 1024 B | 1/3/25 ms | 3/10/24/25 ms | 252.14 KiB/s |

benchmark 所有记录均为 `expected=1000 collected=1000 missing=0`，总门禁 PASS：

| metric/run | P50 | P95 | P99 | P99.9 | max | miss_1ms |
|------------|----:|----:|----:|------:|----:|---------:|
| timer jitter 1 | 4.000 us | 15.568 us | 58.048 us | 209.904 us | 258.208 us | 0 |
| callback 1 | 0.464 us | 0.944 us | 2.272 us | 9.984 us | 43.328 us | 0 |
| timer jitter 2 | 4.624 us | 17.232 us | 25.360 us | 624.352 us | 636.336 us | 0 |
| callback 2 | 0.464 us | 0.544 us | 0.656 us | 2.048 us | 2.048 us | 0 |
| timer jitter 3 | 6.656 us | 21.056 us | 33.600 us | 267.584 us | 283.952 us | 0 |
| callback 3 | 0.464 us | 0.624 us | 0.864 us | 3.680 us | 9.152 us | 0 |
| preemption | 4.768 us | 5.008 us | 5.280 us | 6.624 us | 15.504 us | 0 |
| irq | 76.720 us | 79.600 us | 84.112 us | 123.600 us | 252.016 us | 0 |

suite CPU 日志有 25 个一秒样本：QEMU 总 `%CPU` 平均 `187.44%`（范围
`108-196%`）；TCG0/1/2/3 平均分别为 `90.28%`、`0.72%`、`95.00%`、`0.00%`。

### 300 秒长稳首轮结果和 v8 比较

三档均完成 `30000/30000`，合计 `90000/90000`，均为
`request_timeouts=0 protocol_errors=0 errors=0`。传输层在 64/256 B 档自动恢复了少量
retrans/dup，但无 transport timeout/error，不影响请求完整性。

| payload | RTT min/avg/max | P50/P95/P99/P99.9 | throughput |
|--------:|-----------------|--------------------|-----------:|
| 64 B | 1/5/809 ms | 3/23/24/34 ms | 11.93 KiB/s |
| 256 B | 1/4/1620 ms | 3/23/24/29 ms | 48.42 KiB/s |
| 1024 B | 1/4/462 ms | 3/23/23/27 ms | 234.16 KiB/s |

stability benchmark 为 `expected=299999 collected=299999 missing=0`，脚本严格门禁本轮 PASS。
callback 为 P50/P95/P99/P99.9/max =
`0.512/0.688/0.960/4.560/164.096 us`，`miss_1ms=0`。抖动与 v8 的比较为：

| 指标 | v8 基线 | 清理后 300 s | 相对变化 | 回归门槛 |
|------|--------:|---------------:|---------:|----------|
| P50 | 8.288 us | 9.408 us | **+13.5135%** | **FAIL，>10%** |
| P95 | 241.328 us | 254.048 us | +5.2708% | PASS |
| P99 | 293.712 us | 315.104 us | +7.2833% | PASS |
| P99.9 | 362.144 us | 443.808 us | +22.5501% | 记录，非独立硬门槛 |
| max | 1.193376 ms | 0.997136 ms | -16.4441% | 改善 |
| miss_1ms | 2 | 0 | -100% | 改善 |

300 s CPU 日志有 451 个一秒样本：QEMU 总 `%CPU` 平均 `193.92%`（范围
`108-201%`）；TCG0/1/2/3 平均分别为 `93.20%`、`0.58%`、`98.80%`、`0.00%`。
TCG 线程在普通宿主 CPU 之间迁移，未施加额外 host affinity。

### 300 秒 repeat 结果和 repeatable 判定

批准 spec 要求 P50/P95/P99 的 `>10%` 回归必须可重复。报告初版曾错误地以
“不是仅 max/miss_1ms 变差”为由不运行 repeat；规格复核后已使用完全相同的
300 s concurrent/uclamp 参数补跑。首轮数据保留不变。

repeat 同轮再次输出 `LINUX_SMP_READY configured=2 online=0-1 nproc=2` 和
`lwIP-2.1.2 initialized!`。三档各 `30000/30000`，合计 `90000/90000`，
`request_timeouts=0 protocol_errors=0 errors=0`；输入传输层出现少量 retrans/dup 和一次
`SourceMacViolation` drop warning，可靠性层已恢复，无 transport timeout/error。

| repeat payload | RTT min/avg/max | P50/P95/P99/P99.9 | throughput | transport retrans/dup |
|---------------:|-----------------|--------------------|-----------:|---------------------:|
| 64 B | 1/4/758 ms | 3/23/24/28 ms | 12.09 KiB/s | 0/1 |
| 256 B | 1/3/521 ms | 3/7/24/27 ms | 63.19 KiB/s | 1/1 |
| 1024 B | 1/4/1587 ms | 3/23/24/30 ms | 204.66 KiB/s | 3/1 |

repeat stability benchmark 为 `expected=299999 collected=299999 missing=0`，脚本严格门禁 PASS。
callback P50/P95/P99/P99.9/max 为
`0.512/0.704/1.072/5.136/164.736 us`，`miss_1ms=0`。

| 指标 | v8 基线 | 300 s 首轮 | 首轮变化 | 300 s repeat | repeat 变化 | repeatable 判定 |
|------|--------:|-------------:|-----------:|-------------:|------------:|-----------------|
| P50 | 8.288 us | 9.408 us | +13.5135% | 9.760 us | **+17.7606%** | **确认，两轮均 >10%** |
| P95 | 241.328 us | 254.048 us | +5.2708% | 259.728 us | +7.6245% | 未超 10% |
| P99 | 293.712 us | 315.104 us | +7.2833% | 316.976 us | +7.9207% | 未超 10% |
| P99.9 | 362.144 us | 443.808 us | +22.5501% | 422.288 us | +16.6078% | 记录，非独立硬门槛 |
| max | 1.193376 ms | 0.997136 ms | -16.4441% | 0.869632 ms | -27.1284% | 改善 |
| miss_1ms | 2 | 0 | -100% | 0 | -100% | 改善 |

repeat CPU 日志有 432 个一秒样本：QEMU 总 `%CPU` 平均 `195.17%`（范围
`102-201%`）；TCG0/1/2/3 平均分别为 `94.55%`、`0.59%`、`98.76%`、`0.00%`。

**阶段性历史观察（baseline spec 修订之前）：功能 PASS，cleanup 两轮相对 v8 的 P50
增幅可重复。** Linux SMP、RT-Thread 网络启动、suite 三档、两轮各 90,000 请求长测、
错误计数和样本完整性全部通过。P50 在首轮和 repeat 中分别比 v8 高 `13.5135%` 和
`17.7606%`。由于 v8 使用不同 QEMU，`f5c61c734` 的后续 spec 修订将其降为跨 QEMU 历史
上下文；这组百分比不再作为正式 cleanup 回归 gate 或 cleanup 因果结论。

### 产物和原始证据 SHA-256

| 产物 | suite 1000 | 300 s | 300 s repeat |
|------|------------|-------|--------------|
| QEMU | `5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9` | 同 suite | 同 suite |
| rootfs | `6b8857a04392eaa96f78235281a45b687e6aada12cfe6d78f71c5e6a14e5af29` | 同 suite | 同 suite |
| Linux kernel | `d8127a4ce952ae9bfa539d3535260b8d67973b766e51a3de0b97b526bfd6722c` | 同 suite | 同 suite |
| initramfs source | `05cc23a827f791cd4d216aa32ac811634a8cb30ab096e1b99b5401bbff4144e6` | 同 suite | 同 suite |
| generated initramfs | `efcd9ab0a62561a6b30464fc0041bef51308a27022fc8071fa59a86dd21cafbb` | `d1929e8f97f163d2a59fe19ac53f70b5deb76c3363f320e009c9c4852870c89f` | `c79a063d9e8d15f4c9c7afffc507ef778e0dead64cc118c839533e7c8a129ec4` |
| Linux VM config | `4186d4992b919fbb3cd16824781ca5040a57083f9f3de0e069e12a124f07fb06` | 同 suite | 同 suite |
| RT-Thread VM config | `5daed0b71ab80f9d3dce51f548ef6a56b5936886163b1f47c4a96d6da47d9246` | 同 suite | 同 suite |
| RT-Thread image | `4da57282042e61869b61deed6cbc43100afa7b774bc3c9ccb47b7babc7d97a55` | `33a768ce68fa8396b13f3c83cda0d4c8456ee3dfb4b6a2b1ca06746ea1478c7a` | `df6033e433d5075bb9b206eda3a7f6d7c4ff04c256dd9374f55f9d7afd49325e` |
| AxVisor image | `ce75bdf6bbf20591afb0f087b7622b8ca2d1f9fc5d18bb2b4587334e45c20736` | `ba45baf5147a7361bd3cb50834cc83f2d58606c10e94a439459c2dc309310077` | `98b5c1198be2e4f2a40765462ef04315aac821b705a81904c173ba2591a45853` |

| 原始证据 | SHA-256 |
|----------|--------|
| `task12-cleanup-suite-1000.log` | `913cd4b2a3cd3471687d1b729cad4713234db5a43779a7011578809bf1b4ab26` |
| `task12-cleanup-suite-1000.log.qemu` | `4f48d7c4e611f369f893bd1dd5b43d148b213fb72b0cba3f3bc8387b7057ef97` |
| `task12-cleanup-suite-1000.log.artifacts` | `424185bed549c7762e75b23de171f7ecfd4628764f03da206a00bba9453f3cd4` |
| `task12-cleanup-suite-1000.log.timing` | `6da295daca0d71d428ef428fb971eff8b19be797800ff5ef0488040a78fdafcc` |
| `task12-cleanup-suite-1000-cpu.log` | `c9df0fb794b1bf1db6ed2ae63d77247aa8c9772658ad5d9f53c2573a0d75fbc4` |
| `task12-cleanup-300s.log` | `1bfbc97f8fa15384ea38d4c70920826e468167cff192aee064742a4c93948f61` |
| `task12-cleanup-300s.log.qemu` | `18729dee5a475028b1aade62105d56180759c1ffcb4d57aa46e26d97fdbd82fc` |
| `task12-cleanup-300s.log.artifacts` | `bd1c8ed6ff79142150ae8c462df52f7e31534f50ebc9da69c9a8ba2124efbb7e` |
| `task12-cleanup-300s.log.timing` | `2117f3ed7a938757b04db4fb56863df271418ba633df87396a34adf980928c7d` |
| `task12-cleanup-300s-cpu.log` | `fa3a632119120c65b490cae0cbd3dc15701f1f446717156f696942707a408e60` |
| `task12-cleanup-300s-repeat.log` | `d3fba76ea2c51d66409db03d601840949c3433cd27ef3fd76151157fca2ed450` |
| `task12-cleanup-300s-repeat.log.qemu` | `bed1c1ff19ee8d68228c1085075fe4ecfaf91ad4ab90aac6bf6da4fb9f0c81bd` |
| `task12-cleanup-300s-repeat.log.artifacts` | `3c9c3897828a3e25986db7e1f82b903696ad5ac148b566ac80db247ff397940f` |
| `task12-cleanup-300s-repeat.log.timing` | `9a242fce0a9c3a60d7f7d164d714b42c00efdfa9e2c891f1348c2a44af044710` |
| `task12-cleanup-300s-repeat-cpu.log` | `a13ee81d8a717a80f820d1b4de1ac7441334505565183a163ef3d62010c723de` |

原始证据均位于 `docs/docs/build/axvisor/`，各轮 `.artifacts` 保留实际输入路径和
image hash，`.timing` 保留 monotonic/epoch 起止时间，`.qemu` 保留完整 QEMU 输出，
CPU 日志保留逐秒线程分布。

## QEMU 基线可证伪实验

### 实验设计与命令

为检验清理后两轮 P50 `9.408/9.760 us` 是否由 QEMU 基线差异引起，本轮保持 cleanup
当前源码、`RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup`、请求量、300 s stability、
`concurrent` 启动和 `uclamp.min=1024` 不变，唯一有意改变的运行变量是 QEMU 二进制。
runner 会 fresh rebuild RT-Thread、initramfs 和 AxVisor，因此下文完整保留本轮 image hash；
这些可重建 image 并不与前两轮逐字节相同，但使用相同源码和构建入口。

运行前 `pgrep -a -f '[q]emu-system-aarch64'` 无匹配并以 1 退出，未终止任何外部 QEMU。
诊断 QEMU 为 `QEMU emulator version 11.0.2`，先校验 SHA-256 为
`98e36db59ef04d96a88d8959f61f7336dcffd8fbd8a5267c7dfedc1953ebc95a` 后执行：

```bash
env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/task12-cleanup-qemu-ab-diag-300s.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/task12-cleanup-qemu-ab-diag-300s-cpu.log \
  QEMU=/tmp/qemu-rtthread-diag.ytbnqM/build/qemu-system-aarch64 \
  RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
  /usr/bin/time -f 'TASK12_QEMU_AB_WALL=%e TASK12_QEMU_AB_EXIT=%x' \
  bash os/axvisor/scripts/run_rtipc_test.sh
```

墙钟耗时 `491.03 s`，benchmark host timing 为 `301.617915 s`。QEMU/run-until 因总
completion deadline 到达返回 `124`，Linux client 未产生
`RT-IPC client exited with rc=...` marker，故其独立退出码不可观测；runner 总退出码为 1。
RT-Thread 的稳定性 marker 为 `FAIL`，但 `299999/299999` 样本完整；失败条件是
`miss_1ms=2`（对应 `max=1.429392 ms`）。这些退出状态与下面的完整性能样本、未完整收尾的
RT-IPC 功能结果分别判读。

### 功能、RTT 与 CPU 结果

Linux 输出 `LINUX_SMP_READY configured=2 online=0-1 nproc=2`，RT-Thread 输出
`lwIP-2.1.2 initialized!` 并启动 server。64 B 和 256 B 各完成 `30000/30000`；1024 B
在 deadline 前最后可观测进度为 `24399/24399`，没有最终 payload 汇总，故全轮只能确认至少
`84399/90000`，不能判为端到端功能 PASS。已完成档的 request timeout、protocol error 均为
0；最后进度累计 transport `retrans=5 timeouts=0 dup=2 reorder=0 errors=0`。由于 client 未正常
收尾，1024 B 的最终 application error、RTT 和 throughput 不可获得。

| payload | 完成度 | RTT min/avg/max | P50/P95/P99/P99.9 | throughput | request/protocol error |
|--------:|-------:|-----------------|--------------------|-----------:|-----------------------:|
| 64 B | 30000/30000 | 0/5/951 ms | 3/24/24/30 ms | 11.63 KiB/s | 0/0 |
| 256 B | 30000/30000 | 0/5/1579 ms | 3/24/24/28 ms | 40.96 KiB/s | 0/0 |
| 1024 B | 最后可见 24399/24399 | 未产生最终汇总 | 未产生最终汇总 | 未产生最终汇总 | 最终值不可获得 |

CPU 日志包含 480 个一秒样本：QEMU 总 `%CPU` 平均 `195.07%`（范围 `103-200%`）；
TCG0/1/2/3 平均分别为 `94.40%`、`0.59%`、`98.83%`、`0.00%`，范围分别为
`80-100%`、`0-2%`、`0-101%`、`0-0%`。

### 性能结果与假设判定

stability jitter 和 callback 均为 `expected=299999 collected=299999 missing=0`：

| metric | P50 | P95 | P99 | P99.9 | max | miss_1ms |
|--------|----:|----:|----:|------:|----:|---------:|
| stability jitter | 6.272 us | 246.784 us | 298.272 us | 359.760 us | 1.429392 ms | 2 |
| callback exec | 0.480 us | 0.688 us | 1.056 us | 4.704 us | 157.504 us | 0 |

| jitter 指标 | v8 | 普通 QEMU 首轮 | 普通 QEMU repeat | 诊断 QEMU | 诊断相对 v8 |
|-------------|---:|----------------:|-----------------:|----------:|------------:|
| P50 | 8.288 us | 9.408 us | 9.760 us | 6.272 us | -24.3243% |
| P95 | 241.328 us | 254.048 us | 259.728 us | 246.784 us | +2.2608% |
| P99 | 293.712 us | 315.104 us | 316.976 us | 298.272 us | +1.5525% |
| P99.9 | 362.144 us | 443.808 us | 422.288 us | 359.760 us | -0.6583% |
| max | 1.193376 ms | 0.997136 ms | 0.869632 ms | 1.429392 ms | +19.7772% |
| miss_1ms | 2 | 0 | 0 | 2 | 0% |

普通 QEMU 两轮 P50 自身差值为 `0.352 us`。诊断 QEMU 的 P50 比首轮低 `3.136 us`
（`-33.3333%`，为该差值的 8.91 倍），比 repeat 低 `3.488 us`（`-35.7377%`，为该差值的
9.91 倍），因此不满足“与 cleanup 两轮差异小于 `0.352 us`”的证伪条件。它没有精确落在
`8.288 us` 附近，而是越过 v8 基线降至 `6.272 us`；但方向和效应量均显著，且 P95/P99
也回到 v8 的 `+2.2608%/+1.5525%`。因此该跨 QEMU 证据表明 **QEMU 二进制是影响 P50 的
重要变量**；它本身不建立 cleanup 的因果回归结论。

该诊断 QEMU 只用于性能根因归因，**不是生产优化，也不是产品交付依赖**。本轮 RT-IPC
第三档因总 deadline 未完成，不能替代前两轮普通 QEMU 的完整功能验收；同时单轮诊断结果
不能证明具体某一项 QEMU patch 是根因，若要继续细分需在同一诊断构建链上做 patch 二分。

### 产物与原始证据

| runtime artifact | SHA-256 |
|------------------|--------|
| diagnostic QEMU | `98e36db59ef04d96a88d8959f61f7336dcffd8fbd8a5267c7dfedc1953ebc95a` |
| rootfs | `6b8857a04392eaa96f78235281a45b687e6aada12cfe6d78f71c5e6a14e5af29` |
| Linux kernel | `d8127a4ce952ae9bfa539d3535260b8d67973b766e51a3de0b97b526bfd6722c` |
| initramfs source | `05cc23a827f791cd4d216aa32ac811634a8cb30ab096e1b99b5401bbff4144e6` |
| generated initramfs | `6767b77664e99193797654129e491e8f883d1be8ea9c0d478e1378eba076e1f0` |
| Linux VM config | `4186d4992b919fbb3cd16824781ca5040a57083f9f3de0e069e12a124f07fb06` |
| RT-Thread VM config | `5daed0b71ab80f9d3dce51f548ef6a56b5936886163b1f47c4a96d6da47d9246` |
| RT-Thread image | `4aff46640e4d42c84632dc8a27bda5bb3cb3221294e2c6369a1da303b1ecdeff` |
| AxVisor image | `2aea59a493f76e6cc4f1bf96df938fbeca57c1bdb3521b57fc4c5cd192312b8c` |

| 原始证据 | SHA-256 |
|----------|--------|
| `task12-cleanup-qemu-ab-diag-300s.log` | `818a0f1aaf17368af14f1003003ba34a723c5efec60b0029a94ff7df96b9212d` |
| `task12-cleanup-qemu-ab-diag-300s.log.qemu` | `5a743241b882f1de679a66c46245db33a80782efaea89fb29e87f3e2d73e2678` |
| `task12-cleanup-qemu-ab-diag-300s.log.artifacts` | `7b8c3284c4a3543f17fd49c0b66b3579ce0ff7f1df2a62706f67fe504dbf9176` |
| `task12-cleanup-qemu-ab-diag-300s.log.timing` | `00aff587df905204a7225f490b54352499550640c1d9a8f63e96d6d889b53171` |
| `task12-cleanup-qemu-ab-diag-300s-cpu.log` | `3e34c417c23754a3e37bd06a3058cdeae140df743b2997f34447f19085b4483e` |

以上证据均位于 `docs/docs/build/axvisor/`。`.artifacts` 保留每个实际输入路径和 hash，
`.timing` 保留 benchmark monotonic/epoch 起止时间，`.qemu` 保留诊断探针和终止原因，CPU
日志保留逐秒总进程与线程分布。

## 同 QEMU 清理前重构控制实验

### 控制变量与临时诊断

为区分 P50 变化来自 cleanup 重构还是 QEMU 二进制，本轮使用与 cleanup 两轮完全相同的
普通 QEMU（SHA-256
`5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9`）、
`RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup`、`RTIPC_COUNT=30000`、300 s stability、
`concurrent` 和 `uclamp.min=1024`，只在测试期间恢复清理前的诊断开销：

- `virtio_net.rs` 临时恢复设备 id/MMIO/IRQ 分配 debug、TX/drop 原子累计器及 drop total、
  RX no-buffer 原子累计和首个/每 1000 次 warning；deferred-ingress 行为和现有测试断言不变。
- `init-linux-1` 临时恢复启动和网络 ready 后的 `ifconfig`，以及 RT-IPC 前后
  `/proc/net/snmp`、客户端后的 `ifconfig eth0` 和 `/proc/net/udp` dump；客户端退出码通过
  `client_rc` 保持不被诊断命令覆盖。

这是重构清理前诊断的 **test-only control**。没有把这些诊断作为产品改动交付；实验退出后
第一时间用反向 `apply_patch` 全部移除，未使用 `git checkout` 或 `git reset`。

| 文件 | 实验前 SHA-256 | 临时诊断 SHA-256 | 恢复后 SHA-256 | 恢复 |
|------|----------------|-------------------|-----------------|------|
| `os/axvisor/src/virtio_net.rs` | `63af03a44476a19eba667ae26e4d4e28b2c16fb4b7ed141b37a5b4040385745a` | `9bfaa19f8c02f70f149dffba5546b8783f8a1ddf0e45dd7ee5efa288e6d678f6` | `63af03a44476a19eba667ae26e4d4e28b2c16fb4b7ed141b37a5b4040385745a` | PASS，逐字节一致 |
| `os/axvisor/guests/linux-net/init-linux-1` | `706b14b03f4ea46d5d67e1cb0a9f2ca3c91268138fff9494f96177d76cb6b200` | `52d2cacf5fe8eacc48f8b90d5627d41f5d9dda40ff8649c2e285a76ada15707d` | `706b14b03f4ea46d5d67e1cb0a9f2ca3c91268138fff9494f96177d76cb6b200` | PASS，逐字节一致 |

临时状态 `cargo fmt --all -- --check` 退出 0。恢复后再次执行同一格式检查和
`git diff --check`，均退出 0；随后执行：

```bash
cargo xtask ktest qemu -p axvisor --test axtest --arch aarch64
```

结果为 `AXTEST_SUMMARY pass=83 fail=0 skip=0 total=83`、`AXTEST_SUITE_OK`，退出 0。
实验前和恢复后启动 QEMU 前的 `pgrep -a -f '[q]emu-system-aarch64'` 均无匹配，未终止任何
外部 QEMU。

### 精确命令与退出状态

```bash
env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/task12-precleanup-control-300s.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/task12-precleanup-control-300s-cpu.log \
  QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  RTTHREAD_SRC=tmp/rt-thread-5.2.2-cleanup \
  /usr/bin/time -f 'TASK12_PRECLEANUP_CONTROL_WALL=%e TASK12_PRECLEANUP_CONTROL_EXIT=%x' \
  bash os/axvisor/scripts/run_rtipc_test.sh
```

墙钟耗时 `433.90 s`，benchmark host timing 为 `301.698249 s`。QEMU 退出 0，Linux client
退出 0；runner 因 stability 严格门禁退出 1。门禁失败来自 `miss_1ms=3`，不是样本缺失或
功能失败。

### 功能、RTT 与 CPU

控制轮主日志没有再次捕获 `LINUX_SMP_READY` marker，因此 Linux 2-vCPU 证明明确来自
cleanup suite、300 s 首轮和 repeat 的 PASS 日志，而不是本 control 日志；control 使用与
这些 cleanup PASS 轮相同的 Linux VM config hash。cleanup 日志直接记录
`online=0-1 nproc=2`。RT-Thread 输出 `lwIP-2.1.2 initialized!`。64/256/1024 B 各完成
`30000/30000`，合计 `90000/90000`；
`ALL TESTS COMPLETE` 和 `RT-IPC client exited with rc=0` 均存在。三档均为
`request_timeouts=0 protocol_errors=0`，transport timeout/error 均为 0；1024 B 有 3 次
retrans 并完成恢复，应用结果仍为 PASS。

| payload | RTT min/avg/max | P50/P95/P99/P99.9 | throughput | transport retrans/dup |
|--------:|-----------------|--------------------|-----------:|---------------------:|
| 64 B | 0/4/40 ms | 3/23/24/29 ms | 11.85 KiB/s | 0/0 |
| 256 B | 0/4/113 ms | 3/23/24/29 ms | 57.30 KiB/s | 0/0 |
| 1024 B | 0/3/1656 ms | 2/13/24/27 ms | 249.99 KiB/s | 3/0 |

CPU 日志有 423 个一秒样本：QEMU 总 `%CPU` 平均 `195.25%`（范围 `104-201%`）；
TCG0/1/2/3 平均分别为 `94.48%`、`0.58%`、`98.77%`、`0.00%`，范围分别为
`79-99%`、`0-2%`、`2-101%`、`0-0%`。

### 性能与同 QEMU 归因

stability jitter 和 callback 均为 `expected=299999 collected=299999 missing=0`：

| metric | P50 | P95 | P99 | P99.9 | max | miss_1ms |
|--------|----:|----:|----:|------:|----:|---------:|
| stability jitter | 10.256 us | 258.096 us | 323.952 us | 396.704 us | 2.716144 ms | 3 |
| callback exec | 0.528 us | 0.800 us | 3.072 us | 10.352 us | 187.760 us | 0 |

| jitter 指标 | 清理前诊断控制 | cleanup 首轮 | 首轮相对控制 | cleanup repeat | repeat 相对控制 |
|-------------|---------------:|-------------:|---------------:|---------------:|------------------:|
| P50 | 10.256 us | 9.408 us | **-8.2683%** | 9.760 us | **-4.8362%** |
| P95 | 258.096 us | 254.048 us | -1.5684% | 259.728 us | +0.6323% |
| P99 | 323.952 us | 315.104 us | -2.7313% | 316.976 us | -2.1534% |
| P99.9 | 396.704 us | 443.808 us | +11.8738% | 422.288 us | +6.4491% |
| max | 2.716144 ms | 0.997136 ms | -63.2885% | 0.869632 ms | -67.9828% |
| miss_1ms | 3 | 0 | -3 | 0 | -3 |

预设归因规则要求：只有清理前诊断控制的 P50 显著低于 cleanup 两轮，才能把回归归因于
cleanup。实测 cleanup 首轮 P50 比控制低 `0.848 us`（`-8.2683%`），repeat 比控制低
`0.496 us`（`-4.8362%`），因此**未观察到 cleanup 性能回归**；去除诊断后两轮 P50 均略有改善。
相对 v8 的两轮 `+13.5135%/+17.7606%` 仍是有效观测，但不能据此归因于调试代码清理。

前一节跨 QEMU 实验继续保留：诊断 QEMU 的 P50 为 `6.272 us`，相对普通 QEMU cleanup
两轮下降 `33.3333%/35.7377%`。该跨 QEMU 证据表明 QEMU 二进制是重要变量；同 QEMU
控制只支持“未观察到 cleanup 回归”，两组证据都不足以进一步指定某个 QEMU patch 或宿主
机制为唯一根因。诊断 QEMU 仍只用于归因，不是生产优化或交付依赖。

**更新后的最终结论：功能 PASS，未观察到 cleanup 性能退化。** 普通 QEMU 下恢复清理前
诊断并没有恢复到更低 P50，而是得到更高的 `10.256 us`；两个临时修改文件已逐字节恢复，
恢复后的格式、diff 和 83 项 aarch64 axtest 全部通过，产品工作树没有交付临时诊断。

### 产物与原始证据

| runtime artifact | SHA-256 |
|------------------|--------|
| QEMU | `5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9` |
| rootfs | `6b8857a04392eaa96f78235281a45b687e6aada12cfe6d78f71c5e6a14e5af29` |
| Linux kernel | `d8127a4ce952ae9bfa539d3535260b8d67973b766e51a3de0b97b526bfd6722c` |
| initramfs source | `05cc23a827f791cd4d216aa32ac811634a8cb30ab096e1b99b5401bbff4144e6` |
| generated initramfs | `caca06e7e733ba8aaedd33fccfda3dfadbfe724ac85d7a06f97a432a6710d5ee` |
| Linux VM config | `4186d4992b919fbb3cd16824781ca5040a57083f9f3de0e069e12a124f07fb06` |
| RT-Thread VM config | `5daed0b71ab80f9d3dce51f548ef6a56b5936886163b1f47c4a96d6da47d9246` |
| RT-Thread image | `cff8c4c260793e4a28771406a99f8afc5755e19e7c9da0f2cc63467d63ff3ffa` |
| AxVisor image | `05402d256aa8717a1361ce8cf8f552dd5b6613cd9da85198877da59eb03701bc` |

| 原始证据 | SHA-256 |
|----------|--------|
| `task12-precleanup-control-300s.log` | `9acdaecebbcb7ebed4ea65cdfeb3e33fc8b67c357fdb11861cf5386d5007fcbd` |
| `task12-precleanup-control-300s.log.qemu` | `ffa8aa14e4a42a7387f55e52bd5fbcfe08e30314a523f32e69e1c5d46b7f6f7b` |
| `task12-precleanup-control-300s.log.artifacts` | `bca01504c63eef064e3b21345d02259d7007df04fab1122060457b216dd40f52` |
| `task12-precleanup-control-300s.log.timing` | `22f59f104aebd4aac7807ac26c8aca86e55e13f2e2633a38fa0fd5111c0d0186` |
| `task12-precleanup-control-300s-cpu.log` | `b006d7c83776f932688034ce0211527dc4701f72d9ed4ffc7094d5fa6b0bca85` |

原始证据均位于 `docs/docs/build/axvisor/`；`.artifacts` 记录实际输入路径和 image hash，
`.timing` 记录 benchmark 时钟区间，`.qemu` 保留 QEMU 启停信息，CPU 日志保留逐秒分布。

## 2026-08-17 Task 1 关键路径质量迭代

本轮在独立 worktree 的 `feat/axvisor-task123` 分支完成以下改造：

- AxVisor virtio-net RX 增加事件资格位。没有 ingress notification 或有效 RX queue kick 时，
  vCPU 常规 run-loop 的 DMA poll 立即返回，不再反复访问 guest RX ring；no-buffer、处理中
  kick 和重复 kick 状态机保持不变。
- RT-Thread source preparation 对 pinned commit 之外，再拒绝 staged、unstaged 和 untracked
  内容；失败时不重置、不清理、不替换已有目录。
- `0000`、`0002` 到 `0008` 只通过完整 forward/reverse `git apply --check` 判定状态；
  partially-applied 或漂移状态 fail-closed。已删除格式损坏且与 `0000` 重复的历史 `0001`
  polling/debug cleanup patch。
- AArch64 virtual timer ISR 删除两个按 missed ticks 增长的循环。它使用 wrap-safe signed
  counter delta 算术计算 elapsed ticks，单次推进绝对 deadline，并通过
  `rt_tick_increase_tick` 批量记账。单次 tick 跳变限制为 `< RT_TICK_MAX/2`；超界暂停会
  饱和记账并把硬件 deadline 重同步到 `now + timer_step`，避免截断和中断追赶风暴。

本轮验证结果：

| 验证 | 结果 |
|------|------|
| AxVisor AArch64 axtest | `84 passed, 0 failed` |
| `cargo test -p axvirtio-net` | `31 passed, 0 failed` |
| RT-Thread clean-source contract | PASS，覆盖 clean/tracked/staged/untracked |
| exact patch helper | PASS，覆盖 pristine/idempotent/two-hunk partial/apply failure |
| fresh pinned patchset，连续 apply 两次 | PASS |
| fresh RT-Thread 5.2.2 AArch64 SCons build | PASS，生成 `rtthread.elf`/`rtthread.bin` |

这轮尚未执行整机 suite、300 秒稳定性和同 QEMU A/B，因此没有新增 jitter、最大延迟或
网络 RTT 数字，也不能据此宣称运行时性能无退化。`rt_tick_increase_tick` 已消除按 missed
ticks 重复调用内核的循环，但它仍按 RT-Thread 原生语义执行一次 expired-timer 扫描并调用
到期 hard-timer callback；其 WCET 仍受同一时刻到期 timer 数量和 callback 实现影响。最终
性能结论必须以后续 integrated 300 秒/长时测试数据为准。
