# 工程实录：怎么做、做了哪些事情

本文按工作流顺序记录整个工程的实施过程与关键问题的定位方法，是
[design.md](design.md)（是什么）、[changes.md](changes.md)（改了什么）、
[reproduce.md](reproduce.md)（怎么跑）之外的过程叙述。

## 0. 总体工作流

```text
阶段 1：QEMU 双 guest 打通        （guest 移植 + virtio-net 互联）
阶段 2：QEMU 四组合矩阵 + 门禁     （runner、结果判定、矩阵编排）
阶段 3：ROCK 4D 板级 bring-up      （串口/GIC/定时器/复位链路）
阶段 4：板级四组合 + 正式数据      （串口 gate、retry 合并、指标完整化）
阶段 5：rebase 到 upstream/dev    （适配 upstream 重构、复验八组合）
```

原则：每个阶段都先在 QEMU（快速、可重放）验证，再到真机（慢、需要复位
链路）复验；所有结论以串口 marker 门禁判定，不靠人眼。

## 1. RT-Thread guest 移植怎么做

**补丁工作流**（而非 fork 仓库）：上游 RT-Thread v5.2.2 pin 到固定 commit
`ddf52e2c`，所有修改以 12 个编号补丁维护在
`os/axvisor/patches/rtthread/`，由 `apply-rtthread-patches.sh` 在干净源码
树上按序应用：

```bash
# 准备源码（clone 到固定 commit，校验干净）
bash os/axvisor/patches/rtthread/prepare_rtthread_source.sh <目标目录>
# 应用补丁 + 拷入 RT-IPC/task3/RTBench guest 源码
bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh <目标目录>
# 构建（musl 工具链）
cd <目标目录>/bsp/qemu-virt64-aarch64
RTT_EXEC_PATH=<musl 工具链路径> scons
```

关键设计：

- **补丁状态 digest**：脚本对补丁集做 sha256，记录在源码树的
  `.axvisor-rtthread-patch-state`；脏树或补丁漂移直接拒绝，防止对已改源
  码重复应用或漏应用。
- **双镜像策略**：`RT_USING_TASK123_SERVER` 编译开关区分两种镜像——带
  RT-IPC/task3 服务器的 task123 镜像 vs 纯 RTBench 镜像（服务器线程与
  benchmark 线程同优先级会在 benchmark 阶段引入非确定性干扰）。
- **canonical guest 源码在 tgoskits 仓库内**（`os/axvisor/guests/`），
  apply 脚本负责拷入 BSP，防止源码树里的旧副本悄悄生效。

## 2. Zephyr guest 移植怎么做

Zephyr 走 overlay 路线（Zephyr 自身的板卡机制）：`os/axvisor/guests/
zephyr-task123/` 提供 `axvisor_rock4d` 板型定义与 `virtnet.overlay`（在
QEMU cortex-a53 基础上改内存基址、启用 virtio_mmio@a000000 的 virtio-net
节点），`build_zephyr_task123.sh` 一键构建。guest 应用（main.c）在同一
代码里同时实现 RT-IPC 服务器、task3 服务器与 RTBench——task3 会话结束后
自动进入 benchmark，并通过 RTBENCH_NET 探针握手（见 §4.3）与 app guest
的探针监听器协同。

## 3. 板级 bring-up 实录（关键问题与定位方法）

bring-up 阶段的问题按「现象 → 定位手段 → 根因」记录，这些定位方法本身
是可复用的工程资产。

### 3.1 guest「卡死」实为线程饿死

- 现象：RT-Thread guest boot 后无任何进展，疑似 hypervisor 卡死。
- 定位：在 guest 内逐阶段加 hvc 探针（每个 INIT 阶段发一次 hypercall 打
  到 host 串口），发现内核各阶段都在走——不是卡死，是某个线程霸占 CPU。
- 根因：guest 测试线程用优先级 0 创建——RT-Thread 里 0 是**最高**优先级，
  忙等循环把包括 shell/main 在内的所有线程饿死。删掉该线程即可。
- 教训：「guest 无输出」≠「guest 死了」；先确认 guest 内部是否在推进。

### 3.2 计数器忙轮询挂死（CNTPCT trap 不前进）

- 现象：benchmark 的 settle 阶段（忙等 30 s）永不结束。
- 定位：把忙等的计数器读从 `cntpct_el0` 换成 `cntvct_el0` 立即恢复。
- 根因：物理计数器读被 trap 到 EL2，板级该路径返回值不前进（QEMU 不复
  现）；虚拟计数器不 trap 且同速率。
- 教训：依赖 trap 路径的 guest 代码在 QEMU 与真机行为可能不同，优先用
  不 trap 的等价资源。

### 3.3 虚拟 timer PPI 电平无人发布

- 现象：guest boot 期所有 sleep 挂起——收不到自己的调度 tick。
- 定位：在 vGIC 的 timer 绑定处加诊断日志（compare/level/counter/off
  逐项打印），确认 PPI 转发逻辑本身正确，缺的是「发布」动作。
- 根因：硬件 GICv2 上虚拟 PPI 没有别的断言来源，物理 CNTV 到期被 host
  认领并去激活；必须在每次 guest 进入前重发布 PPI 输入电平
  （`prepare_timer_run` 里的 `synchronize`/upstream 演化版
  `publish_for_entry`）。
- 教训：vGIC 的 PPI 是「电平」语义，不是「事件」语义；谁负责重新断言
  电平要在设计里写明。

### 3.4 virtio-net 探测不到（vendor 身份）

- 现象：guest 报 no_network_device，但 FDT 节点、MMIO 窗口都正确。
- 定位：给设备 MMIO 读路径加日志——guest 只读了 magic/version/vendor 三
  个寄存器就走开了；对照 RT-Thread BSP 源码，其探测循环要求 vendor ==
  0x554D4551（QEMU 身份）。
- 根因：hypervisor 设备模型报的是规范 vendor ID 0x1AF4。改用
  `new_with_vendor_id(QEMU 身份)`；Linux 客户机不受影响（忽略传输层
  私有 ID）。
- 教训：规范值不等于兼容值；guest 的探测条件以 guest 源码为准。

### 3.5 nested-vCPU panic（CPU_ON 握手撞 publication）

- 现象：SMP Linux 客户机 secondary CPU 上线时 hypervisor panic
  "nested vCPU operation is not allowed"。
- 定位：给 panic 消息补上两侧 vCPU 身份——self=VCpu[1]、current=VCpu[0]，
  说明 VCpu[0] 的 current-vCPU publication 未释放时 VCpu[1] 在同一物理核
  上执行了 vCPU 操作。
- 根因：两个 vCPU 的 `phys_cpu_sets` 重叠；CPU_ON 握手期间 primary vCPU
  在 publication 内等待 secondary 启动确认，secondary 恰好被调度到同一核。
  修复为每 vCPU 独占物理核。
- 教训：加一句身份信息到断言里，常常是最高性价比的定位手段。

### 3.6 host SPI 风暴饿死 guest 虚拟时间

- 现象：板上 guest 时钟显著变慢，30 s 的 guest 延时在 180 s 门禁内跑不完；
  串口刷大量同一 host SPI 的中断日志。
- 定位：先给分发路径加 called/handled 诊断——handler 被调用且返回
  handled，但中断以 µs 级间隔重触发，说明 handler 声称处理了却不清源
  （调试 UART 的 RX 电平中断）。再验证「真实速率被日志打印限速」的猜想：
  把 per-IRQ 日志降级 debug 后风暴频率暴涨。
- 根因：upstream 的 aarch64 console 输入路径在该板上不消费 UART RX 中断，
  U-Boot 留下的 IER 使电平持续置位。
- 修复：host-SPI 风暴熔断——同一 SPI 10 ms 内分发超过 32 次即掩蔽该线；
  掩蔽动作放在一次性 host task 里执行（distributor 锁不能在 IRQ 上下文
  拿，第一版直接在 IRQ 上下文拿锁导致死锁，是教训之二）。
- 教训：a) 「handled」不代表「清了源」，电平中断的收尾必须验证；b) 阈值
  要按「handler 正常时的物理不可能速率」设定（第一版 1 s/100 次误杀了
  NVMe 的正常中断，把块 IO 打死）。

### 3.7 busy WFI fastpath 与统一 host-timer 所有权冲突

- 现象：rebase 到 upstream 后，板级 guest 在 idle 后 timer tick 停止。
- 定位：fastpath 在汇编层把 WFI 当 NOP 直接 eret——guest 不产生 exit，
  挂起等待的 timer PPI 永远没有注入时机（注入只发生在 exit 处理循环里）。
- 根因：分支原设计里 fastpath 配套「直接加载 guest 定时器」（硬件直通），
  upstream 的统一 host-timer 所有权模型移走了这个前提。
- 修复：暂禁 fastpath，WFI 走常规 exit + host timer event 等待。真机
  RT-Thread timer jitter p99 与禁用前同量级（28,750 vs 33,375 ns）。

## 4. 验证流程怎么搭

### 4.1 串口 marker 门禁

所有判定都归结为串口流中的文本 marker（`TASK2_*_END status=PASS`、
`TASK123_*_RTBENCH_END status=PASS` 等），由 ostool 的 success_regex 匹配。
要点：

- marker 由**协议两端**交叉背书：app guest 的 init 只有在 task2/task3 全
  部通过且网络探针完整走完后才打印组合终态 marker。
- 板级 gate 的正则要求 benchmark 结束 marker 与组合 marker 落在匹配器的
  2 KiB 滑窗内——由「init 在探针完成后紧邻打印」保证。

### 4.2 retry 合并

物理串口会把单条 benchmark 记录从字段中间截断（mux 输出交错，与
`[VM n]` 前缀黏连）。对策不是修日志，而是：每组合保留主日志 + 若干
retry 日志，解析器（`plots/plot_task123.py`）逐行 `finditer` 提取所有
记录、按 9 个字段值去重、只收完整行；Task 3 的 summary JSON 被截断时从
逐帧 CSV 重建分类与跟踪误差统计（`|target_q15 − actuator_q15|`，与 guest
端 `absolute_error` 定义一致）。

### 4.3 RTBENCH_NET 探针协议

RTBench 的 `net_event_latency` 指标需要 app guest 侧配合：探针监听器
（UDP :9879）等 RTOS 侧 trigger，回 READY，逐序列发探针并等 ACK，最后
等 DONE。Zephyr guest 一开始没实现这套握手，导致 app guest 的 init 永远
等不完、板级 gate 超时——补齐握手（trigger 重试 → READY 确认 → ACK
逐包 → 结束后 DONE）后四组合全绿。

## 5. rebase 到 upstream/dev 的做法

upstream 在开发期间大量重构（统一 host timer 所有权、配置化设备框架、
mandatory-IRQ、isolated interrupt controller fixes）。237 个原始 commit
逐个重放不可行（早期 commit 依赖已被重构删除的 API），采用**树级重放**：

1. `git merge --no-commit` 做三方合并，一次性面对全部语义冲突（~65 块）；
2. 按文件逐个决策：upstream 已演化出等价机制的取 upstream（timer PPI
   发布、vCPU 事件等待、配置化设备），分支独有的机制嫁接回 upstream
   结构（三策略字段、virtio 传统放置、embedded-rootfs、mux 守卫、探针
   握手）；
3. `git reset --soft` 线性化为「集成 + 适配」两个核心 commit；
4. QEMU 矩阵 + 板级四组合全量复验（复验本身发现并修复了 §3.5–3.7 三个
   问题——rebase 复验不是走过场）。

## 6. 做了哪些事情（清单）

- RT-Thread v5.2.2 → Axvisor guest：12 补丁移植（virtio-net/lwIP/GIC/
  定时器/板级），digest 化补丁管理，双镜像构建。
- Zephyr v4.4.2 → Axvisor guest：板型 overlay + 三服务合一应用 + 探针
  握手。
- RT-IPC v2 协议：版本/类型/长度/序号/错误码/校验的 UDP 可靠传输，双端
  实现（Linux/StarryOS 客户端、RT-Thread/Zephyr 服务器）。
- Task 3 TinyCNN：NumPy 自研训练 + int8 量化 + C 推理 + golden 等价校验。
- RTBench 16 指标纳秒基准 + 网络探针协议。
- runner 基础设施：QEMU 矩阵、板级 U-Boot 入口、串口门禁、retry 合并、
  图表生成。
- hypervisor 侧：三策略机制、virtio 传统放置、风暴熔断、串口 mux 守卫、
  embedded-rootfs；rebase 到 upstream/dev 最新并适配其全部重构。
- 验证：8 组合（QEMU×4 + ROCK 4D×4）全部门禁 + 指标完整，正式数据批次
  归档。
