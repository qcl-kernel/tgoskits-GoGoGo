# 双 QEMU 迁移基线：Linux/RT-Thread AI 控制闭环结果

本报告由 docs/results/evidence/normal 中的原始数据生成。每种模式 600 帧，输入帧率 10 FPS，计划有效运行时长 120.0 秒，Linux 同侧实测为 119.806724 秒。

本报告是导入 AxVisor 前的**双 QEMU 迁移基线**，用于确认模型、协议与控制算法的参考行为，不属于 AxVisor 最终证据。AxVisor 集成结果必须使用 `os/axvisor/scripts/run_task123.sh` 重新采集并写入统一报告。

故障证据来自 docs/results/evidence/faults/fault-summary.json ，五类场景均由真实双 QEMU 客户机运行并通过校验。

## 网络拓扑

Linux 客户机使用 192.168.77.11/24、MAC 52:54:00:77:00:11；RT-Thread 客户机使用 192.168.77.30/24、MAC 52:54:00:77:00:30。两端通过 QEMU multicast socket LAN 直连，应用主通道为 RT-IPC over UDP/9876，无 NAT、宿主桥接或 vsock 数据通道。

## 构建与启动命令

    /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a53 -smp 1 -m 128M -kernel "/home/yfblock/Code/hyper-rtos/qemu-task3/build/images/rtthread/rtthread.bin" -netdev socket,id=net0,mcast=230.77.0.1:10600 -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:30 -nographic -no-reboot
    /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a53 -smp 2 -m 256M -kernel "/home/yfblock/Code/hyper-rtos/qemu-task3/build/images/linux/Image" -initrd "/home/yfblock/Code/hyper-rtos/qemu-task3/build/images/linux/rootfs.cpio" -append "console=ttyAMA0 rdinit=/sbin/init task3.frames=600 " -netdev socket,id=net0,mcast=230.77.0.1:10600 -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:11 -nographic -no-reboot

## 版本与运行配置

    QEMU emulator version 11.0.2
    Copyright (c) 2003-2026 Fabrice Bellard and the QEMU Project developers
    frames=600
    multicast_port=10600
    smoke=0
    fault_case=normal
    git_sha=b1fba0e02645541ca03e19fec227116b7e438081
    git_status=clean
    8f3e906fb48c54eb900ee70d712ca009292494392bff792e02113d74eeeb19da  /home/yfblock/Code/hyper-rtos/qemu-task3/build/images/linux/Image
    aca39d2f58db061f9160a23c36db5fcddd6758eb660ba258a611d37b0d677958  /home/yfblock/Code/hyper-rtos/qemu-task3/build/images/linux/rootfs.cpio
    b8dca160aff6e8803034219f7c6531fbb64809ac1af1505ba659af84b2098e36  /home/yfblock/Code/hyper-rtos/qemu-task3/build/images/rtthread/rtthread.bin
    2cb5da281d088bd7650659db74914aa35642e9e0fc93489c6d7479d369315ca2  /home/yfblock/Code/hyper-rtos/qemu-task3/build/model/model_weights.h
    5e45d6d2ed432b635d4579a0ec011aa29acf6a27ff6e119e290cfc463531513e  /home/yfblock/Code/hyper-rtos/qemu-task3/../protocol/c/include/rt_ipc.h
    0b38c5612d92b43c6b6244ff0d08e745acdcba046fead9824bdb58fce034b747  /home/yfblock/Code/hyper-rtos/qemu-task3/../protocol/c/src/rt_ipc.c
    numpy=2.4.6
    Linux 9950x 6.17.0-40-generic #40~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC Tue Jun 23 16:48:12 UTC 2 x86_64 x86_64 x86_64 GNU/Linux
     01:00:26 up 27 days, 23:43, 3623 users,  load average: 0.45, 0.28, 0.40

Linux 配置为 2 vCPU、256 MiB，负责 Y4M 解码、int8 CNN 推理、RT-IPC 客户端和数据采集。RT-Thread 配置为 1 vCPU、128 MiB，负责 UDP/RT-IPC 服务、幂等控制器和虚拟 PWM/位置执行器。

## CPU 负载分工

Linux 的两个 vCPU 承担推理、网络协议与串口记录，RT-Thread 单 vCPU 承担网络中断、协议处理和控制更新。QEMU TCG 线程由宿主调度，本结果不等价于物理 CPU 硬实时上界。

## 计时方法与误差

Linux 使用 CLOCK_MONOTONIC_RAW 记录推理耗时和发送到状态回传的同侧往返延迟；RT-Thread 使用 AArch64 通用计数器换算处理微秒。两侧时钟未同步，因此不报告伪精确单向延迟。主要误差来自 TCG 调度、虚拟中断、串口输出、计数器量化和宿主负载。

| 指标 (us) | min | mean | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| CNN 推理 | 399 | 712 | 640 | 1040 | 1082 | 2024 |
| 闭环往返 | 203 | 862 | 883 | 1176 | 1359 | 1723 |
| RTOS 处理 | 1 | 37 | 11 | 90 | 109 | 164 |

## 固定基线与 AI 对比

| 模式 | 跟踪误差 mean | p95 | max |
|---|---:|---:|---:|
| 固定参数 | 9809 | 17528 | 18947 |
| AI 控制 | 6065 | 12009 | 13887 |

AI 平均跟踪误差相对固定基线改善 38.17%。分类正确 593/600，准确率 0.988333。

## 可靠性

| 请求 | 成功 | 成功率 | 应用错误 | 超时 | 重连 | 重传 | 重复 | 恢复 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1200 | 1200 | 1.000000 | 0 | 0 | 0 | 72 | 0 | 0 |

重传按发送侧拆分为 Linux 0 次、RT-Thread 72 次；这些重传已由 RT-IPC 透明恢复。有效应用吞吐量为 240 B/s。质量门禁状态：{"ai_tracking_mae_improves_at_least_30_percent": true, "classification_accuracy_at_least_95_percent": true, "success_rate_at_least_99_5_percent": true}。

稳定时间统计：FIXED 方向变化 20 次、满足收敛条件 0 次；AI 方向变化 20 次、满足收敛条件 0 次。成功段的平均/最大帧数分别为 FIXED 0/0，AI 0/0。

## 故障恢复

| 场景 | 结果 | 传输重传 | 重复请求 | 应用错误 | 故障导致的额外控制应用 |
|---|---|---:|---:|---:|---:|
| drop-control | recovered | 1 | 0 | 0 | N/A |
| drop-status | recovered | 1 | 0 | 0 | N/A |
| duplicate-frame | recovered | 0 | 1 | 0 | 0 |
| delayed-server | recovered | 0 | 0 | 0 | N/A |
| malformed | rejected | 0 | 0 | 2 | 0 |

`duplicate-frame` 与 `malformed` 的 `applied_delta` 均为 0，证明重复或非法输入没有造成额外控制动作。`malformed` 的两个应用错误分别来自错误 schema 和错误长度；CRC 损坏包在 RT-IPC 校验层被丢弃。

## 原始证据

- frames.csv: docs/results/evidence/normal/frames.csv
- linux.log: docs/results/evidence/normal/linux.log
- rtthread.log: docs/results/evidence/normal/rtthread.log
- summary.json: docs/results/evidence/normal/summary.json
- fault-summary.json: docs/results/evidence/faults/fault-summary.json
