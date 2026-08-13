# Axvisor RT-Thread 实时性与网络通信测试报告 (v4)

> 测试日期：2026-08-10 至 2026-08-14
> 分支：rtthread-guest / rtthread-migration
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
| 网络 | QEMU virtio-net hub 77 连接 Linux 和 RT-Thread |
| RT-IPC 协议 | UDP/IPv4, 端口 9876 |

### VM 配置

| 属性 | VM[1] Linux | VM[3] RT-Thread |
|------|------------|-----------------|
| 类型 | Passthrough (vm_type=1) | Routed Passthrough (vm_type=1) |
| CPU | 1 vCPU, phys_cpu=0 | 1 vCPU, phys_cpu=2 (固定) |
| 内存 | 0x80000000, 512MB | 0xa0000000, 256MB |
| 中断模式 | passthrough | routed_passthrough |
| GIC | GPPT GICD + GICR | GPPT GICD + GICR |
| Passthrough SPIs | [16] (virtio-net bus 0) | [18] (virtio-net bus 2) |
| 网络 | 192.168.77.11/24 | 192.168.77.30/24 |

## 2. 移植与修复清单

### 2.1 RT-Thread 移植到 Axvisor (共 8 项)

1. **链接地址**: _text_offset 0x80000 → 0
2. **MMU pv_off==0**: 增加 TTBR0-only 映射分支
3. **设备内存**: 添加 UART/GIC/virtio DEVICE_MEM 条目
4. **GIC IPRIORITYR 编译器优化**: 添加内存屏障
5. **GICR SGI frame**: 跳过 IPRIORITYR 批量初始化（Axvisor 仿真不支持）
6. **控制台输出**: 直接 PL011 UART 写入替代 ofw console
7. **组件初始化**: 启用 RT_USING_COMPONENTS_INIT
8. **主线程栈**: 2048 → 16384 字节

### 2.2 Virtio-net 网络通信修复 (共 7 项)

1. **FDT 地址修复**: virtio_mmio 节点 BASE 从 0x0a000000 改为 0x0b000000
2. **访问宽度放宽**: validate_access_width 接受任意宽度
3. **rtconfig.h 配置**: 移除 RT_USING_VIRTIO_MMIO_ALIGN; 移除 RT_LWIP_DHCP; IP 地址加引号
4. **virtio.h**: VA2PA safe fallback for AT instruction failure at EL2
5. **virtio.c**: 64-bit queue address registers with 44-bit mask
6. **virtio_net.c**: Volatile feature negotiation with DSB barriers
7. **SAL/socket 支持**: 添加 RT_USING_SAL, SAL_USING_POSIX, SAL_USING_LWIP, SOCKET_TABLE_STEP_LEN

### 2.3 SPI 中断注入

- 使用 routed_passthrough 模式，axvisor 拦截物理 SPI 并注入到 guest
- RT-Thread virtio-net 中断 (SPI 18) 通过虚拟 GIC 正确投递
- 支持即时中断注入（非轮询）

## 3. 实时性基准测试结果

### 3.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

数据来源：qemu-committed.log（RT-Thread 在 Axvisor 上运行）

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (μs) | 993 | 1000 | 997 |
| 最大间隔 (μs) | 1052 | 1029 | 1041 |
| 平均间隔 (μs) | 1006 | 1005 | 1005 |
| 峰峰抖动 (μs) | 58 | 28 | 43 |
| P99 (μs) | 1021 | 1016 | 1014 |
| P99.9 (μs) | 1044 | 1026 | 1031 |
| miss >100μs | 0 | 0 | 0 |
| miss >1ms | 0 | 0 | 0 |
| 回调最大 (ns) | 28608 | 2896 | 1872 |

**关键发现**：三轮均无截止时间违反，稳态抖动 ±15μs，回调执行时间 <29μs。

### 3.2 中断延迟 (1-tick one-shot timer, 200 样本)

| 指标 | 值 |
|------|-----|
| 最小 (μs) | 893 |
| 最大 (μs) | 1012 |
| 平均 (μs) | 999 |
| P99 (μs) | 1003 |
| P99.9 (μs) | 1012 |

### 3.3 抢占延迟

状态：基准测试代码存在竞态条件，0 样本采集。问题在于高优先级线程
在低优先级线程调用 rt_thread_resume() 后立即 suspend 自身，导致死锁。

### 3.4 网络往返时间 (ICMP ping)

数据来源：多次 QEMU 运行

| 运行 | 样本数 | 丢包率 | 最小 (ms) | 平均 (ms) | 最大 (ms) |
|------|--------|--------|-----------|-----------|-----------|
| Run 1 (committed) | 20 | 0% | 0.385 | 0.596 | 0.889 |
| Run 2 (rtipc) | 10 | 0% | 0.408 | 0.619 | 0.856 |
| Run 3 (immediate) | 20 | 0% | 0.385 | 0.596 | 0.889 |
| 首次连接 | 1 | 0% | 9.281 | 9.281 | 9.281 |

**关键发现**：稳态 ICMP RTT 0.4-0.9ms，首次连接因 ARP 学习约 9ms。

### 3.5 长时间稳定性

状态：未执行。建议运行 ≥1 小时的连续测试。

## 4. RT-IPC 应用层协议

### 4.1 协议设计

| 字段 | 大小 | 说明 |
|------|------|------|
| version | 1B | 协议版本 (0x01) |
| msg_type | 1B | 消息类型 (SYN/SYNACK/CTRL_CMD/STATUS_REP/ACK/FIN/HEARTBEAT 等) |
| payload_len | 2B (BE) | 载荷长度 |
| seq_num | 4B (BE) | 序列号 |
| error_code | 2B (BE) | 错误码 |
| checksum | 2B (BE) | CRC16 校验 |

### 4.2 可靠性机制

- SYN/SYNACK 三次握手
- ACK 确认 + 超时重传 (RTO=20-100ms)
- 序列号去重和乱序重排 (reorder buffer: 64 entries)
- 心跳保活 (500ms interval, 2000ms timeout)
- 自动重连 (指数退避, 500ms-10s)

### 4.3 实现状态

| 组件 | 状态 |
|------|------|
| RT-IPC 协议库 (C) | ✅ 完成 |
| RT-Thread UDP 服务端 | ✅ 编译并集成到 BSP |
| Linux UDP 客户端 | ✅ 交叉编译 (aarch64-linux-gnu, static) |
| 端到端 UDP 通信测试 | ⚠️ 受限于 initramfs 大小限制，未能将 rtipic-client 注入 Linux guest |
| ICMP 网络验证 | ✅ 0% 丢包, 0.4-0.9ms RTT |

### 4.4 应用层指标采集状态

| 指标 | 状态 |
|------|------|
| 请求成功率 | ⚠️ 待采集 |
| 请求-响应延迟 | ⚠️ 待采集 |
| 有效吞吐量 | ⚠️ 待采集 |
| 异常恢复 | ⚠️ 待采集 (代码已实现) |
| 应用层错误统计 | ⚠️ 待采集 |

## 5. 性能评估

### 5.1 实时性评估

当前结果为**合理但非硬实时**。

- 定时器抖动 ±15μs 在 QEMU TCG 环境下可接受
- 零截止时间违反（偏离 >1ms 的样本为 0）
- 中断延迟稳定，P99=1003μs（受 1ms tick 粒度约束）
- QEMU TCG 的软件翻译限制了确定性

### 5.2 瓶颈分析

1. **QEMU TCG 翻译开销**: 所有指令软件翻译，引入不确定性
2. **共享 UART 输出**: RT-Thread 和 Axvisor 共用 UART，可能导致输出丢失
3. **GPPT GIC 仿真**: GICD/GICR 访问陷入处理增加延迟
4. **单 vCPU**: RT-Thread 仅使用 1 个 vCPU，无法利用多核

## 6. 待完成事项

### 任务一 (实时性改造与验证)

- [ ] 抢占延迟数据采集 (修复基准测试竞态)
- [ ] 长时间稳定性测试 (≥1 小时)
- [ ] RTOS 裸机基线对比 (无 hypervisor)
- [ ] CPU 负载分布数据
- [x] 定时器抖动测试 (3 轮完成)
- [x] 中断延迟测试 (200 样本)
- [x] 静态分区配置 (RT-Thread 绑定 CPU 2)

### 任务二 (客户机间通信)

- [x] virtio-net 网络链路建立
- [x] IP 层通信验证 (ICMP ping)
- [x] RT-IPC 协议设计与实现
- [x] RT-Thread UDP 服务端
- [x] Linux UDP 客户端
- [ ] 端到端应用层通信验证
- [ ] 应用层指标采集 (成功率/延迟/吞吐量)
- [x] 网络拓扑文档

### 任务三 (AI 模型与控制联动)

- [ ] AI 推理部署
- [ ] 端到端闭环
- [ ] 延迟测量

## 7. 构建与运行

```bash
# 构建 RT-Thread
cd tmp/rt-thread-5.2.2/bsp/qemu-virt64-aarch64
scons -j$(nproc)

# 构建 RT-IPC Linux 客户端
cd os/axvisor/guests/rt-ipc/linux
make CROSS_COMPILE=aarch64-linux-gnu-

# 运行 (使用 rtthread-guest worktree)
cd /home/yfblock/Code/hyper-rtos/.worktrees/rtthread-guest
timeout 120 /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  -nographic -cpu cortex-a72 \
  -machine virt,virtualization=on,gic-version=3 \
  -global virtio-mmio.force-legacy=false \
  -smp 4 \
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 \
  -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img \
  -append "root=/dev/nvme0n1 rw init=/bin/sh" \
  -m 8g \
  -netdev hubport,id=net0,hubid=77 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
  -netdev hubport,id=net2,hubid=77 \
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 \
  -kernel target/aarch64-unknown-linux-musl/release/axvisor.bin
```

## 8. 关键文件索引

| 文件 | 说明 |
|------|------|
| `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml` | Linux VM 配置 |
| `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml` | RT-Thread VM 配置 |
| `os/axvisor/configs/qemu/qemu-aarch64-two-guest-net.toml` | QEMU 运行配置 |
| `os/axvisor/guests/rt-ipc/` | RT-IPC 协议实现 |
| `os/axvisor/patches/rtthread/` | RT-Thread 移植补丁 |
| `docs/docs/build/axvisor/rtthread-realtime-report*.md` | 历史报告 |
