# AxVisor 任务一、任务二、任务三实现与性能汇总

> 汇总范围：`history-docs/task12` 与 `history-docs/task123`
>
> 汇总日期：2026-08-19
>
> 证据优先级：最终 AxVisor 集成报告 > 专项性能报告 > 原始运行日志和故障证据

## 1. 总体结论

当前最终方案是一个 AxVisor 实例启动一个 2-vCPU Linux 客户机和一个 1-vCPU
RT-Thread 客户机。Linux 负责 AI 推理和网络客户端，RT-Thread 负责实时基准、网络
服务和控制器。两个客户机之间的应用数据全部通过 virtio-net、IPv4、UDP 和 RT-IPC
传输，不使用共享内存、HyperCall、裸 MMIO 或 vsock 作为主数据通道。

| 任务 | 功能实现度 | 性能/验收状态 | 结论 |
|---|---:|---|---|
| 任务一：实时性改造与验证 | **95%** | 有条件通过 | 实时路径、2-vCPU Linux、RTOS 独占 CPU、基线和完整采样已完成；普通 Ubuntu + QEMU TCG 的严格 1 ms 长稳门禁仍有离群值 |
| 任务二：客户机间通信 | **100%** | **PASS** | virtio-net/IP/UDP/RT-IPC 双向通信、可靠性、重连和长时间请求测试均完成 |
| 任务三：AI 模型与控制联动 | **100%** | **PASS** | AI 推理、网络控制、RTOS 执行器、状态回传、固定参数对比和故障注入均完成 |

这里的百分比表示需求、实现和可复现证据的覆盖程度，不代表 QEMU TCG 已经提供硬实时
保证。任务一的 95% 主要扣减项是严格长时间测试中的最坏延迟门禁，而不是功能缺失。

最终集成主报告：

- [任务一/二/三集成测试报告](task123/report/2026-08-17/starryos-replace/docs/docs/build/axvisor/task123-test-report.md)
- [RT-Thread 实时性专项报告](task12/report/2026-08-18/tgoskits/docs/docs/build/axvisor/rtthread-realtime-report.md)
- [任务三 AI 控制报告](task123/report/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/task3-report.md)
- [RT-Thread A/B/C 指标补足与基线报告（2026-08-20）](task123/report/2026-08-20/tgoskits/rt-thread-realtime-baseline-suite-20260820-report.md)

## 2. 共同平台和拓扑

| 项目 | 配置 |
|---|---|
| 外层平台 | QEMU 11.0.2 TCG，AArch64 `virt`，Cortex-A72，4 个外层 vCPU |
| Linux 客户机 | 2 vCPU，512 MiB，`192.168.77.11/24` |
| RT-Thread 客户机 | 1 vCPU，256 MiB，`192.168.77.30/24` |
| Linux CPU 策略 | vCPU 可在非实时 pCPU 集合 `{0,1,3}` 中调度，不固定到单一 pCPU |
| RT-Thread CPU 策略 | vCPU 固定到 pCPU 2，CPU 集合为 `0b0100` |
| Linux 内存 | `0x80000000` 起，512 MiB，入口约为 `0x80200000` |
| RT-Thread 内存 | `0xa0000000` 起，256 MiB，入口为 `0xa0000000` |
| Task 2 端口 | UDP `9876` |
| Task 3 端口 | UDP `9877` |
| 网络设备 | AxVisor virtio-net，经内部 L2 switch 转发 |
| 中断路径 | 网络事件唤醒目标 vCPU，virtqueue 进度处理后通过 VGIC 注入虚拟 SPI |

报告中出现两组 MAC 地址：`34:54:00:4d:00:01/03` 是一轮 AxVisor 客户机设备配置，
`52:54:00:77:00:01/03` 是另一轮 QEMU hub/backend 配置。两者属于不同运行轮次，不能
混写为同一轮的配置；IP、端口和 virtio-net 主通道保持一致。

网络和 RT-IPC 设计来源：

- [三客户机网络设计](task12/design/2026-08-01/tgoskits/docs/superpowers/specs/2026-08-01-axvisor-three-guest-network-design.md)
- [virtio-net 设备设计](task12/design/2026-08-10/tgoskits/docs/design/axvisor-virtio-net.md)
- [RT-IPC 集成设计](task12/design/2026-08-11/tgoskits/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md)
- [任务三 RT-IPC/UDP 协议规范](task123/spec/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/protocol.md)

## 3. 任务一：实时性改造与验证

### 3.1 已实现功能

任务一完成了以下 AxVisor 实时性改造和验证基础：

1. Linux 使用 2 个 vCPU；两个 vCPU 允许在非实时 CPU 集合内抢占和迁移。
2. RT-Thread 使用 1 个 vCPU，并静态固定到 pCPU 2，避免 Linux vCPU 与 RTOS 争用实时核心。
3. RT-Thread 使用 `busy WFI` 策略；对 trapped WFI 增加 AArch64 快速返回路径，减少完整
   world switch、外层 `yield_now()` 和 guest timer 状态切换带来的延迟。
4. RT-Thread 周期基准使用 hard timer，generic timer 使用绝对 `CNTV_CVAL` deadline，并
   对跨周期情况进行补偿，降低累计漂移。
5. Linux 的 TLBI 广播限制在 Linux 自己的 pCPU 集合，不影响 RT-Thread pCPU 2。
6. 虚拟 GIC、SPI 路由、vCPU 唤醒和 virtio-net 中断使用事件驱动的注入路径，不依赖周期轮询。
7. 采集周期任务抖动、抢占延迟、SGI/中断响应延迟、最大值、分位数、缺失样本和 CPU 负载。
8. 提供原生 RT-Thread 基线，用于分离 RT-Thread 本身和 AxVisor 虚拟化带来的额外开销。

### 3.2 实时性性能结果

1000 样本综合测试结果如下。所有项目均为 `expected=1000 collected=1000 missing=0`，
并且 `miss_1ms=0`。

| 指标 | P50 | P95 | P99 | P99.9 | 最大值 | 大于 1 ms |
|---|---:|---:|---:|---:|---:|---:|
| 1 ms timer jitter，run 1 | 5.456 us | 36.592 us | 68.208 us | 463.520 us | 464.912 us | 0 |
| 1 ms timer jitter，run 2 | 5.872 us | 34.288 us | 50.912 us | 246.448 us | 301.456 us | 0 |
| 1 ms timer jitter，run 3 | 6.240 us | 42.832 us | 249.200 us | 327.920 us | 349.664 us | 0 |
| 抢占延迟 | 4.448 us | 5.120 us | 7.296 us | 670.288 us | 698.016 us | 0 |
| SGI/虚拟中断响应 | 76.800 us | 86.784 us | 172.368 us | 266.704 us | 270.000 us | 0 |

SGI 指标从写 GIC redistributor pending 开始，到 RT-Thread ISR 读取 architectural counter
结束，因此包含虚拟 GIC 陷入、VGIC 注入和 guest ISR 入口，不是单纯函数调用时间。

### 3.3 长时间稳定性

严格门禁要求 1 ms 周期任务在完整测试窗口中没有超过 1 ms 的样本。最终集成报告中的
四轮 300 秒测试均完成 `299999/299999` 样本，但仍出现长尾：

| 轮次 | 最大 jitter | 大于 1 ms 样本 | 状态 |
|---|---:|---:|---|
| 300 s run 1 | 3.636208 ms | 14 | FAIL |
| 300 s run 2 | 2.722352 ms | 4 | FAIL |
| 300 s run 3 | 5.406368 ms | 29 | FAIL |
| 300 s run 4 | 2.353616 ms | 2 | FAIL |

另一轮优化后的 300 秒记录曾达到最大 `997.808 us`、`miss_1ms=0`，但后续重复轮出现
`1.107280 ms`、`1.512640 ms` 和 Busy-WFI 快速路径 `1.193376 ms` 的离群值。因此不能
用单轮 PASS 覆盖重复测试中的 FAIL。

这里的长尾需要结合测试平台解释：本轮是在 x86_64 宿主上使用 QEMU TCG 仿真
AArch64 `virt` 平台，RT-Thread 的虚拟 generic timer 需要经过 QEMU main loop 的 timer
callback、TCG vCPU 线程调度以及 QEMU 向虚拟 GIC/PPI 的投递。上述任一宿主侧边界都可能
产生毫秒级离群值，因此当前数据中的长尾主要是 QEMU TCG 仿真的影响，而不是 RT-Thread
周期任务或 guest ISR 内部持续执行过久。

根因分析表明，短延迟路径已经明显改善，剩余长尾主要发生在 QEMU TCG main-loop timer
assert、TCG vCPU 线程调度和普通宿主调度边界；不是 guest ISR 入口内部的长时间执行。
因此当前结果可以说明 AxVisor 关键路径已优化，但不能在 x86_64 宿主 + AArch64 TCG
环境上证明硬实时 WCET。

### 3.4 原生 RT-Thread 基线

同一 QEMU virt/GICv3/Cortex-A72 平台直接启动 RT-Thread 的 300 秒基线：

| 指标 | 原生 RT-Thread | AxVisor 历史最佳严格 PASS 轮 |
|---|---:|---:|
| P50 | 8.432 us | 64.560 us |
| P95 | 16.640 us | 288.000 us |
| P99 | 27.456 us | 373.872 us |
| P99.9 | 57.728 us | 457.440 us |
| 最大值 | 692.672 us | 997.808 us |
| 大于 1 ms | 0 | 0 |

基线用于衡量虚拟化附加开销，不是物理 ARM 裸机结果。虚拟化额外成本包括二级地址转换、
VM exit/entry、虚拟 GIC 和 QEMU TCG 调度。

### 3.5 任务一实现路径

任务一经历了“架构设计 -> RTOS 替换 -> 调度/定时器优化 -> 中断和网络事件验证 ->
短测和长测复验”的路径：

1. 初期设计是两个 Linux 加一个 Zephyr，先验证三客户机 virtio-net 拓扑；随后根据项目
   需求将 RTOS 基线替换为 RT-Thread。
2. 通过 `HostVcpuIdlePolicy` 和 RTOS 专用 CPU 集合确定静态实时分区：RT-Thread 固定
   pCPU 2，Linux 保持自由抢占。
3. 在 AxVisor 调度、vCPU idle、timer、VGIC、TLBI、FDT 和 virtio-net 路径中加入实时性
   改造；实现路径主要位于 `os/axvisor/src/`、`os/arceos/modules/axtask/` 和 VM 配置目录。
4. 在 `os/axvisor/guests/rt-benchmark/` 增加 RTOS 周期、抢占和中断基准，并使用
   `os/axvisor/scripts/` 下的 runner 和验证脚本采集结果。
5. 通过 1000 样本 suite、10/30 秒控制轮、300 秒稳定性轮和原生 RT-Thread 基线逐步验证。

设计和证据：

- [Busy-WFI 实时优化设计](task12/design/2026-08-03/tgoskits/docs/superpowers/specs/2026-08-03-axvisor-rtos-busy-wfi-design.md)
- [任务一/二实施计划](task12/plan/2026-08-15/tgoskits/docs/superpowers/plans/2026-08-15-task1-task2-implementation.md)
- [实时性报告](task12/report/2026-08-18/tgoskits/docs/docs/build/axvisor/rtthread-realtime-report.md)
- [原始 task1/task12 CPU 日志](task12/evidence/2026-08-15/tgoskits-untracked-logs/docs/docs/build/axvisor/task1-2026-08-15-rtbench-suite-1000-pass-cpu.log)

## 4. 任务二：客户机间网络通信

### 4.1 已实现功能

任务二建立了 Linux 和 RT-Thread 之间的双向应用链路：

```text
Linux 192.168.77.11
  UDP/9876 + RT-IPC v2 client
          |
  AxVisor virtio-net + internal L2 switch
          |
RT-Thread 192.168.77.30
  UDP/9876 + RT-IPC v2 server
```

RT-IPC v2 头部包含版本、消息类型、payload 长度、序号、session ID、错误码和 CRC16。
可靠性机制包括：

- 累计 ACK、50 ms RTO、最多 5 次重传；
- UDP 消息分帧、会话建立、heartbeat、FIN 和自动重连；
- 乱序包等待窗口重传，旧序号只重新 ACK，不重复交付；
- frame/session 双层去重和幂等处理；
- CRC、版本、长度、枚举和 reserved 字段校验；
- 断连、超时、非法包和错误通知的应用层恢复。

主要路径为 `os/axvisor/guests/rt-ipc/common/`、`linux/`、`rtthread/`，以及
`os/axvisor/src/virtio_net.rs`、`os/axvisor/scripts/run_rtipc_test.sh` 和 RT-Thread
patch/验证脚本。

### 4.2 网络性能和可靠性结果

当前 HEAD 的 1000 请求测试：

| payload | 发送/接收 | RTT 平均/P95/最大 | 有效吞吐量 | 超时/协议错误 |
|---:|---:|---:|---:|---:|
| 64 B | 1000/1000 | 3/4/30 ms | 17.26 KiB/s | 0/0 |
| 256 B | 1000/1000 | 1/3/11 ms | 108.55 KiB/s | 0/0 |
| 1024 B | 1000/1000 | 2/3/31 ms | 359.07 KiB/s | 0/0 |

64 B 测试在第 500 个请求主动断连，恢复耗时 221 ms，重连后未丢请求。四轮 300 秒
实时性并发测试同时完成 `90000/90000` 网络请求。

3600 秒 Linux/StarryOS 对比测试中，三种 payload 均完成 `240000/240000`，应用超时、
协议错误、乱序、重复包和传输错误均为 0。StarryOS 相比 Linux 的平均 RTT 约高 200%，
吞吐量约低 64.5%，这是客户机网络/调度路径对比，不表示 RT-Thread 网络服务失败。

### 4.3 任务二实现路径

1. 先完成 virtio-net 设备模型、guest memory 访问范围和中断投递设计。
2. 在 RT-Thread 中启用 SAL/socket/lwIP 和 virtio-net；Linux initramfs 中加入静态编译
   的 RT-IPC 客户端。
3. 共享 C 协议核心，让 Linux 和 RT-Thread 使用相同的编码、CRC、ACK 和序号规则。
4. 先通过协议单元和 loopback 测试，再进行真实 QEMU 双客户机测试。
5. 增加丢包、重复、乱序、stale ACK、heartbeat、FIN、重连和网络并发长测。

设计和证据：

- [RT-IPC 集成设计](task12/design/2026-08-11/tgoskits/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md)
- [RT-IPC 与任务一/二实施计划](task12/plan/2026-08-15/tgoskits/docs/superpowers/plans/2026-08-15-task1-task2-implementation.md)
- [可靠性证据日志](task12/evidence/2026-08-15/tgoskits/docs/docs/build/axvisor/task2-2026-08-15-rtipc-reliability-faults-pass.log)
- [长时网络证据日志](task12/evidence/2026-08-16/tgoskits-untracked-logs/docs/docs/build/axvisor/task2-2026-08-16-fin-multipeer-1000.log)

## 5. 任务三：AI 模型与控制联动

### 5.1 已实现功能

任务三在任务二的 UDP/RT-IPC v2 链路上增加了 AI 控制闭环：

```text
Linux 输入帧
  -> int8 CNN 推理
  -> CTRL_CMD / UDP 9877 / RT-IPC v2
  -> RT-Thread 控制器
  -> 虚拟 PWM/执行器状态更新
  -> STATUS_REP 回传 Linux
```

Linux 同时执行输入解码、模型推理、分类结果编码和网络客户端；RT-Thread 解析
`CTRL_CMD`，根据 FIXED 或 AI 模式更新虚拟 PWM/位置执行器，并返回处理时间、frame ID、
应用类别和状态。协议使用 `frame_id` 与时间戳关联请求和回复，重复 frame 返回缓存结果，
不会重复施加控制动作。

任务三应用协议定义了 `CTRL_CMD`、`STATUS_REP`、`ERROR_NOTIFY`、`ACK`、`SYN`、`SYNACK`、
`HEARTBEAT`、`HEARTBEAT_ACK` 和 `FIN` 等消息类型，固定载荷包含 schema version、命令、
模式、类别、置信度、序号、时间戳和错误字段。

### 5.2 AI 和闭环性能结果

正常场景使用相同输入序列运行 600 个 FIXED 帧和 600 个 AI 帧：

| 指标 | 结果 |
|---|---:|
| 控制请求成功 | 1200/1200，100% |
| 应用错误/超时 | 0/0 |
| 传输重试/重复请求/重连 | 0/0/0 |
| 模型分类准确率 | 593/600，98.8333% |
| CNN 推理 mean/P95/P99/max | 607/903/1042/1520 us |
| Linux 同侧请求 RTT mean/P95/P99/max | 6142/30784/30954/31522 us |
| RT-Thread 处理 mean/P95/P99/max | 95/267/289/320 us |
| 固定参数 tracking MAE | 9809 |
| AI tracking MAE | 6065 |
| AI 相对固定参数误差改善 | 38.17% |
| 有效应用 payload | 240 B/s |

任务门禁要求成功率至少 99.5%、分类准确率至少 95%、跟踪误差改善至少 30%，三项均通过。
稳定时间没有形成有效结论：FIXED 和 AI 都检测到 20 次方向变化，但在测试窗口内满足
连续稳定阈值的事件数为 0，因此不能把稳定时间写成 0 或宣称 AI 在该指标上优于固定参数。

### 5.3 故障恢复结果

| 故障场景 | 预期 | 结果 |
|---|---|---|
| drop-control | 控制包丢失后重传 | recovered，retry=1，6/6 |
| drop-status | 状态包丢失后重传 | recovered，retry=1，6/6 |
| duplicate-frame | 重复 frame 不得二次控制 | recovered，duplicate=1，applied_delta=0 |
| delayed-server | 服务延迟 3000 ms 后恢复 | recovered，6/6 |
| malformed | schema/长度/CRC 错误被拒绝 | rejected，application errors=2，applied_delta=0 |

重复 frame 和 malformed 输入均没有产生额外执行器动作，说明传输层恢复和应用层幂等校验
同时生效。

### 5.4 任务三实现路径

1. 先在双 QEMU 基线中验证模型、数据集、RT-IPC codec、控制算法和故障注入；该基线不作为
   AxVisor 最终通过证据。
2. 将 Task 3 作为 `os/axvisor/guests/task3/` 的独立应用树接入 AxVisor，复用任务二的
   RT-IPC v2，不再引入旧的 RT-IPC v1。
3. Linux 侧实现位于 `os/axvisor/guests/task3/src/linux/` 和 `src/common/`；RT-Thread
   控制服务位于 `src/rtthread/`；模型、输入和 Buildroot/initramfs 资源由 task3 构建脚本
   组织。
4. 使用 `run_task123.sh` 启动同一个 AxVisor 实例，先验证 Linux SMP、网络 READY、Task 2
   服务和 Task 3 服务，再执行正常帧、故障帧和结果门禁。
5. 最后进行 Linux 与 StarryOS 的 3600 秒稳定性对比；StarryOS 是后续客户机替换实验，
   不替代当前 Linux 版本的任务三完成证据。

设计、协议和证据：

- [任务三 AI 控制设计](task123/design/2026-08-15/starryos-replace/os/axvisor/guests/task3/docs/superpowers/specs/2026-08-15-qemu-task3-ai-control-design.md)
- [任务一/二/三集成设计](task123/design/2026-08-17/starryos-replace/docs/superpowers/specs/2026-08-17-axvisor-task123-integration-design.md)
- [任务三测试报告](task123/report/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/task3-report.md)
- [正常场景证据摘要](task123/evidence/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/evidence/normal/summary.json)
- [故障场景汇总](task123/evidence/2026-08-17/starryos-replace/os/axvisor/guests/task3/docs/results/evidence/faults/fault-summary.json)

## 6. 三项任务的完整演进路径

### 阶段一：网络拓扑和 RTOS 选择

2026-08-01 先设计两个 Linux 加一个 Zephyr 的三客户机网络拓扑，约束是仅使用普通
Ethernet/virtio-net。随后项目从 Zephyr 迁移到 RT-Thread 5.2.2，并保留同样的 IP 网络
通信边界。这个阶段解决了客户机地址、内存、virtio-mmio 设备和 QEMU hub 的基础布局。

### 阶段二：RTOS 实时路径

2026-08-03 开始分析 RTOS timer 长尾，加入 RTOS 专用 `busy WFI`、CPU 亲和性和 WFI 快速
返回。随后增加 hard timer、绝对 deadline、VM-scoped TLBI 和低干扰采集。短测中的 timer、
抢占和 SGI 指标达到微秒到数百微秒级；长测显示剩余主要是 QEMU/宿主调度长尾。

### 阶段三：virtio-net 和 RT-IPC

2026-08-10 细化 virtio-net device model、scoped guest memory、virtqueue 和 IRQ 注入。
2026-08-11 集成共享 C RT-IPC v2，加入 ACK、重传、CRC、乱序/重复包处理和重连。最终通过
1000 请求、90,000 并发请求和 240,000 请求长测。

### 阶段四：任务一和任务二联合验证

2026-08-15 将 2-vCPU Linux、pCPU 2 上的 RT-Thread、实时基准和网络请求并行运行，记录
CPU 分布、timer jitter、preemption、SGI、RTT、吞吐和失败样本。通过降低 RT benchmark
后台 worker 优先级，避免它在长测末尾的排序任务阻塞网络服务线程。

### 阶段五：AI 闭环集成

2026-08-15 至 2026-08-17 将 CNN 输出接入 UDP/9877，增加 FIXED 基线、AI 模式、执行器
状态回传、MAE、准确率、端到端 RTT 和五种故障注入。最终在同一 AxVisor 实例中完成
1200 帧闭环和全部故障门禁。

### 阶段六：稳定性和客户机替换扩展

2026-08-18 对 Linux 和 StarryOS 进行 3600 秒对比。两者都完成 240,000 网络请求和
3,599,999 周期样本，但 QEMU timer 门禁仍为 `PASS_WITH_QEMU_TIMER_LIMIT`。StarryOS
网络平均 RTT 约为 Linux 的 3 倍、吞吐约为 Linux 的 35.5%，因此当前最终验收基线仍以
Linux 客户机为主。

## 7. 复现入口和证据索引

最终集成复现入口：

```bash
os/axvisor/scripts/run_task123.sh \
  --mode task3 \
  --task3-frames 600 \
  --output tmp/task123-results/task3-normal
```

完整 Linux/StarryOS 长稳对比入口：

```bash
os/axvisor/scripts/run_task123_guest_comparison.sh \
  --full \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-cache-bench-priority.IQYicb" \
  --output "$PWD/tmp/task123-guest-comparison-full-bench-priority"
```

证据组织方式：

- `task12/design/`：架构、实时性、virtio-net 和 RT-IPC 设计；
- `task12/plan/`：任务一/二实现计划、构建和复现路径；
- `task12/report/`：RT-Thread 实时性、网络和阶段性性能报告；
- `task12/evidence/`：QEMU、guest、CPU、timing 和可靠性原始日志；
- `task123/design/`：三任务集成和协议边界；
- `task123/plan/`：任务三、runner、缓存、故障和长期对比计划；
- `task123/report/`：最终集成报告、Task 3 报告和 Linux/StarryOS 对比报告；
- `task123/evidence/`：Task 3 正常和故障场景的 JSON、CSV、Linux/RT-Thread 日志。

归档总清单见 [INDEX.md](INDEX.md)，文件来源、日期、类型、大小和 SHA-256 见
[manifest.json](manifest.json)。

## 8. 当前限制和后续工作

1. 任务一严格最坏延迟仍受 x86_64 宿主上的 AArch64 QEMU TCG timer/main-loop 调度影响；
   长尾主要由 TCG 仿真和宿主线程调度引入，静态分区只能隔离 AxVisor 内部 vCPU/pCPU
   竞争，不能隔离 QEMU main loop 或宿主调度器；需要在真实 AArch64、KVM 或实时宿主上
   重新验证 WCET 和 `miss_1ms=0`。
2. 当前报告中的实时性结论是“关键路径已显著优化、短测门禁通过、长测存在宿主相关长尾”，
   不是硬实时认证。
3. 任务三的稳定时间指标尚未形成有效样本，需要增加持续控制场景并定义收敛判据。
4. Linux/StarryOS 的 3600 秒对比目前按固定顺序执行；正式性能结论还应交换运行顺序并
   重复多轮，计算置信区间。
5. 任务一和任务二的功能实现已具备复现证据，后续主要工作是硬件/KVM 实时性复验和网络
   性能优化，而不是改变任务二的主通信机制。
