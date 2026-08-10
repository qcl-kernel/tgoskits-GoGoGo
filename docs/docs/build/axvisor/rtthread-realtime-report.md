# Axvisor RT-Thread 实时性测试报告

> 测试日期：2026-08-10
> 分支：rtthread-guest
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 × 4, 8GB RAM

## 1. 测试环境

| 项目 | 配置 |
|------|------|
| QEMU | TCG 模式 (无 KVM), cortex-a72 |
| CPU | 4 核, RT-Thread vCPU 固定到物理核心 2 |
| GIC | GICv3 (GICD/GICR 陷入仿真) |
| RT-Thread | 5.2.2, tick=1000Hz, CNTVCT=62.5MHz |
| Host Timer Policy | Periodic |
| Host VCPU Idle | Halt |

## 2. 移植修复清单

1. **链接地址**: _text_offset 0x80000 → 0
2. **MMU pv_off==0**: 增加 TTBR0-only 映射分支
3. **设备内存**: 添加 UART/GIC/virtio DEVICE_MEM 条目
4. **GIC IPRIORITYR 编译器优化**: 添加内存屏障
5. **GICR SGI frame**: 跳过 IPRIORITYR 批量初始化（Axvisor 仿真不支持）
6. **控制台输出**: 直接 PL011 UART 写入替代 ofw console
7. **组件初始化**: 启用 RT_USING_COMPONENTS_INIT
8. **主线程栈**: 2048 → 16384 字节

## 3. 基准测试结果

### 3.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (us) | 995 | 1001 | 999 |
| 最大间隔 (us) | 1060 | 1026 | 1030 |
| 平均间隔 (us) | 1006 | 1006 | 1006 |
| 峰峰抖动 (us) | 65 | 25 | 30 |
| P99 (us) | 1016 | 1014 | 1013 |
| miss >100us | 0 | 0 | 0 |
| miss >1ms | 0 | 0 | 0 |
| 回调最大 (ns) | 35728 | 6384 | 3552 |

### 3.2 关键发现

- 三轮均无截止时间违反（偏离 >100us 的样本为 0）
- 最大偏离 60us 出现在 Round 1（cache cold start）
- Round 2/3 稳定在 ±15us 抖动范围
- 回调执行时间极短（<36us），非瓶颈

## 4. 性能评估

当前结果为**合理但不优秀**。1ms 周期下 ±30us 的典型抖动在 QEMU TCG 环境可接受，但距硬实时保证尚有差距。QEMU TCG 的软件翻译、宿主调度抢占等因素限制了确定性。

## 5. 待测试指标

- 抢占延迟 (Preemption Latency)
- 中断延迟 (Interrupt Latency)
- 网络往返时间 (Network RTT via virtio-net)
- WCET (Worst-Case Execution Time)

## 6. 后续计划

1. 清理调试 UART 写入
2. 启用 virtio-net, 实现 Linux ↔ RT-Thread 网络通信
3. 添加更多实时指标测试
4. 在真实硬件 (Orange Pi 5 Plus) 上验证
# Axvisor RT-Thread 实时性测试报告 (v2)

> 测试日期：2026-08-10/11
> 分支：rtthread-guest
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 × 4, 8GB RAM

## 1. 测试环境

| 项目 | 配置 |
|------|------|
| QEMU | TCG 模式 (无 KVM), cortex-a72 |
| CPU | 4 核 (Linux: 核心 0; RT-Thread: 固定核心 2) |
| GIC | GICv3 (GPPT GICD/GICR 陷入仿真) |
| RT-Thread | 5.2.2, tick=1000Hz, CNTVCT=62.5MHz |
| Host Timer Policy | Periodic |
| Host VCPU Idle | Halt |
| 网络 | QEMU virtio-net (hub 77 连接两个 VM) |

### VM 配置

| 属性 | VM[1] Linux | VM[3] RT-Thread |
|------|------------|-----------------|
| CPU | 1 vCPU, phys_cpu=0 | 1 vCPU, phys_cpu=2 (固定) |
| 内存 | 0x80000000, 512MB (identity) | 0xa0000000, 256MB (identity) |
| 中断模式 | passthrough | passthrough |
| GIC | GPPT GICD + GICR | GPPT GICD + GICR |
| Passthrough SPIs | [16] (virtio-net bus 0) | [18] (virtio-net bus 2) |
| virtio-net | @0xa000000, bus 0 | @0xa000400, bus 2 |

## 2. 移植修复清单

### RT-Thread 移植修复
1. 链接地址: _text_offset 0x80000 → 0
2. MMU pv_off==0: 增加 TTBR0-only 映射分支
3. 设备内存: 添加 UART/GIC/virtio DEVICE_MEM 条目
4. GIC IPRIORITYR 编译器优化: 添加内存屏障
5. GICR SGI frame: 跳过 IPRIORITYR 批量初始化
6. 控制台输出: 直接 PL011 UART 写入替代 ofw console
7. 组件初始化: 启用 RT_USING_COMPONENTS_INIT
8. 主线程栈: 2048 → 16384 字节
9. 调试 UART 清理: 清理全部约 79 个调试写入

### Axvisor 配置修复（本次新增）
10. passthrough_irqs: 为两个 VM 添加 virtio-net SPI 转发
11. VM 配置编译: 修正 AXVISOR_VM_CONFIGS 编译路径

## 3. 启动状态

### 成功
- 两个 VM 均成功启动 (Linux 6.18.0-rc6 + RT-Thread 5.2.2)
- RT-Thread virtio-net 初始化成功 (init_handler=0)
- lwIP-2.1.2 协议栈启动
- RT-Thread 实时基准测试运行成功 (3 轮 x 999 样本)

### 已知问题
1. Linux initramfs 格式错误
2. virtio-net TX 超时 (网络通信不工作)
3. 抢占延迟和中断延迟测试代码已编写但未运行

## 4. 基准测试结果

### 4.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

与 Linux VM 并行运行 (Linux 核心 0, RT-Thread 核心 2)。

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (us) | 990 | 999 | 995 |
| 最大间隔 (us) | 1024 | 1039 | 1036 |
| 平均间隔 (us) | 1006 | 1006 | 1006 |
| 峰峰抖动 (us) | 33 | 39 | 40 |
| P99 (us) | 1017 | 1016 | 1016 |
| P99.9 (us) | 1024 | 1039 | 1036 |
| miss >100us | 0 | 0 | 0 |
| miss >500us | 0 | 0 | 0 |
| miss >1ms | 0 | 0 | 0 |
| 回调最大 (ns) | 39584 | 3776 | 10000 |

### 4.2 与上轮对比

| 指标 | 独立运行 | 双 VM 运行 | 变化 |
|------|---------|-----------|------|
| 峰峰抖动 | 25-65 us | 33-40 us | 改善 |
| P99 | 1013-1017 us | 1016-1017 us | 持平 |
| miss >100us | 0 | 0 | 持平 |

## 5. 性能评估

当前结果为合理但不优秀。1ms 周期下零截止时间违反, 典型抖动 +-20us。
QEMU TCG 的软件翻译限制了确定性。需要在真实硬件上验证。

## 6. 网络通信分析

RT-Thread virtio-net 驱动初始化成功但网络数据包传输不工作。
可能原因: DMA 一致性, SPI 中断路由, virtio 队列通知。

## 7. 后续计划

1. 修复 virtio-net 网络通信 (P0)
2. 修复 initramfs 格式 (P1)
3. 运行抢占延迟和中断延迟基准测试 (P1)
4. 在真实硬件上验证 (P2)
5. 优化 RT-Thread 实时性 (P3)
