---
sidebar_position: 4
sidebar_label: "Task 1/2/3 实验"
---

# AxVisor Task 1/2/3 实验

`cargo xtask axvisor task123` 是 Task 1（实时性）、Task 2（客户机网络通信）和
Task 3（AI 控制闭环）的统一入口。它使用真实的 `qemu-system-aarch64` 启动 AxVisor；
不会使用 fake QEMU。根目录的 `run-task123.sh` 只是兼容入口，最终执行同一个 cargo
命令。

## 1. 组合

任务支持两个 RTOS 和两个应用客户机，共四种组合：

| RTOS | 应用客户机 | 用途 |
| --- | --- | --- |
| RT-Thread | Linux | 默认基线 |
| RT-Thread | StarryOS | 宏内核替代 Linux |
| Zephyr | Linux | 第二种 RTOS 基线 |
| Zephyr | StarryOS | 完整矩阵组合 |

Linux 和 StarryOS 均按 2-vCPU 配置启动；RTOS 使用独立 VM 配置。客户机之间通过
`virtio-net` 和 IP 协议栈通信，Task 2 使用 RT-IPC 请求/响应，Task 3 使用 AI 输出
驱动控制消息和状态回传。

## 2. 快速验证

快速矩阵用于确认四种组合都能构建、启动并完成 Task 1/2/3 的短流程，不用于产生
正式实时性能结论：

```bash
cargo xtask axvisor task123 \
  --quick \
  --matrix all \
  --task2-count 10 \
  --output tmp/task123-xtask-matrix-smoke
```

每个组合只运行短 smoke profile。完成后查看：

```text
tmp/task123-xtask-matrix-smoke/matrix-summary.json
tmp/task123-xtask-matrix-smoke/matrix-report.md
tmp/task123-xtask-matrix-smoke/rtthread-linux/summary.json
tmp/task123-xtask-matrix-smoke/zephyr-starryos/summary.json
```

`matrix-report.md` 汇总每个组合的 Task 2/3/123 状态、Task 3 成功率和可用的 RTBench
字段。quick 模式不主动运行长时间 RTBench，因此实时列可能显示 `-`。

单个组合可以减少实验范围，例如：

```bash
cargo xtask axvisor task123 \
  --quick --rtos rtthread --app-guest linux \
  --task2-count 10 --output tmp/task123-rtthread-linux-smoke
```

## 3. 实时性能套件

使用 `--realtime-suite` 执行 RTOS 侧实时性测试，并同时保留 Task 2/3 网络负载：

```bash
cargo xtask axvisor task123 \
  --realtime-suite \
  --matrix all \
  --rtbench-samples 1000 \
  --task2-count 100 \
  --output tmp/task123-xtask-realtime
```

正式长测可以把样本数和 Task 2 请求数调大。精确 PMU/虚拟计数器实验使用 QEMU
precise icount 和单线程 TCG，可能比墙钟时间慢很多；普通主机上的 AArch64 TCG
长尾不能直接等价为物理板的硬实时上界。

RTBench 日志中应重点检查以下指标：

- `timer_jitter`：周期任务抖动，包含 `p50/p95/p99/p99_9/max` 的纳秒、cycles
  和 instructions 数据。旧版 RTBench 日志可能使用 `stability_jitter`，矩阵汇总会
  兼容读取这两个字段；
- `callback_exec`：周期回调执行开销；
- `preemption`、`irq`、`irq_to_task`：抢占、硬件中断和中断到任务唤醒延迟；
- `irq_disabled_duration`、`mutex_inversion`、`wake_under_load`：关中断、锁反转和
  负载下唤醒的长尾；
- `net_event_latency`：网络事件到任务处理的延迟。

各组合原始数据位于 `<output>/<rtos>-<app-guest>/`：

```text
summary.json       Task 3 应用层汇总
<app-guest>.log    Linux/StarryOS Task 2/3 日志
<rtos>.log         RTBench 原始输出
frames.csv         Task 3 每帧结果
manifest.txt       镜像、配置和结果门禁
host-metrics.txt   QEMU 墙钟、CPU、RSS 和线程采样
```

## 4. 复现和缓存

默认会复用 `tmp/source-cache` 中已经校验过的 RTOS、Linux/rootfs、协议和模型构建
产物。也可以显式指定输出和共享缓存：

```bash
cargo xtask axvisor task123 \
  --quick --matrix all \
  --cache tmp/task123-artifact-cache \
  --output tmp/task123-matrix
```

`--output` 必须为空目录；`--cache` 用于四次组合间共享构建产物。`RTTHREAD_IMAGE`
和 `RTTHREAD_IMAGE_META` 可以用于指定已经构建并带元数据校验的 RT-Thread 镜像，
通常不需要手工设置。

## 5. 入口边界

Rust `xtask` 负责命令参数校验、组合展开、输出目录策略、共享缓存传递、真实 QEMU
runner 的前台执行以及矩阵 JSON/Markdown 汇总。QEMU 生命周期、guest 串口 marker、
资源采样和结果门禁仍由现有 AxVisor runner 完成；这些脚本是实现细节，不是用户需要
直接调用的入口。

验证入口和契约测试：

```bash
cargo fmt --all -- --check
cargo check -p axbuild --lib
cargo test -p axbuild axvisor --lib
os/axvisor/scripts/test_task123_guest_comparison.sh
os/axvisor/scripts/test_qemu_realtime_controls.sh
```
