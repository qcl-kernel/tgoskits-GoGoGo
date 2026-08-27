# RT-Thread 实时性扩展证据（2026-08-21）

本目录保存真实 QEMU 11.0.2/TCG 的 RT-Thread A/B/C 对照复测结果。

- `suite-100000/`：每个实时性指标 100000 个样本；C 场景同时运行 2-vCPU Linux、RT-IPC 和 Task 3。
- `stability-300/`：A/B/C 三组各运行 300 秒，周期任务采集 299999 个样本。
- `SHA256SUMS`：本目录所有证据文件的 SHA-256 校验和。

场景定义：A 为 native RT-Thread，B 为 AxVisor + RT-Thread only，C 为 AxVisor + 2-vCPU
Linux + RT-Thread。RT-Thread vCPU 固定到 AxVisor pCPU 2，Linux vCPU 使用 `{0,1,3}`；
主数据通道为 virtio-net/IP/UDP/RT-IPC，不使用共享内存、HyperCall、裸 MMIO 或 vsock。

结果汇总见同日期的报告：
`history-docs/task123/report/2026-08-21/tgoskits/rt-thread-realtime-extended-20260821-report.md`。
