# 任务实现情况与指标对照

逐条对照任务要求，说明每项的实现方式、所在位置与实测指标。基线：分支
`upstream/pr-new`（upstream/dev `ba252ca67` + `87eb3fcc5` + `621a063a9`），
数据批次 2026-08-27。

## 任务一：实时性改造与验证

| 要求 | 实现情况 | 指标/证据 |
|---|---|---|
| 1.1 改造调度/抢占/定时器/中断/亲和性/锁临界区/后台任务 | ✅（嫁接保留 + rebase 适配） | 见下文「1.1 明细」 |
| 1.2 ≥2 vCPU 多核 Linux 客户机 + 绑定/内存/设备/中断/启动参数说明 | ✅ | Linux guest 2 vCPU，vCPU↔物理核一一绑定；见下文「1.2 明细」 |
| 1.3 实时性验证流程（周期抖动/调度延迟/中断响应/最大延迟/长稳） | ✅ | RTBench 16 指标 × 10 样本，8 组合全 10/10 完整 |
| 1.4 RTOS 裸机/原生基线对照 | ✅ | RT-Thread native QEMU 基线 runner（`run_rtthread_native_baseline.sh`），同源 RTBench 负载 |
| 1.5 可复现（分支/镜像/配置/命令/脚本/结果采集） | ✅ | [reproduce.md](reproduce.md) 全流程命令 |

### 1.1 明细：实时性改造

**每 VM 策略（分支独有机制，嫁接于 upstream 重构之上）**：

- `host_timer_policy`（periodic/tickless）——per-VM host 定时器所有权
- `host_vcpu_idle_policy`（busy/halt）——vCPU idle 行为；busy WFI fastpath
  曾在汇编层把 WFI 当 NOP 消除 exit，rebase 后因与统一 host-timer 所有权
  模型冲突（idle guest 的 timer PPI 无注入时机）暂禁，走常规 WFI exit +
  host timer event 等待
- `guest_tlbi_policy`（vm_scoped）——按 vCPU 亲和集收敛 TLB 失效广播

**中断路径**：

- host-SPI 风暴熔断：handler 不清源的设备（实测板级调试 UART）会以 exit
  极限速率重触发、饿死 guest 虚拟时间；同一 host SPI 10 ms 内 >32 次即由
  host task 在 distributor 掩蔽（`621a063a9`）
- timer PPI 逐 entry 发布（upstream `publish_for_entry`，分支
  `synchronize` 的演化版）：GICv2 硬件上虚拟 PPI 的电平必须在每次 guest
  进入前重发布，否则 guest 永远看不到自己的调度 tick

**CPU 亲和性**：vCPU 独占物理核（修复 CPU_ON 握手撞 current-vCPU
publication 的 nested-vCPU panic）。

**热路径日志降级**：per-IRQ host 中断日志 info→debug，防刷屏拖慢 guest。

### 1.2 明细：多核 Linux 客户机配置

以 QEMU 配置（`os/axvisor/configs/vms/qemu/aarch64/linux-net.toml`）为例，
板级等价配置见 `configs/vms/rock-4d/linux-task123.toml`：

| 项 | 值 |
|---|---|
| cpu_num | 2（vCPU0/vCPU1） |
| vCPU↔物理核 | `phys_cpu_sets = [0b0001, 0b0010]`，每 vCPU 独占一个 host CPU |
| host_timer_policy | periodic |
| guest_tlbi_policy | vm_scoped |
| 内存 | `memory_regions` 独立区间，Stage-2 页表隔离 |
| 设备映射 | virtio-net 固定放置 MMIO `0x0a00_0000` + GIC SPI 16（控制器输入 48），RT-Thread/Zephyr BSP 静态页表兼容 |
| 中断路由 | 虚拟 GIC（GICv3 for QEMU / GIC-400 for ROCK 4D），host IRQ 由 EL2 拦截转发 |
| 启动参数 | 内核 cmdline：`console=ttyS0... rdinit=/init task2.count task3.frames task3.fault rtbench.net.count` |

### 1.3 实时性指标（16 项 RTBench，本批次实测）

指标集：`timer_jitter`（周期任务抖动）、`preemption`/`scheduler_decision`/
`context_switch`（调度延迟）、`irq`/`irq_to_task`/`irq_handler_exec`/
`irq_disabled_duration`（中断响应与关中断时长）、`callback_exec`/
`wake_under_load`/`deadline_miss_under_load`（负载下唤醒与截止失误）、
`mutex_inversion`/`sync_sem`/`sync_mutex`/`sync_mailbox`（锁临界区）、
`net_event_latency`（网络事件延迟）。

代表性结果（timer jitter，ns；完整表见 [performance.md](performance.md)）：

| 平台 | RTOS | p50 | p99 |
|---|---|---:|---:|
| ROCK 4D | RT-Thread | 459–1,000 | **8,875–28,125** |
| QEMU | RT-Thread | 4,896–8,768 | 83,472–244,720 |
| ROCK 4D | Zephyr | ~1,039,000 | ~2,083,000 |
| QEMU | Zephyr | 398,352–647,584 | 797,104–1,295,168 |

长稳：每组合 realtime-suite 运行 16 指标 × 10 样本全部
`expected=10 collected=10 missing=0`。

### 1.4 RTOS 基线

`run_rtthread_native_baseline.sh`：同一 RTBench 负载跑在 native QEMU
（无 hypervisor，RT-Thread 直接在 QEMU virt 上，0009 内存布局补丁），输出
同格式指标，供虚拟化开销对照。平台差异：native QEMU 无 Stage-2 翻译与
vGIC 转发，定时器为直通虚拟定时器；虚拟化侧的差值即为 Axvisor 隔离开销。

## 任务二：客户机间通信

| 要求 | 实现情况 |
|---|---|
| 2.1 IP 协议栈双向链路（非网络机制不作主通道） | ✅ virtio-net guest-to-guest（内部 VirtualSwitch）+ IPv4/UDP；无共享内存/HyperCall/裸 MMIO |
| 2.2 应用层协议（版本/类型/长度/序号/时间戳/错误码/校验 + 控制/状态/错误通知） | ✅ RT-IPC v2：header 含 `version` `msg_type` `payload_len` `seq_num` `error_code` `checksum`；消息类型覆盖控制指令、状态回传、错误通知 |
| 2.3 vsock 边界 | ✅ 未使用 vsock |
| 2.4 可靠性机制 | ✅ UDP 上实现 ACK、超时、重传、乱序/重复处理（序列空间与 FIN 握手见 `rt_ipc.h`）；实测 8 组合 transport_retries=0、duplicates=0 |
| 2.5 拓扑/地址/指标说明 | ✅ 见下 |

**网络拓扑**：VM[1] `52:54:00:77:00:01` / 192.168.77.11 ↔ VM[3]
`52:54:00:77:00:03` / 192.168.77.30，/24 直连，无 NAT/网关/桥接/防火墙；
Task 2 用 UDP :9876，Task 3 用 UDP :9877，RTBench 探针 :9878/:9879。

**实测指标**（8 组合，详见 [performance.md](performance.md)）：

- 请求成功率 100%（Task 2 10/10、Task 3 6/6，`application_errors=0`）
- 64B RTT：QEMU 2–4 ms；ROCK 4D RT-Thread×Linux 2 ms
- 网络事件延迟 net_event_latency p50：84–348 µs
- 有效吞吐：~313–340 B/s（Task 3 帧 64B 载荷 @ ~5 Hz 场景值）

## 任务三：AI 模型与控制联动

| 要求 | 实现情况 |
|---|---|
| 3.1 AI 应用 + 经任务二协议发送输出 | ✅ TinyCNN int8 三分类（LEFT/CENTER/RIGHT），Linux/StarryOS 端推理后经 RT-IPC v2 发 RTOS |
| 3.2 RTOS 依 AI 输出执行可观察控制动作 | ✅ RT-Thread/Zephyr 更新虚拟 PWM 与转向位置，并回传状态 |
| 3.3 完整闭环 | ✅ Y4M 帧 → CNN 推理 → virtio-net → RTOS PWM/转向 → 状态回传（帧级 CSV 记录全链） |
| 3.4 端到端延迟 + 测量方法说明 | ✅ 见下 |
| 3.5 可量化对比（≥2 指标，固定参数基线 vs AI） | ✅ 见下 |

**端到端延迟**：同侧往返测量（应用 guest 单时钟源），`round_trip_us` =
发送→RTOS 处理→状态回传全程。真机 p50 ≈ 3.4–3.8 ms（QEMU 1.4–3.8 ms）。
误差来源：两侧时钟未同步，故只报同侧往返不报单向；RTOS 侧处理耗时
（`rtos_processing_us`，45–102 µs）单独统计。

**控制效果对比（FIXED 基线 vs AI）**：

| 指标 | FIXED | AI | 说明 |
|---|---|---|---|
| 跟踪误差 Q15 p50 | 1,461 | 1,461 | 确定性负载下二者相同（设计使然：AI 分类与固定脚本同判） |
| 分类准确率 | —（无模型） | 3/3 = 100% | AI 模式独有指标 |
| 推理耗时 p50 | —（无模型） | 943–982 µs（真机） | AI 引入的额外环节开销 |
| 响应延迟 rtt p50 | 与 AI 相同量级 | 3.4–3.8 ms | 网络往返主导 |

设计说明：Task 3 的视频负载为确定性序列（固定种子 Y4M + truth.csv），固定
控制脚本与模型输出在同序列上判定一致，故跟踪误差相同；对比的意义在于证明
AI 链路引入（推理 + 跨机传输）后控制精度不劣化、闭环仍按帧完成，而分类
准确率与推理耗时是 AI 链路的独有量化指标。

## 提交材料对照

| 要求材料 | 位置 |
|---|---|
| 设计文档 | [design.md](design.md)（架构/隔离/协议概述）、[changes.md](changes.md)（配置与修改说明）、`os/axvisor/guests/task3/README.md`（AI 模型选型与部署） |
| 测试文档 | [results-report.md](results-report.md)、[performance.md](performance.md) |
| 源码 PR | 分支 `upstream/pr-new`（源 self 分支 `feat/task123-rock4d-port` 已合入后 rebase）；已推送 origin，与 dev 无冲突 |
| 复现说明 | [reproduce.md](reproduce.md) |
| 演示视频 | 待录制（建议内容：双终端 guest 输出、RT-IPC 数据流、Task 3 AI 闭环） |
