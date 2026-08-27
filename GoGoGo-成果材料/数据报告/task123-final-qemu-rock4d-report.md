# Task123 最终 QEMU 与 ROCK 4D 验证报告

## 1. 报告信息

| 项目 | 内容 |
|---|---|
| 日期 | 2026-08-25（首版）；2026-08-27（rebase 后重新采集，本版数据） |
| 数据采集时分支 | `dev`（合并提交 `88084dd2a`，Task123 功能提交 `93c2d0e31`） |
| 当前基线分支 | `upstream/pr-new`（集成提交 `87eb3fcc5`，适配提交 `621a063a9`） |
| 当前基线 | upstream/dev `ba252ca67` |
| 测试范围 | QEMU 四组合 + ROCK 4D 真机四组合 |
| 数据目录 | `GoGoGo-成果材料/图标数据/` |

> 注：本版数据于 2026-08-27 在 `upstream/pr-new`（`87eb3fcc5` + `621a063a9`，
> 基于 upstream/dev `ba252ca67`）重新采集，覆盖 8-25 在当时 `dev` 分支
> （`88084dd2a` / `93c2d0e31`）的首版数据。rebase 适配的四个修复（vCPU 独占
> pinning、virtio-mmio QEMU vendor 身份、busy WFI fastpath 禁用、host-SPI 风暴
> 熔断）见提交 `621a063a9` 的说明；其中 busy WFI fastpath 禁用使 ROCK 4D 上
> RT-Thread 组合的 timer jitter 较 8-25 首版略有变化（p99 28,750 ns vs 33,375
> ns，量级一致）。物理串口偶发的记录截断沿用首版的 retry 合并策略：每个组合
> 保留主日志加 retry 日志，解析器只收完整记录并去重。

本报告替代此前“ROCK 4D 在 guest 启动前阻塞”和“物理板 RTOS guest 为占位镜像”的
阶段性结论。旧报告仍保留用于记录历史排障过程，不能与本轮最终数据混用。

## 2. 组合门禁

每个组合均运行 Task 2、Task 3 和 Task123 完整流程；Task 3 使用 3 帧固定/AI 控制
样本，RTBench 请求数为 10。所有组合均以 `status=PASS` 完成：

| 平台 | RTOS | 应用客户机 | Task 2 | Task 3 | Task123 | Task 3 请求 | 分类准确率 |
|---|---|---|---|---|---|---:|---:|
| QEMU | RT-Thread | Linux | PASS | PASS | PASS | 6/6 | 3/3 |
| QEMU | RT-Thread | StarryOS | PASS | PASS | PASS | 6/6 | 3/3 |
| QEMU | Zephyr | Linux | PASS | PASS | PASS | 6/6 | 3/3 |
| QEMU | Zephyr | StarryOS | PASS | PASS | PASS | 6/6 | 3/3 |
| ROCK 4D | RT-Thread | Linux | PASS | PASS | PASS | 6/6 | 3/3 |
| ROCK 4D | RT-Thread | StarryOS | PASS | PASS | PASS | 6/6 | 3/3 |
| ROCK 4D | Zephyr | Linux | PASS | PASS | PASS | 6/6 | 3/3 |
| ROCK 4D | Zephyr | StarryOS | PASS | PASS | PASS | 6/6 | 3/3 |

Task 3 的固定控制和 AI 控制样本均记录 `Q15 min=0, mean=1453, p50=1461,
p95=2900, p99=2900, max=2900`。这组 3 帧数据用于闭环和协议门禁，不作为长时间
控制质量或模型精度结论。

## 3. RTBench 纳秒指标

八个组合都输出完整的 16 项指标：`timer_jitter`、`callback_exec`、`preemption`、
`irq`、`irq_to_task`、`irq_disabled_duration`、`mutex_inversion`、`wake_under_load`、
`context_switch`、`scheduler_decision`、`sync_sem`、`sync_mutex`、`sync_mailbox`、
`irq_handler_exec`、`deadline_miss_under_load` 和 `net_event_latency`。

| 平台/RTOS/客户机 | 指标数 | 样本完整性 | timer jitter p99（ns，轮次最大值） |
|---|---:|---|---:|
| QEMU / RT-Thread / Linux | 16 | 10/10，missing=0 | 244,720 |
| QEMU / RT-Thread / StarryOS | 16 | 10/10，missing=0 | 493,312 |
| QEMU / Zephyr / Linux | 16 | 10/10，missing=0 | 1,295,168 |
| QEMU / Zephyr / StarryOS | 16 | 10/10，missing=0 | 797,104 |
| ROCK 4D / RT-Thread / Linux | 16 | 10/10，missing=0 | 28,750 |
| ROCK 4D / RT-Thread / StarryOS | 16 | 10/10，missing=0 | 29,334 |
| ROCK 4D / Zephyr / Linux | 16 | 10/10，missing=0 | 2,084,375 |
| ROCK 4D / Zephyr / StarryOS | 16 | 10/10，missing=0 | 2,083,166 |

图表只使用纳秒字段并按完整样本筛选；没有用 `16`、`0` 或复制其它指标来填充缺失
值。图中出现的 `16` 仅在实际测量值为 16 ns 时保留。PMU cycles/instructions 不
参与跨平台完整性判断，因为当前 QEMU 与 ROCK 4D 的 PMU 虚拟化条件不一致。

## 4. 数据与复现入口

- 独立复现指南：[task123-reproduction-cn.md](../task123-reproduction-cn.md)
- 图表入口：[图标数据/index.html](../图标数据/index.html)
- 生成脚本：[图标数据/plot_task123.py](../图标数据/plot_task123.py)
- 纳秒明细：[图标数据/rtbench-metrics.csv](../图标数据/rtbench-metrics.csv)
- 完整解析数据：[图标数据/parsed-data.json](../图标数据/parsed-data.json)
- QEMU 与 ROCK 4D 原始串口日志：分别位于 `图标数据/qemu/` 和 `图标数据/rock4d/`

重新生成图表：

```bash
python3 GoGoGo-成果材料/图标数据/plot_task123.py
```

QEMU 和真机使用各自的入口命令；真机命令必须显式提供个人的
`rock-4d-uboot-local.toml`，其中串口设备和电源/复位命令属于本机环境，不纳入成果
材料。

## 5. 结论边界

QEMU 的 host CPU/RSS 采样仅适用于 QEMU 组合；ROCK 4D 的 host 资源列显示为 NA 是
因为真机没有 QEMU 进程采样器，不代表 RTBench 指标缺失。ROCK 4D 纳秒结果是真机
串口采集，可用于硬件相对比较；QEMU TCG 数据仍不能作为物理板硬实时 WCET 上界。
