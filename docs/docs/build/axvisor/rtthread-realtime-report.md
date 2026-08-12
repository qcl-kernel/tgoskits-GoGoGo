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

---

## 8. virtio-net 网络通信深度调试（2026-08-11）

### 8.1 调试方法

启用 Axvisor Debug 日志级别，获得完整的 GPPT GICD/GICR 访问追踪。
通过 QEMU filter-dump 捕获两侧网络数据包（pcap），验证数据路径。

### 8.2 已排除的问题

1. **SPI 路由正确**: assign_irq 设置 GICD_IROUTER, IRQ 48 (SPI 16) 路由到 CPU 0, IRQ 50 (SPI 18) 路由到 CPU 2
2. **GPPT IRQ 过滤正常**: 非分配 IRQ 的 IROUTER/ISENABLER 写操作被正确过滤
3. **SPI 使能正确**: Linux 通过 ISENABLER 正确使能 IRQ 48
4. **TX 部分工作**: pcap 捕获到 3 个 ARP 请求包成功到达 RT-Thread 侧
5. **Stage-2 地址映射正确**: virtio_mmio MMIO 区域正确 identity 映射

### 8.3 核心问题

Linux virtio_net TX 队列超时: 数据包发出后, TX 完成中断无法返回 Linux。
pcap 证明数据包确实到达 RT-Thread 侧, 但 RT-Thread 从未回复 ARP。

### 8.4 已实施的修复

| 修复项 | 文件 | 说明 |
|--------|------|------|
| FDT dma-coherent 保留 | virtualization/axvm/src/boot/fdt/core/create.rs | 不再移除 passthrough 设备的 dma-coherent |
| virtio queue version 2 | components/drivers/virtio/virtio.c | 使用非 legacy 寄存器设置队列地址 |
| rtbench.c 编译修复 | applications/rtbench.c | 修复字符串字面量换行符 |

### 8.5 未解决的根因

TX 完成中断在 GIC 层面正确配置, 但无法被 Linux 接收。
可能原因:
- QEMU TCG GICv3 在嵌套虚拟化下的中断投递限制
- Linux 报告 "LPIs enabled, memory probably corrupted" (GICR 脏状态)
- HCR_EL2.IMO=0 时的物理中断投递时序问题

### 8.6 下一步

1. 验证 QEMU TCG 在 HCR_EL2.IMO=0 时是否正确投递物理 SPI 到 EL1
2. 检查 /proc/interrupts 确认中断计数
3. 尝试 GICv2 模式排除 GICv3 问题
4. 检查 ICC_IGRPEN1_EL1 设置
5. 添加中断投递追踪日志

## 调试代码清理（2026-08-12）

### 清理范围

- 删除运行时跟踪模块 `rt_trace.rs`（271 行）及其 5 个调用点（guest_entry/guest_exit/exit_handler_return/deferred_finish/axvm_deadline_publish）。
- 删除 `rt-trace` Cargo feature（axvm 和 axvisor 两个 Cargo.toml）。
- 删除 3 个仅用于 trace 的 board/QEMU 配置文件（rt-trace、three-guest-net-rt-trace、three-guest-net-trace）。
- 删除 6 个 QEMU 调度诊断脚本（collect_qemu_sched_trace、qemu_sched_probe、qemu_sched_thread_map、run_qemu_vcpu_affinity、test_qemu_sched_trace、test_qemu_vcpu_affinity）。
- 删除 2 个临时诊断补丁（qemu-arm-ppi27-diagnostic.patch、qemu-mttcg-exclusive-diagnostic.patch）。
- 恢复生产 board 配置日志级别从 `Debug` 到 `Info`。
- 移除 `inject_external_interrupt` 中新增的逐中断 debug 日志。
- 修正精度测试脚本：移除已删除的 combined trace-board 契约，改为精确 multiset 校验。
- 修复 `timer.rs` 中因删除 trace 调用产生的 clippy let_and_return 警告。

### 保留范围

- AArch64 物理 SPI 路由、GIC 硬件 LR 注入（HW=1 + PINTID）、延迟 deactivate。
- RT-Thread 中断驱动 virtio-net（轮询补丁移除 RX 定时器）。
- RT-IPC 协议核心、Linux 客户端、RT-Thread 服务端及全部测试。
- 实时基准程序（抢占延迟、中断延迟、网络 RTT）和中文测试报告。
- 历史实验数据和报告（rtos-realtime-iterations.csv 等）。

### 验证结果

| 验证项 | 命令 | 结果 |
|--------|------|------|
| 缺失契约 | `test ! -e rt_trace.rs && ! rg rt-trace ...` | PASS |
| 空白检查 | `git diff --check` | PASS（无错误） |
| 架构边界测试 | `cargo test -p axvm --test arch_boundary_contract` | 19/19 PASS |
| AxVM 全量测试 | `cargo test -p axvm` | 175/175 PASS |
| Clippy | `cargo clippy -p axvm` | 无新增警告 |
| RT-IPC 协议 | `make test` | 8/8 PASS |
| RT-IPC 可靠性 | `make test_loopback` | 3/3 PASS |
| 精度测试 board 契约 | Python board feature check | PASS |
| 精度测试 QEMU 网络 | `test_rtbench_precision.sh` | 未通过（QEMU 网络环境限制，与清理无关） |
| 受保护文件 | `test -f run_test.sh` 等 | 全部存在 |

### 代码量统计

清理动作（相对清理前基线）：

| 指标 | 值 |
|------|-----|
| 变更文件数 | 23 |
| 新增行 | 14 |
| 删除行 | 2,948 |
| 净增行 | -2,934 |

当前工作树相对 `dev` 分支：

| 指标 | 值 |
|------|-----|
| 变更文件数 | 112 |
| 新增行 | 13,690 |
| 删除行 | 405 |
| 净增行 | +13,285 |
| 二进制文件 | 1 |

按子系统分类（相对 `dev`）：

| 子系统 | 文件数 | 新增 | 删除 | 净增 |
--------|--------|------|------|------|
| Axvisor/guest | 27 | 4,175 | 46 | +4,129 |
| RT-IPC | 9 | 1,593 | 0 | +1,593 |
| docs/tests | 19 | 4,762 | 0 | +4,762 |
| virtualization | 35 | 1,968 | 298 | +1,670 |
| platforms | 11 | 381 | 6 | +375 |
| other | 11 | 811 | 55 | +756 |

未提交受保护文件（不纳入 numstat）：

| 文件 | 行数 |
|------|------|
| platforms/ax-plat/src/irq/aarch64_hv.rs | 19 |
| platforms/axplat-dyn/src/irq/aarch64_hv.rs | 242 |
| virtualization/axvm/src/arch/aarch64/irq.rs | 48 |
| os/axvisor/patches/rtthread/0001-virtio-net-remove-rx-polling.patch | 57 |

### 历史说明

报告中提到的 QEMU 诊断补丁（qemu-arm-ppi27-diagnostic.patch、qemu-mttcg-exclusive-diagnostic.patch）和调度 trace 脚本是当时实验的分析依据，源文件已在本次产品清理中移除，历史数据和结论保留在报告和 CSV 中作为实验记录。
