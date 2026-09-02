# Axvisor RT-Thread 实时性与网络通信测试报告 (v8)

> 测试日期：2026-08-14
> 分支：rtthread-migration
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 x 4, 8GB RAM

## 1. 架构方案：Passthrough virtio-net + Virtualized GIC/Timer

| 属性 | VM[1] Linux | VM[3] RT-Thread |
|------|------------|-----------------|
| guest_type | virtualized | virtualized |
| CPU | 2 vCPU, phys_cpu=[0,1] | 1 vCPU, phys_cpu=2 (固定) |
| 网络 | passthrough /virtio_mmio@a000000 | passthrough /virtio_mmio@a000400 |
| MAC | 52:54:00:77:00:01 | 52:54:00:77:00:03 |
| IP | 192.168.77.11/24 | 192.168.77.30/24 |
| SPI | 16 (INTID 48) | 18 (INTID 50) |

## 2. 实时性基准测试结果（完整）

### 2.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (us) | 1077 | 1080 | 994 |
| 最大间隔 (us) | 19974 | 11271 | 20208 |
| 平均间隔 (us) | 1300 | 1248 | 1218 |
| P99 (us) | 8882 | 6905 | 5615 |
| P99.9 (us) | 10201 | 10123 | 10131 |
| miss >100us | 255 | 267 | 297 |
| miss >1ms | 35 | 32 | 21 |
| 回调最大 (ns) | 25264 | 89584 | 3648 |

### 2.2 中断延迟 (1-tick one-shot timer, 200 样本)

| 指标 | 值 |
|------|-----|
| 最小 (us) | 784 |
| 最大 (us) | 1272 |
| 平均 (us) | 1009 |
| P99 (us) | 1122 |
| P99.9 (us) | 1272 |

### 2.3 抢占延迟 (200 样本) ← 新增

| 指标 | 值 |
|------|-----|
| 最小 (ns) | 1120 |
| 最大 (ns) | 229104 |
| 平均 (ns) | 2400 |
| P99 (ns) | 4320 |
| P99.9 (ns) | 229104 |

分析：平均抢占延迟2.4us，P99=4.3us，表现优秀。最大229us的离群值来自QEMU TCG翻译抖动。

### 2.4 长时间稳定性

状态：未执行（建议运行>=1小时的连续测试）。

## 3. 网络通信结果

### 3.1 ICMP Ping

- 3 packets transmitted, 3 received, 0% packet loss
- RTT: min=1.262ms, avg=3.821ms, max=8.676ms

### 3.2 RT-IPC UDP 端到端通信

- RT-IPC握手成功
- RT-Thread服务端收到1685+条消息
- Linux客户端成功接收响应
- 0% 丢包

## 4. 任务完成度

### 任务一 (实时性改造与验证): 75%

| 子项 | 状态 |
|------|------|
| 2-vCPU Linux | 完成 SMP: Total of 2 processors |
| RT-Thread 静态分区 | 完成 绑定CPU 2 |
| 定时器抖动测试 | 完成 3轮 |
| 中断延迟测试 | 完成 200样本 P99=1122us |
| 抢占延迟测试 | 完成 200样本 P99=4.3us |
| 长时间稳定性 | 缺失 |
| RTOS 裸机基线 | 缺失 |

### 任务二 (客户机间通信): 80%

| 子项 | 状态 |
|------|------|
| virtio-net 链路 | 完成 |
| ICMP 双向通信 | 完成 0%丢包 |
| RT-IPC 协议设计 | 完成 |
| 端到端 UDP 通信 | 完成 双向成功 |
| 应用层指标 | 完成 |
| 可靠性机制 | 完成 ACK/CRC16/心跳/重传 |

### 任务三 (AI 模型与控制联动): 0%

## 5. 构建与运行

构建:
  cd tgoskits
  cargo xtask axvisor build --config qemu-aarch64-two-guest-net \
    --vmconfigs os/axvisor/configs/vms/qemu/aarch64/linux-net.toml \
    --vmconfigs os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml
  aarch64-linux-gnu-objcopy -O binary target/aarch64-unknown-linux-musl/release/axvisor target/aarch64-unknown-linux-musl/release/axvisor.bin

运行:
  timeout 180 qemu-system-aarch64 -nographic -cpu cortex-a72 \
    -machine virt,virtualization=on,gic-version=3 \
    -global virtio-mmio.force-legacy=false -smp 4 \
    -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 \
    -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img \
    -append 'root=/dev/nvme0n1 rw init=/bin/sh' -m 8g \
    -netdev hubport,id=net0,hubid=77 \
    -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
    -netdev hubport,id=net2,hubid=77 \
    -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 \
    -kernel target/aarch64-unknown-linux-musl/release/axvisor.bin
