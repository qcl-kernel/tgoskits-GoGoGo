# RT-Thread 实时性正式证据

本目录保存 2026-08-20 A/B/C 正式 suite 的原始输出和摘要：

- A：native RT-Thread on QEMU；
- B：AxVisor + RT-Thread only；
- C：AxVisor + 2-vCPU Linux + RT-Thread。

每个场景的 suite 使用 100000 个样本。C 额外运行 Linux/RT-Thread 的 Task 2、Task 3 和
100000 次 ACK 驱动 UDP 网络 probe。`comparison.json` 和 `comparison.csv` 由
`os/axvisor/scripts/summarize_rtthread_realtime.py` 生成，B 的网络指标按设计标记为
不适用，因为 AxVisor-only 没有 peer guest。

关键 C 结果：

```text
Linux SMP: configured=2 online=0-1 nproc=2
RTBENCH_END status=PASS
net_event_latency: expected=100000 collected=100000 missing=0
RTBENCH_NET_DIAGNOSTIC irq_dropped=0 probe_received=100000 probe_acked=100000
Task2: 64B/256B/1024B all 30000/30000
Task3: 6/6, classification 3/3
```

所有归档文件的 SHA-256 在 `SHA256SUMS` 中。测试运行于 x86_64 宿主的 AArch64 QEMU
TCG，数据用于相对比较和路径定位，不构成物理硬实时 WCET 证明。
