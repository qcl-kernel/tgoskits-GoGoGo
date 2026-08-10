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
