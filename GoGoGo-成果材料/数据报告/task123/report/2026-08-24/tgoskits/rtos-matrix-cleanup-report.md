# RTOS 矩阵清理与真实 QEMU 验证报告

## 1. 报告信息

| 项目 | 内容 |
|---|---|
| 日期 | 2026-08-24 |
| 项目 | `tgoskits` |
| 分支 | `zypher/rtos` |
| 远端 | `origin/zypher/rtos` |
| 当前提交 | `9b8c629ac77b8931f9ee286cae108ed82796f48c` |
| 提交说明 | `chore(task123): remove temporary RTOS matrix diagnostics` |
| 上游基线 | `origin/dev` |
| QEMU | `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64` |
| QEMU SHA-256 | `5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9` |

当前本地分支和 `origin/zypher/rtos` 的提交一致，工作树清洁。原始
`/home/yfblock/Code/hyper-rtos/tgoskits` 工作树没有被本次清理修改。

## 2. 本次清理内容

本次任务针对 Zephyr/RT-Thread 矩阵测试完成了调试代码和临时代码清理：

- 删除 `TASK123_KEEP_RUNTIME` 及固定 `/tmp` 诊断副本逻辑。
- 删除生命周期失败路径中的 `bash -x`、`BASH_XTRACEFD` 和临时追踪输出。
- 删除未使用的生命周期测试辅助函数。
- 删除仅用于故障注入测试的 `FAKE_QEMU_BENCHMARK_AFTER_LINUX` 变量；保留现有
  `FAKE_QEMU_*` 故障注入接口，避免回归测试失效。
- 删除四个 runner 中的 QEMU `debug-threads=on` 调试参数。
- 修正新增测试脚本的可执行权限。
- 保留 RT-Thread/Zephyr 选择、Linux/StarryOS 选择、Task 2 网络测试、Task 3
  AI 闭环测试和结果门禁。

相对 `origin/dev` 的当前分支规模如下：

| 指标 | 数值 |
|---|---:|
| 变更文件 | 97 |
| 新增行 | 8175 |
| 删除行 | 816 |
| 总变更行 | 8991 |

这组数字是分支整体相对 `origin/dev` 的差异，不是本次最后一个清理提交单独的
差异量。

## 3. 验证范围

已完成以下静态和功能验证：

- Shell 语法检查，以及本次清理提交范围内的 `git diff --check`。
- runner 生命周期、RT-IPC、Zephyr、拓扑、缓存和结果门禁测试。
- AxTask 初始 CPU 放置测试：`3/3` 通过。
- `cargo check -p axvm --lib` 通过。
- 使用真实 `qemu-system-aarch64` 完成 RTOS/应用客户机四组合矩阵。

本次清理提交的差异检查通过：

```text
git diff --check HEAD^ HEAD
cleanup_commit_diff_check=0
```

整个分支相对 `origin/dev` 的差异检查仍会报告历史变更中的空白字符告警，位置
主要在归档文档、RT-Thread patch 和 Zephyr 元数据脚本；这些告警不在本次清理提交
范围内，且没有为清理任务进行无关格式改写。

本次矩阵是 smoke 验证，不等价于长时间实时性压力测试。矩阵记录的参数为：

```text
mode=smoke
stability_seconds=1
task2_count=10
task3_frames=3
qemu_cpu=cortex-a72
qemu_pmu=on
qemu_tcg_thread=multi
qemu_icount=shift=3
rtbench_units=ns,cycles,instructions
```

由于运行在 QEMU TCG 上，矩阵结果只能证明启动、通信、协议恢复和 AI 闭环在该
配置下可复现，不能作为物理板实时性上界。

## 4. 四组合真实 QEMU 结果

证据目录：

```text
/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-rtos-matrix-plan-b/tmp/planb-real-qemu-cleanup-20260824/
```

| RTOS | 应用客户机 | Task 2 | Task 3 | Task 123 | 结果门禁 | QEMU 退出 | 备注 |
|---|---|---|---|---|---|---:|---|
| RT-Thread | Linux | PASS | PASS | PASS | PASS | 0 | 6/6 请求成功，无重传 |
| RT-Thread | StarryOS | PASS | PASS | PASS | PASS | 0 | 6/6 请求成功，无重传 |
| Zephyr | Linux | PASS | PASS | PASS | PASS | 0 | 6/6 成功，发生自动重连和重传 |
| Zephyr | StarryOS | PASS | PASS | PASS | PASS | 0 | 6/6 成功，发生自动重连和重传 |

四个组合均以 `termination_reason=marker-complete` 完成，未使用 fake QEMU。

### 4.1 Task 3 应用层数据

| RTOS | 应用客户机 | 请求成功率 | 分类准确率 | 推理耗时均值 | RTT 均值 | RTOS 处理耗时均值 | 有效吞吐 |
|---|---|---:|---:|---:|---:|---:|---:|
| RT-Thread | Linux | 100% | 100% | 831 us | 2611 us | 114 us | 321 B/s |
| RT-Thread | StarryOS | 100% | 100% | 614 us | 5471 us | 248 us | 308 B/s |
| Zephyr | Linux | 100% | 100% | 504 us | 2184172 us | 110 us | 8 B/s |
| Zephyr | StarryOS | 100% | 100% | 809 us | 2190052 us | 112 us | 8 B/s |

RT-Thread 两组均无应用超时、重连、重复包和传输重试。Zephyr 两组均最终完成，
但各有 7 次应用超时、104 次传输重试、4 个重复包、8 次重连和 5 次恢复；这说明
当前恢复机制有效，但 Zephyr 组合的网络路径仍有明显长尾，不能与 RT-Thread
组合直接视为同等性能。

Task 3 的固定控制和 AI 控制在本次 3 帧 smoke 数据中的 tracking error 均为：

```text
min=0, mean=1453, p50=1461, p95=2900, p99=2900, max=2900 (Q15)
```

样本量很小，且本次门禁未强制要求 AI 相对固定控制的误差改善；因此该数据仅用于
闭环连通性和结果格式验证。

### 4.2 主机运行数据

以下数据来自各组合的 QEMU 进程采样，采样间隔为 100 ms：

| 组合 | 运行时间 | QEMU CPU 时间 | 峰值 RSS | 最大线程数 | 采样数 |
|---|---:|---:|---:|---:|---:|
| RT-Thread + Linux | 6.17 s | 12.53 s | 1293952 KB | 7 | 60 |
| RT-Thread + StarryOS | 11.72 s | 20.33 s | 1345168 KB | 7 | 114 |
| Zephyr + Linux | 37.50 s | 38.93 s | 387420 KB | 7 | 365 |
| Zephyr + StarryOS | 41.12 s | 43.39 s | 425252 KB | 7 | 400 |

## 5. 代码质量与测试限制

`cargo check -p axvm --lib` 已通过。`cargo test -p axvm` 未作为通过项报告，原因
是该 crate 的 host 测试链接阶段依赖裸机目标符号，例如 `STACK_SIZE`、`PAGE_SIZE`
和 `__PERCPU_TEMPLATE_*`；这属于测试目标/链接环境限制，不是本次清理新增的编译
错误。后续应在适配的 AxVisor 目标或专用链接配置下补充该 crate 的单元测试执行。

另外，矩阵 manifest 中 `qemu_vcpu_affinity` 和主机 QEMU CPU affinity 为空，说明
本次矩阵验证没有把 QEMU 进程固定到指定物理 CPU。RTOS 亲和性和实时性专项测试
仍应使用独立的 host affinity、vCPU/物理 CPU 分区和长时间 stability 配置，不能
使用本报告的 smoke 数据代替。

## 6. 结论

本次清理已完成并提交到 `origin/zypher/rtos`。调试专用输出和临时代码已移除，
RT-Thread/Zephyr 双 RTOS 与 Linux/StarryOS 双应用客户机的真实 QEMU 启动、网络
通信、Task 3 AI 闭环和结果门禁均保持可用。

当前结论是“功能回归通过”，而不是“实时性已达标”：RT-Thread 矩阵网络恢复开销
较小，Zephyr 矩阵存在显著网络长尾；两者都需要在物理板和固定 CPU 配置下进行
长时间实时性测试后，才能形成最终实时性能结论。
