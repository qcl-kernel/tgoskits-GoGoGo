# C 场景修复回归测试报告

日期：2026-08-21  
测试对象：AxVisor + 2-vCPU Linux + 1-vCPU RT-Thread  运行环境：真实 QEMU 11.0.2，AArch64 `virt`，GICv3，Cortex-A72，TCG

## 1. 测试目的

验证 C 场景此前出现的两类失败已经修复：

1. `mutex_inversion` 偶发缺少样本；
2. Linux 网络探针因共享 UDP socket 中残留控制包而错误重试，导致网络事件测试失败。

同时验证结果门禁不会把 `task2.fault=none` 错误当成强制断连恢复场景。

## 2. 配置

| 项目 | 配置 |
|---|---|
| Linux | 2 vCPU，IP `192.168.77.11` |
| RT-Thread | 1 vCPU，IP `192.168.77.30`，固定到 AxVisor pCPU 2 |
| Linux vCPU | 使用 pCPU 0、1、3，可自由调度 |
| 网络 | virtio-net + IPv4 + UDP + RT-IPC |
| Task 2 | UDP/9876，每种 payload 2 次 |
| Task 3 | FIXED 3 帧 + AI 3 帧 |
| RTBench | 每个指标 2 个样本 |
| QEMU | `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64` |
| QEMU 计数器 | PMU 开启，`-icount shift=3`，记录 ns/cycles/instructions |

## 3. 测试结果

### 3.1 客户机启动

```text
LINUX_SMP_READY configured=2 online=0-1 nproc=2
TASK123_LINUX_NET_READY ip=192.168.77.11 peer=192.168.77.30
RTIPC_SERVER_READY ip=192.168.77.30 port=9876
TASK3_RTOS_READY ip=192.168.77.30 port=9877
```

结果：通过。Linux 的两个 vCPU 均上线，RT-Thread 网络服务正常启动。

### 3.2 Task 2 网络通信

| Payload | 发送/接收 | 超时 | 协议错误 | 重连 | 结果 |
|---:|---:|---:|---:|---:|---|
| 64 B | 2/2 | 0 | 0 | 0 | PASS |
| 256 B | 2/2 | 0 | 0 | 0 | PASS |
| 1024 B | 2/2 | 0 | 0 | 0 | PASS |

```text
RT-IPC client exited with rc=0
TASK2_LINUX_END status=PASS
```

### 3.3 Task 3 AI 闭环

```text
requests=6 successes=6 success_rate=1.000000
classification correct=3 total=3 accuracy=1.000000
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
```

结果：AI 推理、网络传输、RT-Thread 控制和状态回传闭环通过。

### 3.4 RT-Thread 实时性回归

所有指标均满足 `expected=2 collected=2 missing=0`：

| 指标 | P50 | P95 | 最大值 | 结果 |
|---|---:|---:|---:|---|
| `timer_jitter`（第 1 次） | 538064 ns | 860256 ns | 860256 ns | PASS |
| `callback_exec` | 1072 ns | 1072 ns | 1072 ns | PASS |
| `preemption` | 4896 ns | 4896 ns | 4896 ns | PASS |
| `irq` | 1900448 ns | 3505824 ns | 3505824 ns | PASS |
| `irq_to_task` | 3008592 ns | 30069920 ns | 30069920 ns | PASS |
| `irq_disabled_duration` | 3344 ns | 16944 ns | 16944 ns | PASS |
| `mutex_inversion` | 40304 ns | 53776 ns | 53776 ns | PASS |
| `wake_under_load` | 4880 ns | 23690976 ns | 23690976 ns | PASS |
| `net_event_latency` | 54139744 ns | 474024048 ns | 474024048 ns | PASS |

注意：本表只有 2 个样本，适合验证测试链路和修复有效性，不适合估计长期 P99 或 WCET。
TCG 仿真导致的长尾仍然存在，不能据此宣称硬实时保证。

### 3.5 cycles 和 instructions 计数

RTBench 同时读取以下计数器：

- `PMCCNTR_EL0`：虚拟 CPU cycle 计数；
- `PMEVCNTR0_EL0`，事件 `0x08`：指令完成计数；
- `CNTVCT_EL0`：纳秒结果对应的虚拟计时器。

下表是本次真实 QEMU 回归中输出的 P50/P95/max/mean。单位分别为 cycles 和 instructions。

| 指标/运行 | cycles P50 | cycles P95 | cycles max | cycles mean | instructions P50 | instructions P95 | instructions max | instructions mean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `timer_jitter` run 1 | 10568 | 195008 | 195008 | 102788 | 1321 | 24376 | 24376 | 12848 |
| `timer_jitter` run 2 | 349904 | 408056 | 408056 | 378980 | 43738 | 51007 | 51007 | 47372 |
| `timer_jitter` run 3 | 15088 | 105424 | 105424 | 60256 | 1886 | 13178 | 13178 | 7532 |
| `callback_exec` run 1 | 1080 | 1080 | 1080 | 1080 | 135 | 135 | 135 | 135 |
| `callback_exec` run 2 | 1080 | 1080 | 1080 | 1080 | 135 | 135 | 135 | 135 |
| `callback_exec` run 3 | 1080 | 1080 | 1080 | 1080 | 135 | 135 | 135 | 135 |
| `preemption` | 4888 | 4888 | 4888 | 4888 | 611 | 611 | 611 | 611 |
| `irq` | 1536 | 1536 | 1536 | 1536 | 192 | 192 | 192 | 192 |
| `irq_to_task` | 346936 | 956968 | 956968 | 651952 | 43367 | 119621 | 119621 | 81494 |
| `irq_disabled_duration` | 3336 | 16952 | 16952 | 10144 | 417 | 2119 | 2119 | 1268 |
| `mutex_inversion` | 40296 | 53768 | 53768 | 47032 | 5037 | 6721 | 6721 | 5879 |
| `wake_under_load` | 4888 | 873648 | 873648 | 439268 | 611 | 109206 | 109206 | 54908 |
| `net_event_latency` | 1453736 | 19320496 | 19320496 | 10387116 | 181716 | 2415061 | 2415061 | 1298388 |

cycles 和 instructions 结果用于判断延迟对应的 Guest 执行工作量：例如
`net_event_latency` 的长尾同时表现为约 19.3M cycles 和约 2.4M instructions，说明该样本
不只是计时器读数异常，也包含较长的虚拟网络/调度路径。但在 TCG 下，QEMU 对这些 PMU
值进行虚拟化，结果反映的是 QEMU 的确定性指令模型，不是宿主真实硬件 PMU 的物理周期。
因此 cycles/instructions 可以辅助区分路径工作量，不能完全消除 TCG 的调度和设备模拟影响。

关键诊断结果：

```text
RTBENCH_NET_DIAGNOSTIC irq_dropped=0 irq_coalesced=0
probe_received=2 probe_acked=2 probe_no_irq=0 probe_duplicates=0
trigger_socket_failures=0 trigger_send_failures=0
RTBENCH_END status=PASS
```

## 4. 根因与修复

### 4.1 mutex inversion

高优先级 worker 在上一轮结束后可能提前进入下一轮，控制线程尚未完成
`low_acquired` 同步就进入下一轮等待，造成偶发超时和样本缺失。

修复是在每一轮引入 `low_go`，按以下顺序同步：

```text
low_go -> low_acquired -> medium_go -> high_go -> release_now -> high_acquired
```

超时和正常结束路径统一停止并回收 worker。

### 4.2 网络探针

Linux 探针与 RT-Thread 共享 UDP 控制/数据 socket。旧的 READY 或触发包可能滞留在 socket
中，探针只读取一个包时会把旧包误判为当前序号 ACK。

修复内容：

- ACK 等待阶段循环读取 socket；
- 忽略旧控制包、非匹配序号和非 ACK 包；
- 只有真正超时才增加重试次数；
- RT-Thread 不再把 `RTBENCH_NET_READY` 和 `RTBENCH_NET_PROBE_READY` 计为丢失事件。

### 4.3 结果门禁

原门禁无条件要求“request=半数”的强制断连和重连标记，即使实际配置为
`task2.fault=none` 也会失败。

现在：

- `fault=none`：要求三种 payload 的 `reconnects=0`，禁止出现强制断连标记；
- `fault=reliability`：继续要求断连、重连、重传、重复包和乱序包证据。

## 5. 回归验证

通过的测试：

```text
PASS: RT benchmark suite result gate
PASS: Linux network probe is ACK-paced and guest budget covers coexistence RTT
PASS: Task 1/2/3 result gate rejects malformed evidence
PASS: RT-IPC result gate
PASS: Task 1/2/3 runner owns and reaps one AxVisor QEMU
```

真实 QEMU 原始日志：

```text
/home/yfblock/Code/hyper-rtos/tgoskits/tmp/c-final-fixed.FNC0uE/console.log
```

修复后重新执行结果门禁：

```text
PASS: all RT-IPC payload tests completed (2 requests each)
PASS: RT benchmark suite completed (2 samples per metric)
PASS: integrated Task 1/2/3 evidence accepted for mode=realtime-suite
```

另外，真实 QEMU 的结束输出存在 `RTBENCH_END status=PASS\r` 或
`RTBENCH_END status=PASSqemu-system-aarch64: terminating ...` 两种串口边界形态。底层
RTBench verifier 和 Task123 总门禁现已统一归一化这两种边界，并保留严格的 PASS/FAIL
marker 计数。回归夹具和本次 C 原始日志均通过；该改动只修复证据解析，不改变 RTBench
采样或实时性数据。

新增开销指标短时 A/B/C 对照结果见：

```text
comp-docs/task123/report/2026-08-21/tgoskits/rt-thread-realtime-extended-20260821-report.md
tmp/rtthread-realtime-overhead-abcs-20260821/realtime-suite.json
```

## 6. 结论

C 场景的功能性失败已修复：RTBench 样本完整、网络中断探针完整、Task 2/3 通过，最终
`RTBENCH_END status=PASS`。当前结果证明修复有效，但由于本次是快速回归测试，不能替代
300 秒稳定性测试或 100000 样本性能测试；长期实时性结论仍应参考现有 RT-Thread A/B/C
对照报告，并明确 QEMU TCG 对长尾的影响。
