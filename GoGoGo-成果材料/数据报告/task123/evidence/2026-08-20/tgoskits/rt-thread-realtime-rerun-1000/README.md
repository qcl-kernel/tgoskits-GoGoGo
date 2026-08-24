# RT-Thread 1000 样本同批次复测证据

日期：2026-08-20

本目录保存 native RT-Thread、AxVisor-only 和 AxVisor + 2-vCPU Linux 三组真实 QEMU
复测结果。三组均使用 1000 个样本；B 场景使用 `benchmark_core`，因为 AxVisor-only
没有第二个客户机，跨客户机 `net_event_latency` 在 B 中不适用。

平台为 QEMU 11.0.2、AArch64 `virt`、Cortex-A72、TCG，QEMU 路径为：

`/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`

结果摘要：

- A native：所有核心指标和 native 网络探针 `1000/1000`；严格尾部通过。
- B AxVisor-only：所有核心指标 `1000/1000`；网络指标 N/A；严格尾部通过。
- C AxVisor + 2-vCPU Linux：所有核心指标和网络探针 `1000/1000`；Linux 标记为
  `configured=2 online=0-1 nproc=2`；`RTBENCH_END status=PASS`，但严格尾部不通过。

`comparison.md`、`comparison.json` 和 `comparison.csv` 由同一个汇总器从三组原始日志
生成。C 的网络事件 P99 为 2.462 ms、最大值为 4.692 ms；该长尾应结合 QEMU TCG
主循环、虚拟中断/设备模拟和宿主调度解释，不能直接作为物理硬件 WCET。

这轮复现命令见报告文件；正式 100000 样本结果仍以同日期的
`rt-thread-realtime-extended-report.md` 为准。
