# Axvisor RT-Thread 实时性与网络通信测试报告 (v5)

> 测试日期：2026-08-10 至 2026-08-14
> 分支：rtthread-migration (main tgoskits repo)
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 × 4, 8GB RAM

## 1. 测试环境

| 项目 | 配置 |
|------|------|
| QEMU | TCG 模式 (无 KVM), cortex-a72 |
| CPU | 4 核 (Linux: 核心 0,1; RT-Thread: 固定核心 2) |
| GIC | GICv3 (axvisor 内部虚拟 GIC) |
| RT-Thread | 5.2.2, tick=1000Hz, CNTVCT=62.5MHz |
| 网络 | axvisor 虚拟 virtio-net + 内部 L2 switch |
| RT-IPC 协议 | UDP/IPv4, 端口 9876 |

### VM 配置

| 属性 | VM[1] Linux | VM[3] RT-Thread |
|------|------------|-----------------|
| 类型 | Virtualized (guest_type=virtualized) | Virtualized (guest_type=virtualized) |
| CPU | 2 vCPU, phys_cpu=[0,1] | 1 vCPU, phys_cpu=2 (固定) |
| 内存 | 0x80000000, 512MB | 0xa0000000, 256MB |
| 网络 | 虚拟 virtio-net @0x0b000000 | 虚拟 virtio-net @0x0b000000 |
| MAC | 52:54:00:77:00:01 | 52:54:00:77:00:03 |
| IP | 192.168.77.11/24 | 192.168.77.30/24 |

## 2. 实时性基准测试结果

### 2.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

数据来源：2026-08-14 virtual-net-test.log

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (μs) | 996 | 1075 | 1060 |
| 最大间隔 (μs) | 1189 | 1188 | 1183 |
| 平均间隔 (μs) | 1085 | 1086 | 1085 |
| 峰峰抖动 (μs) | 193 | 112 | 123 |
| P99 (μs) | 1122 | 1120 | 1117 |
| P99.9 (μs) | 1183 | 1181 | 1183 |
| miss >100μs | 20 | 37 | 31 |
| miss >1ms | 0 | 0 | 0 |
| 回调最大 (ns) | 55808 | 1776 | 2272 |

**关键发现**：三轮均无截止时间违反（miss_gt1ms=0），稳态抖动 ±85μs，回调执行时间 <56μs。
注意：本轮数据抖动略高于 v4 报告的 d7d273c2f passthrough 数据（±15μs），原因可能是：
1. 2-vCPU Linux 增加了调度压力
2. Virtualized 模式下 GIC 仿真开销
3. CPU 0,1 同时运行 Linux 的 vCPU，产生 cache 竞争

### 2.2 中断延迟 (1-tick one-shot timer, 200 样本)

| 指标 | 值 |
|------|-----|
| 最小 (μs) | 925 |
| 最大 (μs) | 1107 |
| 平均 (μs) | 1010 |
| P99 (μs) | 1041 |
| P99.9 (μs) | 1107 |

### 2.3 抢占延迟

状态：基准测试代码存在竞态条件，0 样本采集。问题在于高优先级线程
在低优先级线程调用 rt_thread_resume() 后立即 suspend 自身，导致死锁。

### 2.4 长时间稳定性

状态：未执行。建议运行 ≥1 小时的连续测试。

## 3. 网络通信状态

### 3.1 当前状态：阻塞

虚拟 virtio-net 设备在两端均成功初始化：
- RT-Thread: magic=0x74726976, vendor=0x1af4, dev_id=1, init_handler=0 ✅
- Linux: eth0 UP, HWaddr=52:54:00:77:00:01, TX=15 packets ✅
- RT-Thread RT-IPC server: listening on 192.168.77.30:9876 ✅

但端到端通信失败：
- Linux RX packets: 0（所有 15 个 TX 包均未收到响应）
- RT-Thread RT-IPC server: msgs=0（未收到任何数据包）
- axvisor 日志: 仅 1 次 "virtio-net drops an ingress frame: NotReady"

### 3.2 根因分析

axvisor 内部 L2 switch 的帧转发机制存在以下问题：

1. **Passthrough 模式**：虚拟 virtio-net MMIO 地址 (0x0b000000) 未正确配置
   Stage-2 陷入。Guest 的 QueueNotify 写入只触发一次陷入（产生 NotReady），
   后续写入未陷入到 axvisor，导致 TX 队列不被处理。

2. **Virtualized 模式**：GIC maintenance 中断 (IRQ 26) 未正确处理，
   导致中断风暴，系统卡死。

3. **FDT IRQ 不匹配**：create.rs 中硬编码 SPI 16 作为虚拟 virtio-net 中断，
   但 RT-Thread BSP 使用硬编码 SPI 18 (INTID 50)。设备图自动分配的 IRQ
   可能与 FDT 描述不一致。

### 3.3 修复计划

#### 优先级 1：修复 Passthrough 模式下的虚拟设备 MMIO 陷入

需要确保 Stage-2 页表中 0x0b000000 区域被标记为 trap（而非 passthrough），
这样 guest 的每次 MMIO 访问都会陷入到 axvisor 进行处理。

涉及文件：
- `virtualization/axvm/src/layout.rs` - Stage-2 映射规划
- `virtualization/axvm/src/vm/prepare/device_plan/` - 设备 MMIO 区域分配

#### 优先级 2：修复 IRQ 路由

确保虚拟 virtio-net 设备的 SPI 与 FDT 描述和 RT-Thread 硬编码值一致。

涉及文件：
- `virtualization/axvm/src/boot/fdt/core/create.rs:382` - install_configured_virtio_net
- `os/axvisor/src/virtio_net.rs` - DeviceModel requirements

#### 优先级 3：修复 RT-Thread 抢占延迟基准测试

修复 rtbench.c 中的竞态条件：高优先级线程不应在低优先级线程 resume 后
立即 suspend 自身。

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

### 4.2 实现状态

| 组件 | 状态 |
|------|------|
| RT-IPC 协议库 (C) | ✅ 完成 |
| RT-Thread UDP 服务端 | ✅ 编译并集成到 BSP, 监听中 |
| Linux UDP 客户端 | ✅ 交叉编译, 注入 initramfs |
| 端到端 UDP 通信 | ❌ 阻塞（L2 switch 帧转发问题） |

## 5. 任务完成度

### 任务一 (实时性改造与验证): 55%

| 子项 | 状态 | 说明 |
|------|------|------|
| 2-vCPU Linux | ✅ | cpu_num=2, phys_cpu_ids=[0,1] |
| RT-Thread 静态分区 | ✅ | 绑定 CPU 2 |
| 定时器抖动测试 | ✅ | 3 轮, 0 截止违反 |
| 中断延迟测试 | ✅ | 200 样本, P99=1041μs |
| 抢占延迟测试 | ❌ | 基准测试代码有 bug |
| 长时间稳定性 | ❌ | 未执行 |
| RTOS 裸机基线 | ❌ | 未执行 |

### 任务二 (客户机间通信): 45%

| 子项 | 状态 | 说明 |
|------|------|------|
| virtio-net 链路 | ✅ | 两端设备初始化成功 |
| IP 层通信 | ❌ | L2 switch 帧转发失败 |
| RT-IPC 协议设计 | ✅ | SYN/ACK/CRC16/重传 |
| RT-Thread 服务端 | ✅ | 编译、运行、监听中 |
| Linux 客户端 | ✅ | 编译、注入 initramfs |
| 端到端通信 | ❌ | 阻塞 |
| 应用层指标 | ❌ | 依赖通信打通 |

### 任务三 (AI 模型与控制联动): 0%

完全未开始，依赖任务二完成。

## 6. 构建与运行

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits

# 构建 axvisor
cargo axvisor build --config qemu-aarch64-two-guest-net \
  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/linux-net.toml \
  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml

# 转换为二进制
aarch64-linux-gnu-objcopy -O binary \
  target/aarch64-unknown-linux-musl/release/axvisor \
  target/aarch64-unknown-linux-musl/release/axvisor.bin

# 运行 QEMU
timeout 120 /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
  -nographic -cpu cortex-a72 \
  -machine virt,virtualization=on,gic-version=3 \
  -global virtio-mmio.force-legacy=false \
  -smp 4 \
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 \
  -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img \
  -append 'root=/dev/nvme0n1 rw init=/bin/sh' \
  -m 8g \
  -netdev hubport,id=net0,hubid=77 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
  -netdev hubport,id=net2,hubid=77 \
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 \
  -kernel target/aarch64-unknown-linux-musl/release/axvisor.bin
```

## 7. 关键文件索引

| 文件 | 说明 |
|------|------|
| `os/axvisor/configs/vms/qemu/aarch64/linux-net.toml` | Linux VM 配置 (virtualized, 2 vCPU) |
| `os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml` | RT-Thread VM 配置 (virtualized, CPU 2) |
| `os/axvisor/src/virtio_net.rs` | 虚拟 virtio-net 设备实现 + L2 switch |
| `virtualization/axvm/src/boot/fdt/core/create.rs` | FDT 生成 + 虚拟设备节点注入 |
| `os/axvisor/guests/rt-ipc/` | RT-IPC 协议实现 |
| `tmp/rt-thread-5.2.2/bsp/qemu-virt64-aarch64/` | RT-Thread BSP (virtio-net @0x0b000000) |

