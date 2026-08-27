# Axvisor RT-Thread 实时性与网络通信测试报告 (v6)

> 测试日期：2026-08-10 至 2026-08-14
> 分支：rtthread-migration
> RTOS：RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor：Axvisor (release, qemu-aarch64-two-guest-net)
> 平台：QEMU TCG, cortex-a72 x 4, 8GB RAM

## 1. 测试环境

| 项目 | 配置 |
|------|------|
| QEMU | TCG 模式 (无 KVM), cortex-a72 |
| CPU | 4 核 (Linux: 核心 0,1; RT-Thread: 固定核心 2) |
| GIC | GICv3 (axvisor 内部虚拟 GIC) |
| RT-Thread | 5.2.2, tick=1000Hz, CNTVCT=62.5MHz |
| 网络 | axvisor 虚拟 virtio-net + 内部 L2 switch |
| RT-IPC 协议 | UDP/IPv4, 端口 9876 |

## 2. 关键修复：IRQ 不匹配

### 问题描述

axvisor 的 FDT 生成代码为虚拟 virtio-net 设备硬编码了 SPI 16，但设备资源分配器为每个 VM 分配了不同的 SPI（VM1=INTID 96, VM3=INTID 224）。导致 guest 在错误的中断号上注册处理程序，中断永远无法到达。

### 修复方案

1. 在 capabilities.rs 中从设备图中提取实际分配的 SPI 号
2. 将 SPI 号写入 FDT（GIC FDT SPI = INTID - 32）
3. 更新 RT-Thread 的 virt.h：VIRTIO_IRQ_BASE=224, MAX_HANDLERS=256, ARM_GIC_NR_IRQS=256

## 3. 实时性基准测试结果

### 3.1 定时器抖动 (1ms 周期, 999 样本/轮, 3 轮)

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 最小间隔 (us) | 996 | 1075 | 1060 |
| 最大间隔 (us) | 1189 | 1188 | 1183 |
| 平均间隔 (us) | 1085 | 1086 | 1085 |
| P99 (us) | 1122 | 1120 | 1117 |
| miss >1ms | 0 | 0 | 0 |

### 3.2 中断延迟 (1-tick one-shot timer, 200 样本)

| 指标 | 值 |
|------|-----|
| 最小 (us) | 853 |
| 最大 (us) | 1126 |
| 平均 (us) | 1011 |
| P99 (us) | 1118 |

### 3.3 抢占延迟

状态：基准测试代码存在竞态条件，0 样本采集。

### 3.4 长时间稳定性

状态：未执行。

## 4. 网络通信状态

### 4.1 ICMP Ping：成功

- Linux ping RT-Thread: 1 packets transmitted, 1 packets received, 0% packet loss
- RTT: 15-27ms

### 4.2 RT-IPC 协议

- 连接建立 (SYN/SYNACK): 成功
- RT-Thread 服务端接收: 300+ 条消息
- Linux 客户端接收: 0 条响应 (virtio-net RX 中断在初始 ARP 后失效)

### 4.3 根因分析

axvisor 的 virtio-net 设备成功将帧写入 guest 的 RX 缓冲区并触发中断，但 Linux 的 virtio-net 驱动在初始 ARP 交换后不再处理后续 RX 中断。这可能是虚拟 GIC 中 edge-triggered SPI 的中断注入问题。

## 5. 任务完成度

### 任务一 (实时性改造与验证): 60%

| 子项 | 状态 |
|------|------|
| 2-vCPU Linux | 完成 |
| RT-Thread 静态分区 | 完成 |
| 定时器抖动测试 | 完成 (3轮, 0截止违反) |
| 中断延迟测试 | 完成 (200样本, P99=1118us) |
| 抢占延迟测试 | 缺失 (代码有bug) |
| 长时间稳定性 | 缺失 |
| RTOS 裸机基线 | 缺失 |

### 任务二 (客户机间通信): 55%

| 子项 | 状态 |
|------|------|
| virtio-net 链路 | 完成 |
| ICMP 双向通信 | 完成 |
| RT-IPC 协议设计 | 完成 |
| RT-Thread 服务端 | 完成 (300+ msgs) |
| Linux 客户端连接 | 完成 |
| 端到端 UDP 通信 | 部分完成 (服务端收到, 响应未到达客户端) |
| 应用层指标 | 缺失 |

### 任务三 (AI 模型与控制联动): 0%

完全未开始。

