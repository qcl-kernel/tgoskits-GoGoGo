# StarryOS 与 Linux 长时稳定性对比设计

## 目标

在同一 AxVisor、QEMU 和 RT-Thread 环境中，分别运行两 vCPU Linux 与两 vCPU
StarryOS 应用客户机，完成 300 秒快速稳定性回归和 3600 秒正式稳定性测试，并生成
机器可读数据和中文对比报告。

## 公平性约束

- 两次运行使用相同的 QEMU 可执行文件、machine、CPU 型号、4 个物理 CPU、8 GiB
  内存和两个 virtio-net 外部端点。
- 应用客户机均为 2 vCPU、512 MiB、初始放置在物理 CPU 0/1，可在 CPU 0/1/3
  上运行；RT-Thread 为 1 vCPU、256 MiB，固定在物理 CPU 2。
- 两次运行复用同一个 RT-Thread 二进制、模型、协议源码、Linux 应用二进制来源和
  AxVisor rootfs。只有应用客户机内核和其必需的 rootfs 表示不同。
- 两次运行使用相同 `task2.count`、`task3.frames=3`、
  `task3.fault=normal` 和 `rtbench_stability` 时长。
- 比较顺序固定为 Linux 后 StarryOS，并在报告中明确该顺序可能带来的宿主热状态误差。

## 运行模式

- `quick`：300 秒 RT-Thread 稳定性基准，Task2 每种载荷 30000 次。
- `full`：3600 秒 RT-Thread 稳定性基准，Task2 每种载荷 240000 次。

Task2 数量保证应用客户机在稳定性窗口内持续产生网络负载。若应用客户机提前完成，
结果门禁应拒绝缺少稳定性样本的运行；若网络工作负载晚于稳定性窗口结束，runner
继续等待应用客户机正常完成后再结束。

## 统一 runner

`run_task123.sh` 增加 `--app-guest linux|starryos`，默认保持 `linux`，避免破坏现有
调用者。runner 根据客户机类型选择 VM 配置生成器、启动标记和结果门禁标记。
StarryOS 镜像由固定的 Linux Task123 initramfs 中提取相同应用程序后构建，因此两端
执行同一套 RT-IPC 和 Task3 用户态程序。

运行目录保存：

- `console.log`：完整 AxVisor/QEMU 串口日志；
- `app.log` 和 `linux.log` 或 `starryos.log`：认证后的 VM 1 日志；
- `rtthread.log`：认证后的 VM 3 日志；
- `frames.csv`、`summary.raw.json`、`summary.json`：Task3 数据；
- `host-metrics.txt`：QEMU 墙钟、CPU 时间、峰值 RSS 和最大线程数；
- `manifest.txt`：客户机类型、输入参数和所有输入镜像摘要。

## 指标与门禁

网络指标按 64、256、1024 字节分别统计成功率、RTT min/avg/P50/P95/P99/P99.9/max、
有效吞吐量、超时、协议错误、重传、重复包和乱序包。Task3 统计推理时延、控制 RTT、
成功率和错误计数。RT-Thread 统计稳定性 jitter 与 callback execution 的 P50/P95/P99/
P99.9/max、均值和 100 us/500 us/1 ms 超限次数。

长时稳定性通过条件为：请求完整、应用错误和超时为零、Task3 成功、RTBench 样本完整、
`miss_1ms=0`、无 panic/assert/fatal、QEMU 正常由结果标记终止。性能比较只报告测量值和
StarryOS 相对 Linux 的百分比差异，不把 QEMU TCG 数据表述为物理硬实时上界。

## 结果输出

`run_task123_guest_comparison.sh` 依次运行两个客户机，并调用 Python 分析器生成
`comparison.json` 和 `comparison-report.md`。正式报告同时记录主机信息、Git 提交、
测试命令、时长、输入摘要和已知误差来源。
