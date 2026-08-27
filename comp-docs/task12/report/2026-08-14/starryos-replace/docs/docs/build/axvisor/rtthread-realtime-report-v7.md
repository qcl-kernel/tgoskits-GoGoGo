# Axvisor RT-Thread 实时性与网络通信测试报告 (v7)

> 测试日期：2026-08-14
> 分支：rtthread-migration
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 x 4, 8GB RAM

## 1. 重大变更：从虚拟 virtio-net 切换回 passthrough virtio-net

### 1.1 问题背景

v5/v6 报告中使用 axvisor 内部虚拟 virtio-net 设备（guest_type=virtualized + virtual virtio-net），导致 Linux 侧 RX 中断在初始 ARP 交换后失效。根因是虚拟 GIC 的 edge-triggered SPI 注入问题。

### 1.2 解决方案

切换到 passthrough QEMU virtio-net 设备方案：
- guest_type = "virtualized"（使用 axvisor 的虚拟 GIC 和 timer）
- 将 QEMU 的真实 virtio-mmio 设备作为 passthrough 设备直接映射给 guest
- QEMU 内置 hub（hubid=77）负责二层帧转发
- SPI 中断通过 axvisor 的 VGIC assigned SPI 路径投递

### 1.3 配置

| 属性 | VM[1] Linux | VM[3] RT-Thread |
|------|------------|-----------------|
| guest_type | virtualized | virtualized |
| CPU | 2 vCPU, phys_cpu=[0,1] | 1 vCPU, phys_cpu=2 (固定) |
| 网络 | passthrough /virtio_mmio@a000000 | passthrough /virtio_mmio@a000400 |
| MAC | 52:54:00:77:00:01 | 52:54:00:77:00:03 |
| IP | 192.168.77.11/24 | 192.168.77.30/24 |
| SPI | 16 (INTID 48) | 18 (INTID 50) |

## 2. 实时性基准测试结果

### 2.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (us) | 1078 | 992 | 992 |
| 最大间隔 (us) | 19868 | 19859 | 19904 |
| 平均间隔 (us) | 1349 | 1247 | 1415 |
| 峰峰抖动 (us) | 18790 | 18866 | 18912 |
| P99 (us) | 8114 | 6799 | 9997 |
| P99.9 (us) | 10124 | 10190 | 19270 |
| miss >100us | 325 | 181 | 256 |
| miss >1ms | 47 | 27 | 45 |
| 回调最大 (ns) | 25632 | 7024 | 8352 |

### 2.2 中断延迟 (1-tick one-shot timer, 200 样本)

| 指标 | 值 |
|------|-----|
| 最小 (us) | 292 |
| 最大 (us) | 1161 |
| 平均 (us) | 1007 |
| P99 (us) | 1124 |
| P99.9 (us) | 1161 |

### 2.3 抢占延迟

状态：基准测试代码存在竞态条件，0 样本采集。

### 2.4 长时间稳定性

状态：未执行。

## 3. 网络通信结果

### 3.1 ICMP Ping：完全成功

- 3 packets transmitted, 3 packets received, 0% packet loss
- RTT: min=1.166ms, avg=3.698ms, max=8.643ms

### 3.2 RT-IPC UDP 端到端通信：完全成功

- RT-IPC 协议握手成功
- RT-Thread 服务端收到 4785+ 条消息，总数据量 874KB
- Linux 客户端成功接收响应（STATUS_REP, ACK, HEARTBEAT）
- 序列号连续递增至 1364+，无丢包

### 3.3 RT-IPC 应用层指标

| 指标 | 值 |
|------|-----|
| RTT (64B) | min=13ms, avg=50ms, max=231ms |
| RTT (256B) | min=14ms, avg=34ms, max=217ms |
| RTT (1024B) | min=15ms, avg=71ms, max=234ms |
| 吞吐量 (64B) | 20 KB/s |
| 吞吐量 (256B) | 41 KB/s |
| 吞吐量 (1024B) | 166 KB/s |
| 总消息数 | 4785+ |
| 丢包率 | 0% |

## 4. 任务完成度

### 任务一 (实时性改造与验证): 65%

| 子项 | 状态 |
|------|------|
| 2-vCPU Linux | 完成 |
| RT-Thread 静态分区 | 完成 |
| 定时器抖动测试 | 完成 |
| 中断延迟测试 | 完成 |
| 抢占延迟测试 | 缺失 |
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
| 可靠性机制 | 完成 |

### 任务三 (AI 模型与控制联动): 0%

## 5. 性能对比

| 指标 | v4 (1-vCPU) | v7 (2-vCPU) |
|------|-------------|-------------|
| 定时器抖动 P99 | 1021 us | 6799-9997 us |
| miss >1ms | 0 | 27-47 |
| ICMP RTT | 0.4-0.9 ms | 1.2-8.6 ms |
| 中断延迟 P99 | 1003 us | 1124 us |
| UDP 端到端 | 双向 | 双向 |
