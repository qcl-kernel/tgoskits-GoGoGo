# RT-Thread 实时性隔离对照原始证据（2026-08-19）

本目录保存 Task 1 的 A/B/C 对照原始日志，用于区分三类开销：

- native/：A 组，RT-Thread 直接运行在 QEMU virt 上，无 AxVisor。
- axvisor-rtthread-only/：B 组，AxVisor 只启动 RT-Thread VM。
- axvisor-linux/：C 组，AxVisor 同时启动 2-vCPU Linux VM 与 RT-Thread VM。

三组均使用 300 秒 RTBench、299999 个周期样本，并保持 QEMU
virt/GICv3/Cortex-A72、RT-Thread 5.2.2 和相同的宿主实时控制设置。

## 快速结论

| 场景 | P99 | 最大抖动 | >1ms 次数 | 结论 |
|---|---:|---:|---:|---|
| A native | 10.912 us | 145.696 us | 0 | QEMU TCG 本身未产生毫秒级尾部 |
| B AxVisor + RT-Thread | 18.048 us | 488.032 us | 0 | AxVisor 基础虚拟化开销显著，但仍无毫秒级尾部 |
| C AxVisor + Linux | 396.848 us | 2.803 ms | 2 | 长尾主要来自共存负载/设备模拟/宿主线程调度干扰 |

C 组的 RTBENCH_STABILITY_END status=FAIL 来自严格 1ms 门禁；本轮所有样本均被采集，
无样本缺失。它表示最坏情况延迟超标，不是测试执行失败。

## 文件说明

- summary.csv：机器可读的三组指标。
- native/rtthread-native-300s.log：A 组 RT-Thread 控制台输出。
- native/rtthread-native-300s.qemu.log：A 组 QEMU 辅助日志。
- axvisor-rtthread-only/console.log：B 组 AxVisor + RT-Thread 完整控制台输出。
- axvisor-rtthread-only/results.txt：B 组校验结果和结构化指标。
- axvisor-rtthread-only/metadata.txt：B 组提交、镜像哈希、QEMU 路径和测试时长。
- axvisor-rtthread-only/axvisor-build.log：B 组单 VM AxVisor 构建记录。
- axvisor-linux/console.log：C 组 2026-08-19 12:42 原始控制台输出。
- axvisor-linux/host-metrics.txt：C 组 QEMU 宿主资源采样。

