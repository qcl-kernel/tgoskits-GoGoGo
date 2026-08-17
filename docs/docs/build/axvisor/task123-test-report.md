# AxVisor 任务一、二、三集成测试报告

> 测试日期：2026-08-17
>
> 分支：`feat/axvisor-task123`
>
> 受测 runtime 提交：`7e25b6ceeb8a1613705b90d47969482479a10dda`
>
> RTOS：RT-Thread 5.2.2，固定提交
> `ddf52e2cdd977f14fc04035c88672ac204aec713`
>
> 虚拟平台：QEMU 11.0.2 TCG / AArch64 `virt`

报告提交晚于受测 runtime commit；其后的变更仅为报告、文档契约和导入历史
日志的行尾空格，不改变任何可执行代码、配置、镜像或运行参数。

## 1. 总体完成度

| 任务 | 完成度 | 当前验收 | 结论 |
|---|---:|---|---|
| Task 1 | 95% | 有条件通过 | 改造、2-vCPU Linux、RTOS 基线及完整采样已完成；严格长稳门禁未通过 |
| Task 2 | 100% | PASS | VirtIO-net/IPv4/UDP/RT-IPC v2 双向通信、分帧、ACK/重传/去重/重连与当前运行证据完整 |
| Task 3 | 100% | PASS | 600 FIXED + 600 AI、控制回传及 5 个故障配置均在 AxVisor 下通过 |

这里的百分比表示当前需求、实现和可复现证据覆盖率。Task 1 不宣称硬实时：
普通 Ubuntu + QEMU TCG 的四轮 300 秒严格门禁仍有 1 ms 以上离群值。

## 2. 集成架构

```text
Linux VM[1], 2 vCPU, 192.168.77.11/24
  Task 2 client : UDP 9876 / RT-IPC v2
  Task 3 model  : UDP 9877 / RT-IPC v2
                   |
         AxVisor virtio-net + internal L2 switch
                   |
RT-Thread VM[3], 1 vCPU on pCPU 2, 192.168.77.30/24
  Task 2 server : UDP 9876
  Task 3 control: UDP 9877
```

应用数据只经过 virtio-net、IPv4、UDP 和 RT-IPC v2。禁止使用共享内存、
HyperCall、raw MMIO、vsock、宿主用户态 relay 或其他非网络应用数据通道
承载控制、状态或模型输出。

RT-IPC v2 头包含版本、消息类型、20 字节头长度、payload 长度、session ID、
序号、ACK 和 CRC。UDP 可靠性由累计 ACK、超时重传、乱序窗口、重复抑制、
heartbeat、FIN 和断连重连共同实现。

## 3. Task 1 结果

1000 样本综合轮的 timer、preemption 和 IRQ 均为 `miss_1ms=0`。四轮
300 秒测试均完整采集 `299999/299999`，但最坏抖动分别为 3.636208、
2.722352、5.406368 和 2.353616 ms，对应 14、4、29、2 个 1 ms 超限样本。
详细分位数、短时 timer slack A/B 和 QEMU TCG 根因见
`rtthread-realtime-report.md`。

结论是 AxVisor Busy-WFI 根因已经修复，剩余长尾主要在 QEMU timer assert
或 TCG 调度边界。当前环境不能证明 1 ms WCET，所以 Task 1 保持 95%。

## 4. Task 2 结果

当前 HEAD 的 `task3-normal` 运行在启动 Task 3 前先完成 Task 2：

| 载荷 | sent/recv | avg/P95/max RTT | 吞吐量 | 超时/协议错误 |
|---|---:|---:|---:|---:|
| 64 B | 1000/1000 | 3/4/30 ms | 17.26 KiB/s | 0/0 |
| 256 B | 1000/1000 | 1/3/11 ms | 108.55 KiB/s | 0/0 |
| 1024 B | 1000/1000 | 2/3/31 ms | 359.07 KiB/s | 0/0 |

64 B 阶段在请求 500 强制断连，恢复耗时 221 ms、一次重连成功，未丢请求。
四轮 300 秒实时性运行中的网络侧也都完成 `90000/90000`。协议单元测试覆盖
丢包重传、乱序、重复包、stale ACK、heartbeat、session 重建和可靠 FIN。

## 5. Task 3 正常场景

命令：

```bash
os/axvisor/scripts/run_task123.sh \
  --mode task3 --task3-frames 600 \
  --output tmp/task123-results/task3-normal
```

manifest 记录 `raw_qemu_exit=0`、`termination_reason=marker-complete` 和
`result_gate=PASS`。CSV 行数是 600 FIXED + 600 AI。

| 指标 | 结果 |
|---|---:|
| 请求成功 | 1200/1200，100% |
| 应用错误 | errors=0 |
| 应用超时 | timeouts=0 |
| 传输重试 | retries=0 |
| 重复请求 | duplicates=0 |
| 重连 | reconnects=0 |
| 模型准确率 | 593/600=98.8333% |
| 推理 mean/P95/P99/max | 607/903/1042/1520 us |
| 同侧请求 RTT mean/P95/P99/max | 6142/30784/30954/31522 us |
| RTOS 处理 mean/P95/P99/max | 95/267/289/320 us |
| fixed tracking MAE | 9809 |
| AI tracking MAE | 6065 |
| MAE 改善 | 38.17% |
| 有效应用 payload | 240 B/s |

AI 在相同输入序列下把平均跟踪误差从 9809 降到 6065，超过 30% 门禁。
分类准确率和请求成功率也分别超过 95% 和 99.5% 门禁。

`settling successes=0`：两个模式都检测到 20 次方向变化，但测试窗口内没有
满足连续稳定阈值的事件，因此未形成有效稳定时间结论。该字段没有被当作 0 帧
稳定时间或 AI 优势使用。

## 6. Task 3 故障场景

每个配置都独立启动一轮 AxVisor；五个 manifest 均为 `result_gate=PASS`。

| 配置 | 预期行为 | 观测 | 状态 |
|---|---|---|---|
| drop-control | 客户端丢首个控制包后重传 | recovered，retry=1，6/6 | PASS |
| drop-status | RTOS 丢首个状态包后重传 | recovered，retry=1，6/6 | PASS |
| duplicate-frame | 重复帧不能重复施加控制 | recovered，RTOS duplicates=1，applied_delta=0 | PASS |
| delayed-server | 服务延迟 3000 ms 后连接恢复 | recovered，6/6 | PASS |
| malformed | schema/短包/CRC 错误全部拒绝 | rejected，application errors=2，applied_delta=0 | PASS |

汇总文件：`task3-faults/fault-summary.json`。畸形包没有改变 actuator，
重复帧也没有导致第二次控制应用。

## 7. 延迟口径

Linux 使用 `CLOCK_MONOTONIC_RAW` 测量模型推理和同侧请求-响应 RTT，
因此 RTT 包含 Linux 发送、VirtIO-net、AxVisor、RTOS 协议/控制处理和返回路径。
RTOS 使用 AArch64 architectural counter 测量自身处理时间。

两个客户机时钟没有同步到可证明的一致误差范围，所以本报告不声明单向跨 guest latency。
端到端指标采用 Linux 同侧 RTT，误差主要来自时钟读取、QEMU TCG 调度和虚拟中断排队。

## 8. 原始数据与哈希

| 文件 | SHA-256 |
|---|---|
| `task3-normal/manifest.txt` | `0eb333c1c83b3d596fdc48022529a844922db3da439948bfe246d353fb8f95e6` |
| `task3-normal/summary.json` | `11fa72c85130635d0ca939c25d90a1df4bf21501deb34fdfef005db7e7a2f0aa` |
| `task3-normal/frames.csv` | `aaedefbe5599c172543f67dea56df4b7a996546c76b263455573fc0ea7f5e2e7` |
| `task3-normal/console.log` | `005ae9526cfba29c43b0f62a81292c1eead483ca44b63f76c3ccee2c96774147` |
| `realtime-suite-r5-final/manifest.txt` | `ee54a3d3da08eeb5a0c07cad991644eb0899facc8bfe8d0c7b9969f42a125179` |
| `stability-300s/console.log` | `ddfda7b2051d95af499f720ba4f29eda702a51dd8d4881d91854092bba967e91` |
| `stability-300s-r2-timerslack1/console.log` | `7daba98a12278352bb927f11241e22cb4fa11a000c7601959d030452ddc8f882` |
| `stability-300s-r3-timerslack1/console.log` | `31ce71aaf87d6916da50aefc2b80afcc3cfa172d8eeebbfe2b7a98e1a33f8574` |
| `stability-300s-r4-low-host-load/console.log` | `32a567eb8fd3544175bc97999804fc5dcd349625549d8840f5e0d2de7dcc6dc8` |
| `task3-faults/fault-summary.json` | `55fa19d2206012f6a7278363ce05d92f2b513caa60930bdb70474dc82a8cd0f8` |

完整原始证据在共享工作区的
`tmp/task123-results/task123-evidence-7e25b6cee.tar.gz`，SHA-256 为
`5e2f220eeb7e22bbd540172c77d9818a606f9d0228e81ae8025acc792c5a62ba`。
归档不进入 Git，但可在当前工作区直接读取和复核。

## 9. 需求到证据映射

| requirement | implementation/config | verification command | accepted artifact/marker | status |
|---|---|---|---|---|
| Task 1 topology | Linux 2 vCPU `0b1011`，RTOS `0b0100` | `test_task123_topology.sh` | `LINUX_SMP_READY configured=2` | PASS |
| Task 1 memory/device | 512/256 MiB、双 virtio-net、VGIC SPI | `test_task123_topology.sh` | generated VM TOML + manifest | PASS |
| Task 1 timer | absolute deadline、hard timer、busy WFI | `--mode realtime-suite` | timer run 1/2/3，`missing=0` | PASS |
| Task 1 callback execution | hard-timer callback 独立采样 | `--mode realtime-suite` | callback_exec run 1/2/3 | PASS |
| Task 1 preemption | 高优先级线程唤醒延迟 | `--mode realtime-suite` | preemption 1000/1000 | PASS |
| Task 1 SGI interrupt | redistributor pending 到 guest ISR | `--mode realtime-suite` | IRQ/SGI 1000/1000 | PASS |
| Task 1 long stability | 300 s/299999 samples | `--mode stability --seconds 300` | 四轮完整 log | FAIL: 1 ms 门禁 |
| Task 1 CPU load | QEMU TCG 线程采样 | 300 秒 CPU load collector | vCPU0/1、pCPU2/3 分布 | PASS |
| Task 1 RTOS baseline | 原生同 QEMU RT-Thread 5.2.2 | `run_rtthread_native_baseline.sh` | native 300 s baseline | PASS |
| Task 2 IP topology | 192.168.77.11 与 192.168.77.30，同 /24 | `--mode smoke` | NET_READY + ARP/UDP traffic | PASS |
| Task 2 protocol fields | RT-IPC v2 20-byte header、session/seq/ACK/CRC | `make -C os/axvisor/guests/rt-ipc/tests test` | protocol 21/21 | PASS |
| Task 2 bidirectional RT-IPC | UDP 9876 request/status | `--mode task3 --task3-frames 600` | `TASK2_LINUX_END status=PASS` | PASS |
| Task 2 64-byte load | 1000 requests | current-head Task 2 | 1000/1000，17.26 KiB/s | PASS |
| Task 2 256-byte load | 1000 requests | current-head Task 2 | 1000/1000，108.55 KiB/s | PASS |
| Task 2 1024-byte load | 1000 requests | current-head Task 2 | 1000/1000，359.07 KiB/s | PASS |
| Task 2 timeout/retransmit | ACK、RTO、重传、乱序和去重 | RT-IPC loopback/fault tests | loss/reorder/retry tests | PASS |
| Task 2 disconnect recovery | 重连和可靠 FIN | 当前 Task 2 64 B 阶段 | reconnect complete，221 ms | PASS |
| Task 3 AI inference | 量化 CNN 600 帧 | `--mode task3 --task3-frames 600` | accuracy 593/600 | PASS |
| Task 3 network control | 模型输出经 UDP 9877 到 RTOS | 同上 | 1200/1200，RTOS FINAL | PASS |
| Task 3 observable output | RTOS controller 更新 actuator 并回传 status | 同上 | frames.csv control/status 列 | PASS |
| Task 3 fixed baseline | 同输入 FIXED 600 帧 | 同上 | MAE 9809 | PASS |
| Task 3 AI improvement | 同输入 AI 600 帧 | 同上 | MAE 6065，改善 38.17% | PASS |
| Task 3 request gate | success >=99.5% | `verify_task123_results.sh` | 100% | PASS |
| Task 3 accuracy gate | accuracy >=95% | `summarize.py` | 98.8333% | PASS |
| Task 3 tracking gate | MAE 改善 >=30% | `summarize.py` | 38.17% | PASS |
| Task 3 clock method | Linux RTT + RTOS processing | summary/frames extractor | CLOCK_MONOTONIC_RAW + architectural counter | PASS |
| Task 3 settling | 连续稳定阈值 | `summarize.py` | successes=0 | 无有效结论 |
| Task 3 faults | 五种真实故障配置 | `--mode task3-fault` | `task3-faults/fault-summary.json` | PASS |

## 10. 源树隔离约束

原始 `/home/yfblock/Code/hyper-rtos/tgoskits` 和 `qemu-task3` 仅作为只读输入。
实现、测试生成物和文档提交都位于独立 worktree；最终审计只读取源 checkout
的 HEAD、状态和 diff 指纹，不重置、清理、暂存或修复原始目录。现场瞬时指纹
属于本次执行记录，不作为可复现测试报告的固定基线。
