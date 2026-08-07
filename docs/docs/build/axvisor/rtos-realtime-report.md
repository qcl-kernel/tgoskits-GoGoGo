# Axvisor RTOS 实时性测试报告

## 结论

截至 `2026-08-07`，same-board bare-metal acceptance 的目标是
`board=orangepi-5-plus`，当前状态为外部硬件/资产 `BLOCKED`，不是实时性优化
完成。当前没有真实板测量；CSV/PNG 新增的 QEMU TCG 筛选结果不能解除该阻塞。

本轮迭代确认并修复了 RTOS 定时器完全不工作的配置问题：Axvisor 将
Zephyr guest 放在 EL1 Non-secure，但 Zephyr 未按 Non-secure GIC 模型配置
SGI/PPI。修复 `CONFIG_ARMV8_A_NS=y` 后，`k_sleep()` 返回，单 guest 和
两个 Linux + 一个 Zephyr 的 10,000 次定时器测试均完成。

这些实时性能仍不能称为“非常优秀”的硬实时结果：初始三 guest 网络基线最大
延迟为 `1984/1021/1550 us`，每轮都有超过 1 ms 的 miss。经过关闭同步日志、
提高 tick 到 10 kHz，并移除正式网络 guest 的 1 ms virtio 状态轮询后，正式
no-poll 三轮最大延迟降为 `515/307/84 us`，三轮均无超过 1 ms 的 miss；但
仍有一轮出现 1 次超过 500 us 的 miss。网络和每轮 9999/9999 callback 均通过，
说明本轮优化有效降低了长尾，但仍不足以形成硬实时保证。

10 kHz 是当前 QEMU TCG、固定 vCPU 拓扑下的有效平均/典型延迟优化，但仍不是
裸机级硬实时保证。TCG 多线程和单线程对照分别出现 `2339 us` 和 `9745 us`，
此前 raw-cycle 重测也出现 `3563 us`；no-poll 优化后的正式三轮仍为
`515/307/84 us`，说明轮询竞争被消除后，剩余长尾主要来自 QEMU TCG 和宿主调度。

本轮继续迭代没有得到“非常优秀”的硬实时结果。修复 AArch64 非 passthrough
IRQ 退出路径的重复 host dispatch 后，旧 workload 的一次重测最大延迟为
`2814 us`；这项修改验证了 IRQ 所有权和分发次数的正确性，但当前正式使用的
passthrough timer 路径不应把它直接归因成延迟改善。将 benchmark 完成后的
Zephyr 主线程从 1 ms 周期唤醒改为 completion semaphore 后，三轮最大延迟为
`92/352/576 us`，没有超过 1 ms 的 miss，但相较 no-poll 正式三轮没有稳定改善。
宿主绑核加显式 TCG multi 的对照最大延迟为 `4693 us`，并出现 8 次超过 1 ms
的 miss，因此已拒绝作为优化配置。当前可归因的主要长尾仍是 AArch64 QEMU TCG
执行和宿主调度，不能宣称已达到裸机水平。

本轮补强了测量边界，但没有改变定时器调度路径：新增 p99.99、callback 最大
执行时间和 tick-gap 统计，并运行三轮新的默认 no-poll 基线，最大延迟为
`449/1081/62 us`，p99.99 分别为 `405840/219168/0 ns`。三轮的
`tick_gap_min/max` 都是 `0/0`，说明没有观测到 10 kHz tick 合并；callback
自身最大执行时间为 `267648/70368/51392 ns`，不能解释全部毫秒级长尾。将
显式 TCG multi 的宿主 CPU 预算从 4 个扩展到 8 个后，最大延迟为 `362 us`，
优于此前 4 CPU 绑核对照，但仍属于 QEMU/宿主控制实验，不是 Axvisor 裸机级
性能证明。宿主当前 governor 为 `powersave`，因此这些结果还受到宿主频率策略
影响。

本轮还修复了 passthrough SPI 路由不应使用 `vm.id() - 1` 推导物理 CPU 的问题，
改为读取 vCPU placement 并加入架构边界契约。修复后的网络 smoke 仍完成
`9999/9999` callback 和三条网络验证，但最大延迟为 `5954 us`、6 次超过
`1 ms`；因此该改动只按正确性修复保留，性能结论记为“未改善”。

随后尝试了 vCPU guest-entry 上下文缓存：在同一 vCPU 连续重入期间跳过不变的
EL2 寄存器写入，但保留每次 entry 的 `ic iallu`、`tlbi alle2`、`tlbi alle1`
和屏障。三轮均完成 `9999/9999` callback 和三条网络验证，但最大延迟为
`251/664/1697 us`，其中一轮出现 1 次超过 `1 ms`；正式 no-poll 基线为
`515/307/84 us`。这项候选优化因此被拒绝并从正式代码移除，数据保留在 CSV
迭代 41--43。结果进一步表明，未减少 TLB/cache 维护时，仅减少 EL2 寄存器
写入不足以压低 QEMU TCG 的调度长尾。

撤回候选后的最终功能 smoke 仍完成三 guest 网络验证和 `9999/9999` callback，
但单轮最大延迟为 `4226 us`，有 4 次超过 `1 ms`。该轮使用的历史正式 guest
镜像没有输出新增的 p99.99/callback/tick-gap 字段，因此只作为功能回归记录在
迭代 44，不作为新的正式性能基线；它同时说明 QEMU TCG 单轮结果波动很大。

为区分 Axvisor 开销和 QEMU TCG/宿主调度影响，新增了同一 benchmark 的裸机
QEMU 参考。裸机镜像使用同样的 10 kHz tick、62.5 MHz counter 和 raw-cycle
测量，只将 RAM overlay 放到 QEMU `virt` 的 `0x41000000`，直接由 ELF loader
启动。三轮 idle 最大延迟为 `0/0/0 us`；低优先级负载最大延迟为 `14/17/19 us`，
p99.99 为 `9344/16960/14112 ns`，三轮均无 deadline miss，tick gap 均为 `0/0`。
这说明 Axvisor 正式三 guest 网络结果的 `84/307/515 us` 长尾确实比单 guest
裸机参考更差，但该对照仍运行在同一 x86_64 主机的 AArch64 TCG 上，尚不能等同
于真实 ARM 裸机，也不能单独把全部差值归因于 Axvisor。

移除未使用的第 4 个 QEMU/Axvisor CPU，并对 RTOS VM 同时启用 tickless host timer
与 `host_vcpu_yield` 后，历史三轮结果最大延迟为 `0/0/378 us`，三轮均无
`>500 us` 或 `>1 ms` miss，所有网络验证及 `9999/9999` callback 均完成。它是
当前 x86_64/AArch64 TCG 环境中的历史最佳三轮样本，但最坏值仍约为裸机 QEMU
低优先级参考 `19 us` 的 20 倍。

本轮使用新鲜度 manifest 绑定的 SMP3 release ELF/raw 和三份 VM TOML，再对同一
tickless + yield 组合完成三轮确认。最大延迟为 `569/4996/2678 us`，`>1 ms`
miss 为 `0/5/2`；三轮的两条 Linux-to-Zephyr ICMP、Linux 间 TCP/8080 和
`9999/9999` callback 都完成，启动日志也明确打印 RTOS 为
`timer=Tickless, vcpu_yield=true`。callback 最大执行时间仅为
`15.456/18.688/18.224 us`，不能解释毫秒级长尾。故历史 `0/0/378 us` 不能再被
描述为稳定性能，SMP3 + tickless + yield 候选按“不稳定”拒绝；当前没有任何三
guest TCG 配置达到或稳定接近裸机参考。

最新同步诊断进一步缩小了根因范围。manifest 绑定的 SMP3、显式 MTTCG、
tickless + yield 场景完成两轮完整网络测试，最大延迟为 `1459/1362 us`，
`>1 ms` miss 为 `1/3`。500 us 周期采样的实际最坏间隔为
`591.942/1008.715 us`。第一轮把 guest 最坏 `1.6616 ms` compare-overdue
映射到宿主时间窗后，RTOS QEMU TID 的窗口 run-delay 为 `0 ns`；第二轮最坏
`1.5685 ms` 窗口同样为 `0 ns`，且采样状态持续为
`S/futex_do_wait`。因此“RTOS vCPU 已 runnable、但被 Linux CFS 延迟调度”的
假设已被证伪；当前证据指向 Axvisor 执行 WFI 后 QEMU 将该 vCPU 挂入
`halt_cond`，虚拟 timer 唤醒该 halted vCPU 时产生长尾。这个结论只描述当前
x86_64 宿主的 AArch64 TCG 行为，不证明真实 ARM/KVM 上存在同一问题。

继续迭代增加了一层“一个 Linux + 一个 Zephyr”的网络对照。三轮最大延迟为
`403/180/13 us`，`>500 us` 和 `>1 ms` miss 均为 0，回调均为 `9999/9999`；
Linux-1 到 Zephyr 的 ICMP 也均通过。该层没有启动 Linux-2，因此没有把
Linux-1 到 Linux-2 的 TCP/8080 记为通过，CSV 使用 `pass_partial_network`。
它不是正式验收配置，但相对两 Linux + RTOS 正式结果的最大值
`515/307/84 us`，说明增加一个 Linux guest 及其网络/调度活动会扩大 RTOS
定时器长尾；callback 最大执行时间仍只有约 `50--53 us`，不能解释该差异。
因此本轮没有把“减少 guest 数量”当作优化提交，而是将其作为归因对照。

本轮继续降低 benchmark 自身扰动：timer callback 只保留 raw cycle、interval 和
tick-gap 采样，把微秒换算、histogram、百分位和 deadline 统计移到测试结束后的
`rtbench_report()`。三轮结果最大延迟为 `1004/1312/96 us`；第一轮因临时生成的
动态 BusyBox initramfs 缺少 loader，Linux guest 启动失败，网络标记为
`failed_initramfs`，不作为性能验收。修正为上一轮已验证的静态 initramfs 后，后两轮
网络均通过，但仍出现一次 `>1 ms` miss，因此该改动不能证明降低了 RTOS 调度长尾；
它将 callback 最大执行时间从约 `50 us` 降到 `16--25 us`，保留为测量质量改进，
不作为 latency 优化结果。

随后评估 Axvisor guest-entry 中每次重入执行的 `ic iallu`。保留
`tlbi alle2/alle1` 和屏障，仅移除全局 instruction-cache flush；三轮网络和
`9999/9999` callback 均通过，但最大延迟为 `8383/77/104 us`，首轮有 8 次
`>1 ms` miss，远差于正式 no-poll 基线，因此候选已撤回。该结果不支持继续从
cache flush 单点优化；下一阶段应把长尾拆分到 host scheduler/QEMU TCG 和真实
硬件/KVM，而不是继续猜测 guest-entry 指令。

本轮又验证了一个单变量候选：外部 IRQ 已经在
`fetch_pending_host_irq()` 完成 host claim/dispatch 时，AArch64 guest exit
直接在当前 pinned vCPU loop 内执行 `check_timer_events()` 并返回 `Continue`，
以尝试省掉 `unbind -> 外层调度 -> bind -> guest 重入` 往返。候选的边界契约、
AxVM 单元测试和 arm_vgic 回归均通过，但三轮完整网络结果为最大延迟
`53507/855/4558 us`，`>1 ms` miss 为 `60/0/4`。第一轮出现 `52.5 ms`
的 p99.99 尾延迟；第二轮 Linux-2 HTTP 首次连接被拒绝、随后重试成功，第三轮
仍有 4 次超过 1 ms。三条网络链路和 `9999/9999` callback 最终均完成，但候选
远差于正式 no-poll 的 `515/307/84 us`，因此拒绝并恢复 deferred 路径。原始日志
保留在 `/tmp/axvisor-rtbench-irq-inline-r1.log` 至 `r3.log`，CSV 为迭代 60--62。

修复单 RTOS 启动配置后，补做了三轮 Axvisor 单 Zephyr 对照；每轮先运行 idle，
再启动优先级 10 的低优先级 busy worker。六条记录均完成 `9999/9999` callback，
idle 最大延迟为 `0/0/0 us`，低优先级负载最大延迟为 `0/16/17 us`，三轮均无
`>100 us`、`>500 us` 或 `>1 ms` miss。对应低优先级 p99.99 为
`0/11104/10672 ns`，与裸机 QEMU 低优先级 `14/17/19 us` 同量级；因此单 guest
Axvisor/FDT/timer 路径不是两 Linux + RTOS 场景毫秒级长尾的主要来源。原始日志为
`/tmp/axvisor-rtbench-single-fdt-fixed-r1.log` 至 `r3.log`，CSV 为迭代 63--68。

在 FDT 修复后的最终工作树上又做了一轮正式三 guest no-poll smoke：两个 Linux
到 Zephyr 的 ICMP、Linux-1 到 Linux-2 的 TCP/8080 重试和 `9999/9999` callback
均完成，未出现旧的 MMIO fault；但 HTTP 首次连接被拒绝，且最大延迟为 `1181 us`
并有 1 次超过 1 ms。因此该轮标记为 `pass_after_retry`，只证明修复后的最终配置
仍可运行，不更新正式 no-poll 性能基线。原始日志为
`/tmp/axvisor-rtbench-final-fdt-smoke.log`，CSV 为迭代 69。

随后针对宿主调度边界做了一个单变量候选：Axvisor 的 `ax-std` 原先只启用
`multitask`，没有启用 `sched-rr` 或 `sched-cfs`，因此 ArceOS 使用默认 FIFO
协作式调度。临时启用 `sched-rr` 后，启动日志确认使用 Round-robin scheduler，
三轮完整网络测试均完成 `9999/9999` callback，最大延迟为 `810/753/54 us`，
`>1 ms` miss 为 `0/0/0`，p99.99 为 `95.6/359.3/0 us`。但正式 no-poll 基线为
`515/307/84 us`，RR 前两轮尾延迟更高，三轮也没有稳定改善，因此候选已拒绝，
正式代码恢复 FIFO；原始日志保留在 `/tmp/axvisor-rtbench-sched-rr-r1.log` 至
`r3.log`，CSV 为迭代 70--72。该结果说明“启用抢占”本身不能替代对 vCPU
运行片段、IRQ 交付和 QEMU TCG 调度长尾的分段测量。

随后验证了 AArch64 IRQ fetch/deferred finish 的单变量候选：`gic::fetch_irq()`
已经通过平台 IRQ dispatcher 完成当前 GIC IRQ 的 claim、dispatch 和 completion，
因此临时保留 deferred 阶段的 AxVM timer drain，同时移除第二次 host IRQ dispatch。
三轮完整网络测试仍完成 `9999/9999` callback；最大延迟为 `437/1/484 us`，
p99.99 为 `43.120/0/94.848 us`，`>1 ms` miss 为 `0/0/0`。三轮网络均完成，
前两轮 Linux-2 HTTP 首次连接被拒绝后重试成功。与正式 FIFO no-poll 基线
`515/307/84 us` 相比，该候选没有稳定改善，故已恢复正式 AArch64 deferred
dispatch 路径；原始日志保留在 `/tmp/axvisor-rtbench-irq-fetch-r1.log` 至
`r3.log`，CSV 为迭代 73--75。

随后测试了宿主 ArceOS timer tick 从 `1000 Hz` 提升到 `10000 Hz` 的单变量候选，
Zephyr guest 配置和三 guest 网络拓扑保持不变。三轮均完成两条 ICMP、TCP/8080
和 `9999/9999` callback，最大延迟为 `633/904/292 us`，p99.99 为
`319.904/12.880/111.728 us`，`>1 ms` miss 为 `0/0/0`；callback 最大执行时间为
`15.728/27.008/16.096 us`，tick-gap 均为 `0/0`。与正式宿主 1 kHz FIFO
no-poll 基线 `515/307/84 us` 相比，三轮没有稳定改善，第二轮 interval 最大误差
仍为 `1.085 ms`，因此候选已拒绝并恢复 `ticks-per-sec = 1000`。原始日志为
`/tmp/axvisor-rtbench-host-tick10k-r1.log` 至 `r3.log`，CSV 为迭代 76--78。

在此之后尝试取消 FIFO 模式下 Axvisor 的周期 host timer，只保留 AxVM/task 的
one-shot deadline。第一轮只完成 FIFO scheduler 初始化，随后在 guest 启动前停止
推进，没有产生任何网络或 timer callback；原始日志保留在
`/tmp/axvisor-rtbench-fifo-oneshot-r1.log`，CSV 迭代 79 标记为 `failed_startup`。
该结果说明当前周期 timer 还承担 Axvisor 启动/协作式任务推进职责，不能直接删除；
候选已撤回，正式配置和代码恢复不变。后续若继续优化，必须先把启动阶段 timer
需求与 guest runtime 的 vtimer deadline 分离并增加独立回归测试。

随后验证了一个跨层单变量候选：让 AxVM 注册当前 CPU 的 timer-wheel deadline
provider，由 ArceOS 在最终写入共享 one-shot comparator 前合并 periodic、task/future
和 AxVM deadline 的最小值。该设计的契约测试和 `ax-task` 编译/单元测试通过，且三轮
完整网络测试都完成两条 ICMP、TCP/8080 和 `9999/9999` callback；但最大延迟为
`3770/224/18068 us`，p99.99 为 `3098.288/0/17072.272 us`，`>1 ms` miss 为
`11/0/21`，相对正式 FIFO no-poll `515/307/84 us` 没有稳定改善，因此候选已撤回。
原始日志保留在 `/tmp/axvisor-rtbench-deadline-provider-r1.log` 至
`r3.log`，CSV 为迭代 80--82。该结果说明 deadline 覆盖链的逻辑问题真实存在，
但在当前 QEMU TCG/宿主调度长尾下，修复 comparator 合并并不足以改善端到端 RTOS
延迟；正式代码恢复原有 timer callback/rearm 路径。

早期 QEMU 诊断采样由 QMP 映射 4 个 vCPU TID，并读取
`/proc/<qemu>/task/<tid>/schedstat`。复核发现这些 r1--r5 数据都是 SMP4，
采样实际最大间隔达到约 `27--34 ms`，且 `log` trace backend 只输出事件名和
CPU index，没有时间戳或 TID；它们不能解释后续 SMP3 的单个毫秒长尾。旧报告
关于“TCG 工作集中在 CPU0”的表述也不成立：例如 r4 窗口 CPU0 累计执行约
`2.200 ms`，CPU3 约 `10.689 ms`。这些旧数据只保留为采集器演进记录，不再作为
根因证据。原始数据位于 `/tmp/axvisor-rtbench-trace-data-r1` 至 `r5`。

新的同步采集器严格校验 manifest、运行内核快照、QEMU `-smp 3` 和 QMP 唯一
TID，并用本地 C probe 每 500 us 读取三个 vCPU 的 schedstat；控制台每行同时记录
`CLOCK_MONOTONIC_RAW`。Zephyr 在 benchmark 开始和报告时输出 CNTVCT 锚点，并在
结束后输出最坏 overdue 的 sample/CVAL/IRQ-entry。两点线性映射的宿主时间与 guest
counter 比例均约为 `16 ns/cycle`，与 62.5 MHz counter 一致。

同步轮 144 的最坏 overdue 为 `1.6616 ms`，对应窗口 RTOS TID run-delay 为
`0 ns`；整个 benchmark 内最大 run-delay 仅 `15.29 us`。同步轮 145 的最坏
overdue 为 `1.568544 ms`，对应窗口 run-delay 同样为 `0 ns`，并直接观测到
RTOS TID 为 `S/futex_do_wait`。该轮 90,001 个样本中，89,902 个 wchan 是
`futex_do_wait`。因此长尾发生时 vCPU 没有在宿主 runqueue 等待，而是处于 QEMU
halted-vCPU 条件变量等待；恢复执行后随即进入 PPI 27。原始证据为
`/tmp/axvisor-iteration-143-trace-r2` 和 `r3`，CSV 为迭代 144--145。

### 迭代 146：busy-WFI 筛选（拒绝）

本轮只执行 iteration 146 一次，runner 退出码为 `0`。固定运行参数为 QEMU SMP3、
`-accel tcg,thread=multi`、不绑宿主 CPU（QMP 映射的三个 vCPU 均为
`unbound/other`）；QEMU executable 为
`/home/yfblock/Env/qemu-11.0.2/build/qemu-system-aarch64`，版本 `11.0.2`，大小
`118351784` bytes，SHA-256 为
`84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956`。宿主为
x86_64 Linux `6.17.0-40-generic`，32 个 CPU 的 governor 均为 `powersave`。
这仍是 x86_64 宿主上的 AArch64 QEMU TCG 筛选，不是 bare-metal 或 same-board
证据。

预先冻结的 build manifest
`/tmp/axvisor-busy-wfi-iteration-146-build-manifest.tsv` 与 runner 保存的
`/tmp/axvisor-busy-wfi-iteration-146.log.build-manifest.tsv` 内容一致，SHA-256 均为
`636a29bacf3aea69f2f470eb1408d9d192f631ce18299b6ef5805cc75860b40f`。其中 release
ELF 为 `50ee99033e7c6795f37977ef41c0a61f6dc7295f9c5623a130bbf72e71e056c6`
（`58348208` bytes），raw 为
`f1a0a75e5b5dcce174fd44225035ce61796eb813bd2ac94b5dc7c04b9db33b89`
（`56717360` bytes）。Linux-1、Linux-2、Zephyr 三份 TOML 的 SHA-256 依次为
`69c6ab936f4f41783da2f3a78258741f2a8b3f9e881631c746c69c2a672aeef0`、
`5b91c694a5d7db7163496d528e9d4ace0301b54ca76ae92d952de9db4ba6a829`、
`103fa0b66dc90b2226998a71f9095761d8110e4c2a4383eb11d7dce3cded18df`；
Zephyr image SHA-256 为
`31fc218ab1c2b4d8e4395eee19bf387a76a28800f664c3189a2236342b18dfe2`
（`105064` bytes）。vCPU placement 仍为 Linux-1/Linux-2/RTOS 对应 pCPU
`0/1/2`。启动日志逐项确认 VM1=`Periodic,false,Halt`、
VM2=`Periodic,false,Halt`、VM3=`Tickless,true,Busy`。guest counter 为
`62500000 Hz`，Zephyr tick rate 为 `10000 Hz`，目标 schedstat sample interval
为 `500 us`，RTOS benchmark period 为 `1000 us`。

功能门禁全部通过：Linux-1 和 Linux-2 均到达 `192.168.77.13`，Linux-1 到
Linux-2 的 TCP/8080 通过；唯一一条 `RTBENCH network` 结果为
`samples=9999 expected=9999`，`tick_gap_min=0 tick_gap_max=0`。网络仍只经三个
virtio-net 设备，没有使用 shared memory、IVC 或 virtio/vhost-vsock。

因果门禁也通过。summary 恰有一个 `main-loop`（TID `4150950`）和一个
`cpu_index=2` RTOS vCPU（TID `4150957`）归因行；main-loop 与三个 vCPU 各有
`90001` 个样本。annotated samples 中 RTOS vCPU 的
`S/futex_do_wait` 为 `1357/90001 = 1.507761%`，严格低于 `50%`；其主要状态为
`88605` 个 `R/0` 样本，符合 busy-WFI 候选确实覆盖 RTOS vCPU 主循环的预期。

与 iteration 144--145 的原始指标对比如下：

| iteration | p99.9 | p99.99 | maximum | miss >100/>500/>1 ms | callback max | tick gap |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 144 | 0 us | 545808 ns | 1459 us | 3/2/1 | 58672 ns | 0/0 |
| 145 | 0 us | 1158416 ns | 1362 us | 8/6/3 | 28896 ns | 0/0 |
| 146 | 0 us | 595248 ns | 1185 us | 8/2/1 | 35936 ns | 0/0 |

p99.9 没有回退，maximum 也优于两轮同步对照；但 p99.99 相对 iteration 144
回退 `49440 ns`，miss severity 相对 144 的 `3/2/1` 没有改善（变为
`8/2/1`），因此不满足“p99.99、maximum 和 miss severity 同时改善”的
screen-pass 条件。单变量冻结也失败：144--145 使用的 QEMU 虽同为 `11.0.2`，
但 executable 为 `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`、SHA-256
为 `5b36544fa892b1d3d3abe24f36940518cccc6291d2e3ba298e4600f0c9d1afa9`；本轮路径和
哈希均不同。此外 Linux-1/2 TOML 哈希也从
`a8d372d229b132a59fba916a64b9c8771d4b4c6216fffdac01742cc86ab653b0`/
`caff30b2cfab0dc403a08cf9252af2ee0c5fa803399455dc8448734aa853d240`
变为上述新值。两套 Linux init/BusyBox payload 哈希及加载大小相同，说明没有
观测到 Linux workload 内容变化，但 exact TOML identity 仍未保持。ELF/raw 的变化
属于实现 busy-WFI 所需的已冻结候选产物，Zephyr TOML 的变化对应唯一策略字段，
collector 的预期变化是新增 main-loop 覆盖；QEMU hash 和两份 Linux TOML hash
则是这三项之外的 concrete drift。

因此 iteration 146 的 `network_validation` 记为 `pass`，但
`candidate_decision` 明确记为
`rejected_qemu_hash_and_linux_toml_drift_p99_99_miss_not_improved`。不得据此执行
147--149，也不采纳 busy-WFI 候选。完整 console、三个 PCAP、build manifest、QMP
map、sampled-thread map、raw/annotated samples、summary 和 metadata 分别保留在
`/tmp/axvisor-busy-wfi-iteration-146.log` 及
`/tmp/axvisor-busy-wfi-iteration-146-trace`；本轮没有覆盖或复用旧证据路径。

### 迭代 147--148：timer-broker remediation 筛选

本轮在 clean archive
`/tmp/axvisor-timer-broker-iteration-147-archive.y9NvYf` 上完成 correctness remediation
验证。归档源 SHA 为 `cc1c3a3ad176090261a7c18cb3218868d7bbb82e`，source tree 为
`de3393c9b491d5f8d77a23236c1267cd3c03e8d2`；生成目录的 `current` 是相对链接
`run.kw8nkU`，且同级只有这一个 `run.*` 目录。host matrix 全部通过：
`cargo fmt --check`；axvmconfig `25`、arm_vcpu `6`、axvm host-test `197`、
ax-runtime host-test `7`、ax-task `26`，Rust 合计 `261 passed, 0 failed`；precision
source contract、affinity executable artifact contract、validator shell syntax 均通过；
plot tests `11`、report tests `10`。

冻结输入为 Linux
`d8127a4ce952ae9bfa539d3535260b8d67973b766e51a3de0b97b526bfd6722c`、Zephyr
`31fc218ab1c2b4d8e4395eee19bf387a76a28800f664c3189a2236342b18dfe2`
（entry `0xa0001114`）、BusyBox
`52862c3b1a80652dd255f90a06960b1e03c5d58805f473c78bc8855c5eabb060` 和 rootfs
source `12cfc9f42549199d57ca67b6fc49fc701ff041efd6cdbcb390094edda8ef6f20`
（`33554432` bytes）。QEMU `11.0.2` executable 为 `118351784` bytes，SHA-256
`84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956`；宿主为
x86_64 Linux `6.17.0-40-generic`，32 个 CPU governor 均为 `powersave`。

board 为 `qemu-aarch64-three-guest-net-rt-trace.toml`，大小 `170` bytes，SHA-256
`7ced0368c8b8a98e99f46de0385415d83c126087fd064d793cc71f16ab043540`；features
严格为 `ax-driver/nvme, fs, rt-trace, qemu-aarch64-three-guest-net`，没有
`preempt`。release ELF/raw 分别为 `58356560`/`56725552` bytes，SHA-256 为
`915a53c1ae62f927926f70060b4548b0c65c8fbd2e00b4be8f8ed0b5fc2ab5d0`/
`467d745f0093a2741804810da1c6acb0fc0128b9a1e3503f245840e8c87a817a`。
build manifest 为 `925` bytes、SHA-256
`e8a4e0cb5b15eba2aee5fe6d8d4b6463977c742740120b7c6705fa09e1130fb7`；setup
manifest 为 `1728` bytes、SHA-256
`96852c75745d55531c9844db60f0619279f5fab5ba2aa8b7c5b6ee4eeb8d7160`。
Linux-1/Linux-2/Zephyr TOML 分别为 `934/934/796` bytes，SHA-256 为
`5f5c533aab3d2ace955a8c09883a7bf70c379e117e07c2b70b66e3356c6cd45b`、
`43f7eb26b724bff4c364c3c720fb819e9747508e5ebcee67d6db296fcfc84270`、
`3ba6e33198cafa139948350f4464ae2fc911fa4b0439803ac4587c27f8e33e64`。
两轮 runner sidecar 都与 build manifest byte-identical；启动策略严格为两个
`Periodic,false,Halt` 和一个 `Tickless,true,Busy`。

正式筛选前的 45 秒 safety smoke 保留在
`/tmp/axvisor-timer-broker-iteration-147-smoke.log`。它确认 host RAM reservation
恰有一个精确的 `[0x80000000,0xb0000000)` 区间，buddy 初始化区间为
`[0xb0000000,0x240000000)`，追加区间为 `[0x40000000,0x40200000)` 和
`[0x43bd5000,0x80000000)`，所有 allocator 区间在数学上互不相交。三条网络 marker
及 `9999/9999` callback 全部通过，tick gap `0/0`，maximum `606 us`，miss
`2/1/0`，callback max `31808 ns`。QEMU hub 77 上恰有三个 virtio-net NIC；
shared-memory、IVC、vsock、virtio socket、vhost-vsock 均未出现，三个 sidecar
都是有效 Ethernet PCAP。所有 guest 通信从 smoke 到两轮筛选始终只走 virtio-net。

iteration 147 启动了 45 秒同步筛选并完成两条 Linux-to-Zephyr、Linux 间
TCP/8080 和 `9999/9999` RTBENCH。保留的执行上下文将该轮记为在同步 collector
finalization 前中断，但没有保留可独立验证 controller signal 或 exit status 的
machine-readable artifact。`/tmp/axvisor-timer-broker-iteration-147-trace` 只有原始
schedstat、console、QMP/map 和 probe，没有 metadata、annotated samples、summary
或 trace report。因此可复现处置只基于这些 finalization artifacts 缺失：本轮按
invalid screening 处置，不能视为完整同步性能结论。CSV 仍按“失败/回退轮不得省略”
的规则记录 console 中的事实字段：
p99.9 `0 us`、p99.99 `240240 ns`、maximum `1236 us`、miss `2/1/1`、callback
max `28960 ns`、tick gap `0/0`；`network_validation=pass` 只表示三条网络 marker
通过，`candidate_decision=failed_incomplete_synchronized_trace_missing_finalization_artifacts`。

iteration 148 复用完全相同的已验证 artifact，并以独立 inode 的专用
`/tmp/axvisor-timer-broker-iteration-148-rootfs.img` 开始于冻结的 `12cfc...` bytes；
运行后该副本变为
`44ad9ec8276bac5b200313ad1698be9efed9a8bd6b915611ee0a077056c732f8`，冻结 source
保持不变。完整 45 秒 collector 使用 `CLOCK_MONOTONIC_RAW` 和 `500 us` 目标周期，
wall duration 为 `45009008678 ns`，产出 `360004` 行且无负/倒退 delta。main-loop
及三个 vCPU 各有 `90001` samples；main-loop、vCPU0、vCPU1、RTOS vCPU2 的最大
run delay 分别为 `1776768/15230/984965/39790 ns`。RTOS vCPU2 状态为
`R=88613`、`S=1388`，其中 `futex_do_wait=1377`；QMP/affinity 只映射出三个唯一、
unbound、`SCHED_OTHER` 的 vCPU TID。network、policy、reservation、allocator gate
全部通过。可选 QEMU log trace backend 为 `unavailable/no_trace_file`，但 schedstat、
QMP、metadata 均完整，不影响本轮同步筛选有效性。

guest RTBENCH 为 p99.9 `0 us`、p99.99 `298016 ns`、maximum `357 us`、miss
`7/0/0`、callback max `43456 ns`、tick gap `0/0`。IRQ 记录为 entries/callbacks
`10000/10000`、overflow `9744`、entry-to-callback max `177520 ns`、entry 时
overdue max `606640 ns`；overdue sample/compare/entry 为
`531/34943750/34981665`，trace start/report 为 `1687231/626841344`，last
CTL/CVAL 为 `0x05/626693750`。RTTRACE frequency 为 `62500000`，guest/external
exits 为 `10000/0`，AxVM deadline publications 为 `18121`，ring 为 `4096`；
`entry_to_exit_ticks=18446744073664825956 = 2^64 - 44725660` 是无符号下溢/回绕，
不是可信 latency，`exit_to_handler_ticks` 和 `handler_to_finish_ticks` 均为 `0`。

与 iteration 146 相比：p99.9 保持 `0 us`；p99.99 从 `595248` 降至 `298016 ns`，
改善 `297232 ns`（`49.934145%`）；maximum 从 `1185` 降至 `357 us`，改善
`828 us`（`69.873418%`）；miss 从 `8/2/1` 变为 `7/0/0`；但 callback max 从
`35936` 增至 `43456 ns`，回退 `7520 ns`（`20.926091%`），tick gap 仍为 `0/0`。
上述结果只是跨不同冻结 build identity 的描述性筛选算术：iteration 146 与 148 的
ELF/raw 及三份 VM TOML 均不同，不能作为 timer broker/remediation closure 的
单变量因果归因。
因此 iteration 148 的 `network_validation=pass`，`candidate_decision` 为
`screen_pass_single_tcg_repetition_tail_improved_callback_max_regressed_not_physical_acceptance`。
timer broker、host RAM reservation 和 current-config consumption 修复按 correctness
证据继续接受；单次 QEMU TCG screening 不证明稳定性能收益、优秀实时性、裸机等价
或 physical acceptance。

原计划只追加一个 completed row，但 iteration 147 已实际启动并产生 guest output，
批准规则要求失败/回退运行不得省略，所以报告按证据诚实性先将 147 记为缺少
finalization artifacts 的无效轮，再记录 148 的完整有效轮。CSV 因此恰好追加两行，
而不是把 147 的事实输出伪装成 valid synchronized metrics 或静默丢弃。

### 迭代 149--154：稳定性否定与 PPI 27 边界收敛

iteration 149--150 在不重建的前提下复用 iteration 148 的 ELF/raw、三份 VM TOML、
QEMU 11.0.2 和冻结 rootfs source。两轮均完成三条网络门禁和 `9999/9999`
callback，但 p99.99 分别为 `53.490304/23.302176 ms`，maximum 为
`54.484/24.294 ms`，`>1 ms` miss 为 `55/24`。因此 148--150 的 p99.99
min/median/max 为 `0.298016/23.302176/53.490304 ms`，maximum 为
`0.357/24.294/54.484 ms`，miss `>100/>500/>1 ms` 合计 `92/81/79`；iteration
148 的单轮 screen pass 不稳定，候选明确拒绝。

149--150 的 callback max 只有 `28.576/28.000 us`，但 PPI 27 在 guest IRQ entry
时已经 overdue `54.701984/24.559920 ms`。`irq_trace entries=9945/9976`，比同一
trace 摘要内部的 `callbacks=10000` 少 `55/24`，恰好等于 `>1 ms` miss；坏轮主要
由一次晚 IRQ 后 Zephyr 补跑多个 1 ms 周期形成，不是 callback 计算或统计开销。
同步 schedstat 在最坏窗口内没有足以解释 24--54 ms 的 runnable delay；RTOS QEMU
vCPU 从 `S/futex_do_wait` 唤醒的窗口与 callback 对齐。

iteration 151 启用全部 QEMU ARM generic-timer 内置事件，产生 `1.5 GB`、
`27834145` 行且缺少 CPU identity、时间和 CNTVOFF，按过度扰动、不可归因诊断记录。
iteration 152 的低扰动自定义事件仍只记录 raw count，缺 CNTVOFF，按无效归因诊断记录。
iteration 153 增加 offset 后证明 QEMU `GTIMER_VIRT` assert 点最大有效 overdue 只有
`0.954576 ms`，而同轮 guest IRQ-entry overdue 为 `4.827776 ms`，否定“QEMU
generic timer callback 本身解释全部长尾”的假设。

iteration 154 再增加 QEMU outer IRQ take 锚点。guest 最坏 CVAL 为 `0x11aa83ac`；
QEMU 首次 assert 的 host monotonic 时间为 `1679686471145298 ns`，实际
`EXCP_IRQ` take 为 `1679686475979342 ns`，间隔 `4.834044 ms`，覆盖 guest
`4.846992 ms` overdue 的绝大部分。由此根因边界收敛到 QEMU timer output 已 assert
之后、外层 Axvisor CPU 实际接收 IRQ 之前；现有证据更具体地指向 level PPI 未形成
及时唤醒/可接收转换，或外层 CPU 当时不能接收 IRQ。它尚不能区分 QEMU GIC line
保持高电平未产生新 kick 与外层 guest IRQ mask，故本轮不做猜测性代码修复。

151--154 使用诊断 QEMU 或额外 trace，均只用于边界定位，不作为正式性能候选、裸机
对照或 physical acceptance。正式 QEMU 可执行文件已恢复并复核 SHA-256 为
`84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956`。
为了在临时文件清理后仍能复核诊断 provenance，iteration 152--154 的 QEMU
SHA-256 依次为 `fcb7ab4fdb6e63d5c537356249b57a70279e85f0233bab8d73d0074ee093c041`、
`a8b62e33f93494ec1aba0567144c4443ec50311ece55e2d5a68707c00c65421e` 和
`9da1a7d8ab7efdec6794e7dcc93b6bc2453e9f1d7c4bc30f7a319fd53750a79d`。
三者均以 QEMU 11.0.2 为基线，只在 `target/arm/helper.c` 的
`timeridx == GTIMER_VIRT && irqstate` 条件记录 assert：152 的事件字段为
`cpu/virtual_ns/count/cval`，153 改为 `cpu/virtual_ns/raw_count/offset/cval`，154
再增加 `host_ns`；154 还在 `target/arm/cpu-irq.c` 的 `excp_idx == EXCP_IRQ`
条件记录 `cpu/host_ns/raw_count/offset/cval`。这些事件不改变 timer/GIC 状态，正式
QEMU source 和 executable 均已恢复。

作为下一轮单变量对照，显式 `tcg,thread=multi` 的第 4 轮完成两条 ICMP、TCP/8080
和 `9999/9999` callback，最大延迟为 `633 us`，`>100 us/>500 us/>1 ms` miss 为
`1/1/0`。它没有稳定优于正式 no-poll 基线的 `515/307/84 us`，因此候选拒绝，正式
配置保持默认 TCG 参数。该结果是宿主/QEMU 环境对照，不是 Axvisor 代码优化收益。

继续测试 QEMU TCG 的 translation-block cache，将单变量参数设为
`-accel tcg,tb-size=512`。三轮均完成三条网络验证和 `9999/9999` callback，但最大
延迟为 `45843/33514/663 us`，`>1 ms` miss 为 `45/33/0`，p99.99 为
`44.847/32.531/0.537 ms`。前两轮的毫秒级长尾远差于正式 no-poll 的
`515/307/84 us`，第三轮也未稳定优于基线，因此拒绝该 QEMU 配置，正式配置仍使用
默认 TCG。原始日志为 `/tmp/axvisor-rtbench-tcg-tb512-r1.log` 至 `r3.log`，CSV
为迭代 `84--86`。这进一步说明当前长尾对 TCG 执行配置和宿主调度高度敏感，不能
把它归因到 AxVM timer wheel，也不构成硬实时优化收益。

本轮完成了低扰动 Zephyr PPI 27 诊断埋点，并用独立 instrumented 镜像运行正式三 guest
网络 workload。pCPU 2 诊断轮次的 `overdue_at_entry_max_ns` 为 `1249872 ns`，而
callback 最大执行时间仅 `63872 ns`，说明最严重的长尾发生在 CNTV compare 到期之后、
GIC 取出 PPI 27 之前；这与 callback 自身耗时无关。该轮 Linux initramfs 曾误用动态
BusyBox，Linux 启动失败，故不作为完整网络验收，只保留为诊断数据。

基于该证据又测试了把 RTOS vCPU 和 GPPT GICR 从 pCPU 2 迁移到空闲 pCPU 3 的单变量
候选。三轮均完成两条 ICMP、Linux 间 TCP/8080 和 `9999/9999` callback，最大延迟为
`401/669/1805 us`，p99.99 为 `188.144/449.312/1344.512 us`，`>1 ms` miss 为
`0/0/2`。相对正式 pCPU 2 no-poll 基线 `515/307/84 us`，该候选没有稳定改善，
第三轮反而出现 2 次超过 1 ms，已拒绝；正式配置仍使用 pCPU 2。setup 脚本同时修复
了动态 BusyBox 导致 Linux `/init` panic 的测试基础设施问题：自动从 guest initramfs
提取并校验静态 BusyBox。

结合源码复核，下一阶段的最高优先级不是继续猜测 guest-entry 指令，而是补齐
事件边界：当前 FIFO vCPU task 在绑定的 pCPU 上连续处理 `Continue`，host timer
虽然可以进入，但不会自动触发其他 ready task 的抢占；同时 ArceOS 和 AxVM 都有
写入 host one-shot comparator 的路径。这个 comparator broker 问题只适用于
AxVM/非-passthrough timer，正式 Zephyr `/timer` 仍是 passthrough。因此先在
Zephyr GIC PPI 27 的 IRQ-entry、CNTVCT/CVAL/CTL、callback 和下一次 compare 点
保存低扰动 ring-buffer 样本，并给 Axvisor guest entry/exit 与 host timer 设置点
添加同一时钟域的时间戳。只有能将单个 miss 定位到 guest、Axvisor、QEMU 或宿主
runqueue 后，才实施下一轮单变量调度/比较器修复。

该候选还有明确的适用边界：正式三 guest 配置将 Zephyr 的 `/timer` 作为 passthrough
设备，RTOS 的主要 timer compare/IRQ 不经过 AxVM timer wheel；provider 因而不是这次
正式 workload 的主要延迟路径。后续优化不能继续假设所有 guest timer 都会经过 AxVM
wheel，而应直接测量 passthrough timer compare、QEMU vCPU 执行片段和宿主调度等待。

建立无网络单 RTOS 对照时，旧配置曾因生成 FDT 丢失 `/aliases`、`/chosen`，以及
identity-memory 场景的 DTB 实际加载地址与 vCPU `x0` 不一致而失败；旧日志中的
高地址 MMIO `0xb9e0070c0` fault 不计入实时性数据。现已修复 FDT 保留规则和
显式 `dtb_load_addr=0xaf000000` 的有效性检查，并通过端到端 Zephyr 启动。修复后
三轮单 RTOS idle/低优先级对照已完成，结果记录为 CSV 迭代 63--68。

本轮继续评估 per-VM host timer policy。第一版实现从 VMM 启动线程通过
`run_on_cpu_sync` 关闭 Zephyr 所在 pCPU 的周期 timer，但当前 Axvisor 正式构建只启用
`wake-ipi`，没有注册同步 IPI callback，因此日志明确报告
`VM[3] failed to disable host periodic timer ... Unsupported`；该轮只作为失败的
策略生效证据，不能作为 tickless 性能数据。修复后将策略应用点移到已经绑核的 vCPU
任务：任务首次运行前在目标 pCPU 本地关闭周期 timer，挂起或退出前恢复，恢复运行后
再次关闭。这样避免了未启用的跨 CPU callback，并由架构契约测试锁定生命周期边界。

在同一 release binary、同一 QEMU TCG 默认配置、同一两 Linux + Zephyr 网络 workload
下，修复后的周期模式控制轮最大延迟为 `312/633/1190 us`，p99.9 均为 `0 us`，
`>1 ms` miss 为 `0/0/1`；三轮都完成 `9999/9999` callback，Linux-1/2 到
Zephyr 的 ICMP 及 Linux-1 到 Linux-2 的 TCP/8080 最终均通过（HTTP 个别轮次首次
连接被拒绝后重试成功）。修复后的 tickless 候选四轮均出现
`VM[3] host periodic timer disabled on current vCPU pCPU` 生效日志，最大延迟为
`380/1811/660/421 us`，p99.9 为 `0/0/0/0 us`，`>1 ms` miss 为 `0/1/0/0`，
callback 均为 `9999/9999`，网络最终均通过。相对周期控制，tickless 没有同时稳定
改善 p99.9、最大延迟和 deadline miss，也仍远高于裸机 QEMU 低优先级参考
`14/17/19 us`，因此保留为可选实验策略但不设为默认优化；它修复了策略未生效的
真实边界问题，不能宣称达到裸机级硬实时。

本轮原始日志为 `/tmp/axvisor-rtbench-host-timer-periodic-control-r1.log` 至
`r3.log`、未生效轮 `/tmp/axvisor-rtbench-host-timer-tickless-r1.log`、公平控制轮
`/tmp/axvisor-rtbench-host-timer-periodic-postfix-r1.log` 至 `r3.log`，以及 tickless
候选轮 `/tmp/axvisor-rtbench-host-timer-tickless-local-r1.log` 至 `r4.log`。
对应数据追加为 CSV 迭代 `91--111`。

继续验证宿主归因候选时，使用 `taskset -c 4-11`、显式 `tcg,thread=multi`、tickless
和同一三 guest workload。CPU affinity 候选三轮最大延迟为 `212/397/3049 us`，
`>1 ms` miss 为 `0/0/4`，没有稳定改善，拒绝。随后增加可选的
`host_vcpu_yield = true`：vCPU 每次完成 guest exit、deferred IRQ 和 suspend/stop
检查后才让出一次宿主调度器，默认值为 `false`。三轮最大延迟为 `0/648/2370 us`，
`>1 ms` miss 为 `0/0/3`，网络和 callback 均完成，但同样没有稳定优于 affinity
tickless 控制，因此拒绝默认化。两组数据追加为 CSV 迭代 `102--107`；这两个开关
保留用于后续真实 ARM/KVM 或宿主隔离环境的重复实验。

为拆分 `host_vcpu_yield` 与 affinity 的交互，又在默认 QEMU TCG（无 taskset、无显式
TCG multi）下运行 tickless + yield 四轮。最大延迟为 `555/243/137/0 us`，四轮均无
超过 1 ms 的 miss；p99.9 均为 `0 us`，callback 均完成 `9999/9999`，网络最终均
通过，其中两轮 HTTP 首次连接拒绝后重试成功。它是当前 QEMU 环境中最好的候选，数据
为 CSV 迭代 `108--111`，但仍明显高于裸机 QEMU `14/17/19 us` 的低优先级参考，且
宿主 governor 仍为 `powersave`、加速器仍为 TCG，因此暂不把它宣称为裸机级硬实时；
正式默认配置继续保持 `host_vcpu_yield = false`，候选只通过配置显式开启。

随后单独验证了 FIFO 保持不变、仅打开 ArceOS `preempt` 的候选。先补齐 axbuild 与
ax-std 的 feature forwarding，使实验构建日志明确包含 `ax-std/preempt`；正式
`qemu-aarch64.toml` 没有打开该 feature。三轮完整测试均完成两条 ICMP、TCP/8080
和 `9999/9999` callback，但最大延迟为 `5674/1294/576 us`，p99.9 为
`1418/0/0 us`，p99.99 为 `4687.808/298.848/0 us`，`>1 ms` miss 为
`13/1/0`。第一轮 compare overdue 最大值达到 `5880.192 us`，callback 最大执行
时间仅 `45.856 us`，说明抢占候选没有改善真正的 IRQ 交付长尾，反而引入了额外
调度扰动。相对正式 FIFO no-poll `515/307/84 us` 和当前 tickless + yield
候选 `555/243/137/0 us`，该候选明确拒绝，不设为默认；原始日志为
`/tmp/axvisor-rtbench-preempt-fifo-r1.log` 至 `r3.log`，CSV 为迭代 `112--114`。

随后根据 `run_vcpu()` 会连续处理 `BoundVcpuExit::Continue` 的源码证据，测试了
默认关闭的 cooperative exit budget。候选先用架构契约锁定“达到预算后必须先
unbind vCPU、再让出宿主调度器”，然后测试每 `64` 个连续 exit 执行一次 yield。
事后审计发现第二批三轮只修改了生成 TOML，没有重新构建嵌入 VM 配置的 Axvisor，
因此六轮实际全部是 budget 64，不能声称测过 budget 1024。六轮最大延迟为
`338/16307/16320/59544/646/1823 us`，p99.9 为
`0/6334/6335/49556/0/12 us`，`>1 ms` miss 为 `0/19/17/76/0/2`。第 5 轮缺少
Linux-2 ping 完成文本，其余轮次网络最终通过，所有轮次都完成 `9999/9999`
callback。候选显著放大 TCG/宿主调度时间片，代码和配置字段已撤回；原始日志文件名
仍含历史 `budget1024` 字样，但 CSV 迭代 `115--120` 已纠正为 budget64 r1--r6。

为了进一步隔离外层调度，新增 QMP 驱动的精确 vCPU affinity runner：QEMU 使用
`tcg,thread=multi`，四个 QEMU vCPU 线程分别固定到 host CPU `4/5/6/7`，其中
Axvisor pCPU 2 对应线程固定到 CPU 6，其余 QEMU 线程限制到 CPU `8-15`。QMP
映射文件确认三轮均实际生效，但最大延迟为 `8762/1307/2255 us`，p99.9 为
`1582/47/0 us`，`>1 ms` miss 为 `14/2/2`；两条 ICMP、TCP/8080 和 callback
均完成。该候选同样拒绝。当前用户权限不能启用 QEMU `SCHED_FIFO`，`chrt -f 1`
返回 `Operation not permitted`。这组结果进一步表明，在当前 x86_64 主机的
AArch64 TCG 上，仅调整 Axvisor cooperative loop 或 QEMU affinity 不能稳定达到
裸机 QEMU `14/17/19 us`；下一验收边界必须是 AArch64 KVM/真实 ARM 和可控的宿主
实时调度环境。

最后筛选了仅将 QEMU RAM 从 `8 GiB` 降到 `2 GiB` 的单变量，以检查 TCG 页表和
宿主页压力。地址窗口仍覆盖三个 guest，启动、两条 ICMP、TCP/8080 和
`9999/9999` callback 均完成，但首轮最大延迟为 `3332 us`、p99.99 为
`2336.112 us`，并有 3 次超过 `1 ms`。它在首轮即明显差于正式基线，故按筛选
规则停止，不扩展为三轮候选；CSV 迭代 124 保留，正式 QEMU RAM 仍为 `8 GiB`。

随后通过 QMP 将两个 Linux vCPU 与未使用 vCPU 设为 `SCHED_IDLE`，RTOS vCPU 保持
`SCHED_OTHER`。三轮最大延迟为 `1768/610/2005 us`，`>1 ms` miss 为 `1/0/2`；
该策略反而加剧长尾，CSV 迭代 `125--127` 作为拒绝证据。

移除未使用的 QEMU/Axvisor CPU 3 后，periodic 控制四轮最大延迟为
`38/1262/343/627 us`，仍有一轮超过 `1 ms`。首次组合轮虽然得到 `61 us`，但配置
审计发现实际启动的 `axvisor.bin` 比新 ELF 更旧：VM TOML 只在构建期嵌入，直接
重启 QEMU 不会更新配置，所以该轮记为 `invalid_stale_raw_binary`，不计入 tickless
结果。现已在 VM 创建前打印解析后的 timer/yield 策略，并让 affinity runner 在默认
raw image 比 ELF 更旧时拒绝启动。另一个 `79 us` 诊断轮确认策略生效，但 xtask 的
`--smp 3` 只改变 Axvisor 编译配置，QEMU TOML 仍启动 4 CPU，故同样不纳入 SMP3
组合结论。

使用显式 QEMU `-smp 3` 后，tickless + yield 三轮有效最大延迟为 `0/0/378 us`，
p99.99 为 `0/0/120.512 us`，`>500 us` 和 `>1 ms` 均为 0；三条网络验证、策略
生效日志和 callback 完成标记齐全。去掉 PPI 27 IRQ trace 后，callback 最大执行时间
降为 `20.832/16.736/34.592 us`，但端到端最大值为 `710/353/18 us`，没有稳定改善，
因此无 trace 组作为拒绝候选记录。相关数据为 CSV 迭代 `128--139`。

为排除嵌入 TOML 与 raw binary 不一致，本轮把配置转换下沉到可宿主测试的
`AxVMConfig::from_crate_config()`，以真实 Rust 单测验证 tickless/yield 透传；同时
重建 SMP3 release Axvisor，并用 `rust-objcopy` 和 validator 证明 ELF/raw 字节一致、
三份非空 VM TOML 完整嵌入。新 raw SHA-256 为
`2010ab4788aae2d344c1b2d08a23869ceb869127f4953a8649ff47e752156573`，manifest 为
`/tmp/axvisor-iteration-140-build-manifest.tsv`。第一次 setup 因默认
`/tmp/.axvisor-images` 属于其他用户而在 initramfs staging 前失败，没有进入构建或
benchmark；改用 `/tmp/axvisor-iteration-140-assets` 后准备成功。随后一次未重定向
console 的 smoke 得到 `2729 us`，因没有原始日志不写入 CSV；正式三轮日志为
`/tmp/axvisor-iteration-140-r1.log` 至 `r3.log`，最大延迟
`569/4996/2678 us`，确认该候选不能稳定复现历史最佳值，CSV 为迭代 `140--142`。

## Same-board bare-metal acceptance 状态

记录日期为 `2026-08-07`，目标为 `board=orangepi-5-plus`。在当前没有设置任何
`AXVISOR_RT_*` 变量的环境中执行：

```bash
bash docs/docs/build/axvisor/check_real_arm_board_docs.sh   --realtime-preflight orangepi-5-plus   >/tmp/axvisor-orangepi-5-plus-realtime-preflight-after.log 2>&1
```

checker 按预期退出 `1`；这表示资产 gate 正确拒绝开始测量，不是 preflight 测试
失败。`/tmp/axvisor-orangepi-5-plus-realtime-preflight-after.log` 的精确输出是：

```text
FAIL missing realtime input: AXVISOR_RT_BOARD_DTB
FAIL missing realtime input: AXVISOR_RT_LINUX1_IMAGE
FAIL missing realtime input: AXVISOR_RT_LINUX2_IMAGE
FAIL missing realtime input: AXVISOR_RT_ZEPHYR_IMAGE
FAIL missing realtime input: AXVISOR_RT_LINUX1_VM_CONFIG
FAIL missing realtime input: AXVISOR_RT_LINUX2_VM_CONFIG
FAIL missing realtime input: AXVISOR_RT_ZEPHYR_VM_CONFIG
FAIL missing realtime input: AXVISOR_RT_POWER_RESET
FAIL missing realtime input: AXVISOR_RT_SERIAL_CAPTURE
FAIL missing realtime input: AXVISOR_RT_NET0_DEVICE
FAIL missing realtime input: AXVISOR_RT_NET1_DEVICE
FAIL missing realtime input: AXVISOR_RT_NET2_DEVICE
FAIL missing realtime input: AXVISOR_RT_NET0_IRQ
FAIL missing realtime input: AXVISOR_RT_NET1_IRQ
FAIL missing realtime input: AXVISOR_RT_NET2_IRQ
FAIL missing realtime input: AXVISOR_RT_TRAFFIC_PEER
```

全部 16 个外部 input 都缺失。当前 checked-in Orange Pi 5 Plus 资产不能运行要求的
两个 Linux 加 Zephyr 网络负载：现有板级链路只覆盖单 Linux，RTOS 配置没有可用于
三 guest workload 的独立网络设备/IRQ、唯一 VM id 和不重叠 pCPU 组合。preflight
不发现、不回退到 QEMU artifact，也不使用虚拟板替代实体板。iterations 147--148
仍是 x86_64 host 上的 AArch64 QEMU TCG 筛选，不是 same-board/bare-metal-level
结果。

批准阈值保持不变：每次 Axvisor run 必须通过 full callback/network 且有
`0` 个 `>1 ms` miss；p99.9、p99.99 相对 bare metal 的差值必须分别在
`max(25%, 10 us)` 以内；maximum 必须满足
`Axvisor maximum <= bare-metal maximum + max(2 x bare-metal maximum, 50 us)`。Axvisor 与 bare-metal 的三次配对重复必须
保持相同 RTOS binary options、tick、counter、governor 和 traffic。资产 gate 通过
后仍必须完成这些测量和比较才能批准。也就是说，physical acceptance 仍须先提供
全部 16 个 `AXVISOR_RT_*` input，再在同一实体板完成三次 Axvisor/bare-metal
配对重复；单轮 TCG screen 不能替代其中任何一项。

本次没有连接或控制实体板，也没有真实测量；CSV/PNG 只追加 QEMU TCG remediation
筛选证据。当前 same-board 结论保持外部硬件/资产 `BLOCKED`，不声明目标完成。

## 环境

- 报告更新日期：2026-08-07（新增 TCG remediation 筛选；仍无物理测量）
- Axvisor：QEMU AArch64，Cortex-A72，GICv3；正式配置 4 vCPU，SMP3 确认组合 3 vCPU
- 模式：timer/GIC passthrough，Zephyr vCPU 固定到物理 CPU 2
- 加速器：AArch64 guest 在 x86_64 宿主上使用 QEMU TCG；没有 KVM 加速
- QEMU：`/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`，版本 `11.0.2`；
  `-accel help` 仅列出 `tcg`，`-accel kvm` 实测报 invalid accelerator
- iteration 147--148 QEMU：`/home/yfblock/Env/qemu-11.0.2/build/qemu-system-aarch64`，
  版本 `11.0.2`，SHA-256 为
  `84630fc116fb9c7cc665e329b7f7c071469a0dc356ed541630d37a91baa36956`
- 宿主：AMD Ryzen 9 9950X，32 logical CPUs；当前 governor 为 `powersave`；
  绑核对照分别使用 `taskset -c 4-7` 和 `taskset -c 4-11`
- Guest：Linux-1、Linux-2、Zephyr
- Zephyr counter：62,500,000 Hz
- Zephyr tick：`CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000`（当前正式优化版本）
- 正式无 IRQ trace Zephyr 镜像 SHA-256：
  `10bfbffb0bca491a0cc6b36f0a000bce5e1d268b9a0ebc0f3b4b187ae0775b11`
- SMP3 trace 候选 Zephyr 镜像 SHA-256：
  `6512d5cbcb0ef50dc6f417768773f370989c803ce3b3fae7a02734939553018f`
- Zephyr 日志：`CONFIG_LOG=n`；正式镜像使用 virtio SPI 中断路径，关闭状态轮询
- Zephyr timer：ARM virtual timer，PPI 27
- 网络：三个独立 virtio-net 设备通过 QEMU hubport 连接
- 通信：仅使用网络；没有共享内存或 virtio socket
- 裸机参考：同一 `zephyr-rt-bench`，QEMU `virt`、1 vCPU、ELF loader、RAM
  overlay `0x41000000`；不包含 Linux 或网络流量，仅用于 QEMU 归因对照

## 根因

未修复的 probe 日志为：

```text
group=0x0
hppir0=0x1b
hppir1=0x3ff
```

其中 `0x1b` 是 PPI 27。计数器 compare 已到期，PPI 也已 pending，
但它属于 Group 0；Zephyr 的 EL1 IRQ 路径通过 `ICC_IAR1_EL1` 读取 Group 1，
所以 `k_sleep()` 永远等不到系统 tick。

Zephyr GICv3 驱动在未定义 `CONFIG_ARMV8_A_NS` 时将 SGI/PPI 的 group 设置为
0；定义该选项后将其设置为 Group 1，并启用 Non-secure Group 1 distributor。
临时把 PPI 27 改为 Group 1，以及正式启用 `CONFIG_ARMV8_A_NS=y`，都使
`RTDIAG after_sleep` 和 `RTDIAG complete` 出现，形成了最小因果验证。

## 第二个问题：网络测试超时

网络 guest 原先使用 `CONFIG_SYS_CLOCK_TICKS_PER_SEC=100`，但 benchmark
周期是 `K_USEC(1000)`。Zephyr 文档明确说明 timeout 精度受 tick rate 限制，
因此 1 ms 周期无法被 100 Hz tick 精确表示，10,000 次测试会超过原有
45 秒超时窗口。

先将 tick 提高到 1 kHz 修复测试量化/超时问题，再以单变量实验提高到 10 kHz。
10 kHz 版本的早期三轮网络负载测试曾达到 `962/77/331 us`，最终 raw-cycle
重测为 `3563/297/629 us`；因此当前配置和 verifier 均固定为
`CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000`。
该修改改善的是 RTOS 定时器调度粒度，不是 GIC 中断安全组根因。

## 网络直通辅助修复

为保证网络负载实验确实测到三个 guest，而不是测到 DMA/路由配置错误，
同时保留了三项 Axvisor 侧修复：

- GICv3 SPI 使用 directed route，清除 Any-PE 路由位并保留目标 affinity。
- 生成 guest FDT 时移除 passthrough virtio 及根节点的 `dma-coherent` 声明。
- passthrough guest RAM 使用 uncached 映射，避免外层 QEMU 设备直接访问 guest
  RAM 时产生缓存一致性假设。

这些修复由 AxVM/arm_vgic 单元测试覆盖，并作为网络连通性前置条件；本报告的
实时性对照没有把它们伪装成单独的 latency iteration。

## 第三个问题：网络轮询干扰实时任务

no-poll 诊断镜像在不读取 `VIRTIO_MMIO_INTERRUPT_STATUS`、不主动写
`VIRTIO_MMIO_INTERRUPT_ACK` 的情况下，仍通过 Linux-1/2 到 Zephyr 的 ICMP、
Linux-1 到 Linux-2 的 TCP/8080，以及 9999/9999 次 timer callback。这证明
passthrough virtio SPI 的真实中断路径可用；原来的 1 ms MMIO 轮询不是必要的
可靠性措施，而是额外的 vCPU 唤醒和设备访问竞争源。

因此将 `AXVISOR_DISABLE_VIRTIO_IRQ_POLL` 固定加入 Zephyr 网络 guest 的
`CMakeLists.txt`。轮询实现仍保留在源码中，只能通过不带该正式定义的诊断构建
启用；正式镜像不再包含轮询执行路径。

## 迭代结果

| 轮次 | 场景 | 回调/预期 | p99 | p99.9 | 最大延迟 | >100 us | >500 us | >1 ms |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 修复前三 guest | 0/10000 | NA | NA | NA | NA | NA | NA |
| 3 | 单 guest idle | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 4 | 单 guest 低优先级负载 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 5 | 三 guest 网络，重复 1 | 9999/9999 | 0 us | 18 us | 1984 us | 10 | 4 | 2 |
| 6 | 三 guest 网络，重复 2 | 9999/9999 | 0 us | 0 us | 1021 us | 3 | 1 | 1 |
| 7 | 三 guest 网络，重复 3 | 9999/9999 | 0 us | 0 us | 1550 us | 2 | 2 | 1 |
| 8 | 关闭日志 + `k_sleep(1 ms)`，重复 1 | 9999/9999 | 0 us | 0 us | 1231 us | 3 | 1 | 1 |
| 9 | 关闭日志 + `k_sleep(1 ms)`，重复 2 | 9999/9999 | 0 us | 0 us | 1009 us | 2 | 2 | 1 |
| 10 | 关闭日志 + `k_sleep(1 ms)`，重复 3 | 9999/9999 | 0 us | 0 us | 1513 us | 3 | 2 | 1 |
| 11 | 精确 cycle/ns 测量，1 kHz | 9999/9999 | 0 us | 0 us | 1203 us | 4 | 2 | 2 |
| 12--14 | 显式 TCG multi 对照 | 9999/9999 | 0 us | 0 us | 344/2339/567 us | 1/6/1 | 0/3/1 | 0/2/0 |
| 15--17 | 显式 TCG single 对照 | 9999/9999 | 2251/0/1876 us | 5000/4036/5000 us | 9325/7043/9745 us | 532/48/407 | 316/37/351 | 268/29/199 |
| 18 | 10 kHz tick，重复 1 | 9999/9999 | 0 us | 0 us | 962 us | 2 | 1 | 0 |
| 19 | 10 kHz tick，重复 2 | 9999/9999 | 0 us | 0 us | 77 us | 0 | 0 | 0 |
| 20 | 10 kHz tick，重复 3 | 9999/9999 | 0 us | 0 us | 331 us | 1 | 0 | 0 |
| 21 | 10 kHz 最终 smoke | 9999/9999 | 0 us | 0 us | 99 us | 0 | 0 | 0 |
| 22 | 10 kHz + raw-cycle 阈值，最终重测 1 | 9999/9999 | 0 us | 0 us | 3563 us | 6 | 5 | 3 |
| 23 | 10 kHz + raw-cycle 阈值，最终重测 2 | 9999/9999 | 0 us | 0 us | 297 us | 2 | 0 | 0 |
| 24 | 10 kHz + raw-cycle 阈值，最终重测 3 | 9999/9999 | 0 us | 0 us | 629 us | 2 | 1 | 0 |
| 25 | no-poll 诊断镜像，重复 1 | 9999/9999 | 0 us | 0 us | 423 us | 1 | 0 | 0 |
| 26 | no-poll 诊断镜像，重复 2 | 9999/9999 | 0 us | 0 us | 29 us | 0 | 0 | 0 |
| 27 | no-poll 诊断镜像，重复 3 | 9999/9999 | 0 us | 0 us | 133 us | 1 | 0 | 0 |
| 28 | no-poll 正式构建，重复 1 | 9999/9999 | 0 us | 0 us | 515 us | 1 | 1 | 0 |
| 29 | no-poll 正式构建，重复 2 | 9999/9999 | 0 us | 0 us | 307 us | 1 | 0 | 0 |
| 30 | no-poll 正式构建，重复 3 | 9999/9999 | 0 us | 0 us | 84 us | 0 | 0 | 0 |
| 31 | IRQ 单次分发修复，旧 workload 重测 | 9999/9999 | 0 us | 0 us | 2814 us | 4 | 3 | 2 |
| 32 | no-poll + completion semaphore，重复 1 | 9999/9999 | 0 us | 0 us | 92 us | 0 | 0 | 0 |
| 33 | no-poll + completion semaphore，重复 2 | 9999/9999 | 0 us | 0 us | 352 us | 2 | 0 | 0 |
| 34 | no-poll + completion semaphore，重复 3 | 9999/9999 | 0 us | 0 us | 576 us | 1 | 1 | 0 |
| 35 | 宿主绑核 + TCG multi 对照（拒绝） | 9999/9999 | 0 us | 714 us | 4693 us | 18 | 14 | 8 |
| 36 | 新测量边界，默认 no-poll，重复 1 | 9999/9999 | 0 us | 0 us | 449 us | 2 | 0 | 0 |
| 37 | 新测量边界，默认 no-poll，重复 2 | 9999/9999 | 0 us | 0 us | 1081 us | 3 | 1 | 1 |
| 38 | 新测量边界，默认 no-poll，重复 3 | 9999/9999 | 0 us | 0 us | 62 us | 0 | 0 | 0 |
| 39 | 宿主绑核 8 CPU + TCG multi 对照（拒绝） | 9999/9999 | 0 us | 0 us | 362 us | 1 | 0 | 0 |
| 40 | passthrough SPI placement 修复 smoke | 9999/9999 | 0 us | 0 us | 5954 us | 8 | 6 | 6 |
| 41 | guest-entry 上下文缓存候选，重复 1（拒绝） | 9999/9999 | 0 us | 0 us | 251 us | 1 | 0 | 0 |
| 42 | guest-entry 上下文缓存候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 664 us | 2 | 1 | 0 |
| 43 | guest-entry 上下文缓存候选，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 1697 us | 3 | 3 | 1 |
| 44 | 候选撤回后的最终功能 smoke | 9999/9999 | 0 us | 0 us | 4226 us | 5 | 4 | 4 |
| 45 | 裸机 QEMU idle，重复 1 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 46 | 裸机 QEMU 低优先级负载，重复 1 | 9999/9999 | 0 us | 0 us | 14 us | 0 | 0 | 0 |
| 47 | 裸机 QEMU idle，重复 2 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 48 | 裸机 QEMU 低优先级负载，重复 2 | 9999/9999 | 0 us | 2 us | 17 us | 0 | 0 | 0 |
| 49 | 裸机 QEMU idle，重复 3 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 50 | 裸机 QEMU 低优先级负载，重复 3 | 9999/9999 | 0 us | 6 us | 19 us | 0 | 0 | 0 |
| 51 | 一个 Linux + 一个 Zephyr 网络，重复 1 | 9999/9999 | 0 us | 0 us | 403 us | 1 | 0 | 0 |
| 52 | 一个 Linux + 一个 Zephyr 网络，重复 2 | 9999/9999 | 0 us | 0 us | 180 us | 2 | 0 | 0 |
| 53 | 一个 Linux + 一个 Zephyr 网络，重复 3 | 9999/9999 | 0 us | 0 us | 13 us | 0 | 0 | 0 |
| 54 | callback 低扰动测量，重复 1（initramfs 失败） | 9999/9999 | 0 us | 0 us | 1004 us | 1 | 1 | 1 |
| 55 | callback 低扰动测量，重复 2（不采纳） | 9999/9999 | 0 us | 0 us | 1312 us | 3 | 1 | 1 |
| 56 | callback 低扰动测量，重复 3（不采纳） | 9999/9999 | 0 us | 0 us | 96 us | 0 | 0 | 0 |
| 57 | 移除 guest-entry `ic iallu`，重复 1（拒绝） | 9999/9999 | 0 us | 0 us | 8383 us | 10 | 8 | 8 |
| 58 | 移除 guest-entry `ic iallu`，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 77 us | 0 | 0 | 0 |
| 59 | 移除 guest-entry `ic iallu`，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 104 us | 1 | 0 | 0 |
| 60 | 内联 external IRQ 重入候选，重复 1（拒绝） | 9999/9999 | 0 us | 5000 us | 53507 us | 64 | 62 | 60 |
| 61 | 内联 external IRQ 重入候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 855 us | 1 | 1 | 0 |
| 62 | 内联 external IRQ 重入候选，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 4558 us | 5 | 5 | 4 |
| 63 | Axvisor 单 RTOS idle，重复 1 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 64 | Axvisor 单 RTOS 低优先级负载，重复 1 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 65 | Axvisor 单 RTOS idle，重复 2 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 66 | Axvisor 单 RTOS 低优先级负载，重复 2 | 9999/9999 | 0 us | 0 us | 16 us | 0 | 0 | 0 |
| 67 | Axvisor 单 RTOS idle，重复 3 | 9999/9999 | 0 us | 0 us | 0 us | 0 | 0 | 0 |
| 68 | Axvisor 单 RTOS 低优先级负载，重复 3 | 9999/9999 | 0 us | 2 us | 17 us | 0 | 0 | 0 |
| 69 | FDT 修复后最终三 guest smoke（功能回归） | 9999/9999 | 0 us | 0 us | 1181 us | 5 | 1 | 1 |
| 70 | 临时 `sched-rr` 候选，重复 1（拒绝） | 9999/9999 | 0 us | 0 us | 810 us | 1 | 1 | 0 |
| 71 | 临时 `sched-rr` 候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 753 us | 2 | 1 | 0 |
| 72 | 临时 `sched-rr` 候选，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 54 us | 0 | 0 | 0 |
| 73 | AArch64 IRQ fetch 去重候选，重复 1（拒绝） | 9999/9999 | 0 us | 0 us | 437 us | 1 | 0 | 0 |
| 74 | AArch64 IRQ fetch 去重候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 1 us | 0 | 0 | 0 |
| 75 | AArch64 IRQ fetch 去重候选，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 484 us | 1 | 0 | 0 |
| 76 | 宿主 10 kHz tick 候选，重复 1（拒绝） | 9999/9999 | 0 us | 0 us | 633 us | 2 | 1 | 0 |
| 77 | 宿主 10 kHz tick 候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 904 us | 1 | 1 | 0 |
| 78 | 宿主 10 kHz tick 候选，重复 3（拒绝） | 9999/9999 | 0 us | 0 us | 292 us | 2 | 0 | 0 |
| 79 | FIFO one-shot 候选（启动失败） | 0/9999 | NA | NA | NA | NA | NA | NA |
| 80 | 外部 deadline provider 候选，重复 1（拒绝） | 9999/9999 | 0 us | 1111 us | 3770 us | 32 | 21 | 11 |
| 81 | 外部 deadline provider 候选，重复 2（拒绝） | 9999/9999 | 0 us | 0 us | 224 us | 1 | 0 | 0 |
| 82 | 外部 deadline provider 候选，重复 3（拒绝） | 9999/9999 | 0 us | 5000 us | 18068 us | 26 | 23 | 21 |
| 83 | 显式 TCG multi 候选，重复 4（拒绝） | 9999/9999 | 0 us | 0 us | 633 us | 1 | 1 | 0 |
| 84--86 | TCG `tb-size=512` 候选（拒绝） | 9999/9999 | 0/0/0 us | 5000/5000/0 us | 45843/33514/663 us | 49/36/6 | 47/35/3 | 45/33/0 |
| 87 | PPI trace pCPU 2（Linux initramfs 失败） | 9999/9999 | 0 us | 0 us | 1078 us | 3 | 1 | 1 |
| 88--90 | PPI trace + RTOS pCPU 3 候选（拒绝） | 9999/9999 | 0/0/0 us | 0/0/0 us | 401/669/1805 us | 2/3/7 | 0/1/4 | 0/0/2 |
| 91 | tickless 初版（策略未生效） | 9999/9999 | 0 us | 0 us | 42 us | 0 | 0 | 0 |
| 92--94 | host timer 周期控制（修复前） | 9999/9999 | 0/0/0 us | 5000/0/0 us | 11282/73/143 us | 46/0/2 | 42/0/0 | 36/0/0 |
| 95--97 | host timer 周期控制（公平 release 控制） | 9999/9999 | 0/0/0 us | 0/0/0 us | 312/633/1190 us | 1/2/3 | 0/1/1 | 0/0/1 |
| 98--101 | host timer tickless（pinned vCPU 本地应用，拒绝默认化） | 9999/9999 | 0/0/0/0 us | 0/0/0/0 us | 380/1811/660/421 us | 1/5/3/2 | 0/3/1/0 | 0/1/0/0 |
| 102--104 | taskset 4-11 + TCG multi + tickless（拒绝） | 9999/9999 | 0/0/0 us | 0/0/0 us | 212/397/3049 us | 1/1/5 | 0/0/4 | 0/0/4 |
| 105--107 | taskset 4-11 + TCG multi + vCPU yield（拒绝） | 9999/9999 | 0/0/0 us | 0/0/0 us | 0/648/2370 us | 0/4/5 | 0/3/3 | 0/0/3 |
| 108--111 | 默认 TCG + tickless + vCPU yield（历史候选） | 9999/9999 | 0/0/0/0 us | 0/0/0/0 us | 555/243/137/0 us | 2/2/1/0 | 1/0/0/0 | 0/0/0/0 |
| 112--114 | FIFO + host `preempt` 候选（拒绝） | 9999/9999 | 0/0/0 us | 1418/0/0 us | 5674/1294/576 us | 17/2/1 | 15/1/1 | 13/1/0 |
| 115--120 | cooperative exit budget 64，六轮（拒绝） | 9999/9999 | 0/0/0/0/0/0 us | 0/6334/6335/49556/0/12 us | 338/16307/16320/59544/646/1823 us | 2/28/23/82/1/9 | 0/20/18/78/1/4 | 0/19/17/76/0/2 |
| 121--123 | QMP 精确 vCPU affinity（拒绝） | 9999/9999 | 0/0/0 us | 1582/47/0 us | 8762/1307/2255 us | 28/9/7 | 20/5/3 | 14/2/2 |
| 124 | QEMU RAM 2 GiB 筛选（拒绝） | 9999/9999 | 0 us | 0 us | 3332 us | 4 | 3 | 3 |
| 125--127 | Linux vCPU `SCHED_IDLE`（拒绝） | 9999/9999 | 0/0/0 us | 294/0/39 us | 1768/610/2005 us | 13/3/8 | 7/1/4 | 1/0/2 |
| 128--131 | QEMU/Axvisor SMP3 periodic 控制 | 9999/9999 | 0/0/0/0 us | 0/0/0/0 us | 38/1262/343/627 us | 0/6/3/3 | 0/2/0/1 | 0/1/0/0 |
| 132 | 过期 raw binary（无效） | 9999/9999 | 0 us | 0 us | 61 us | 0 | 0 | 0 |
| 133 | Axvisor SMP3 / QEMU SMP4 拓扑诊断 | 9999/9999 | 0 us | 0 us | 79 us | 0 | 0 | 0 |
| 134--136 | QEMU/Axvisor SMP3 + tickless + yield（历史最佳样本） | 9999/9999 | 0/0/0 us | 0/0/0 us | 0/0/378 us | 0/0/3 | 0/0/0 | 0/0/0 |
| 137--139 | 同组合关闭 IRQ trace（拒绝稳定收益） | 9999/9999 | 0/0/0 us | 0/0/0 us | 710/353/18 us | 4/1/0 | 1/0/0 | 0/0/0 |
| 140--142 | 新鲜产物 SMP3 + tickless + yield 确认（拒绝） | 9999/9999 | 0/0/0 us | 0/0/0 us | 569/4996/2678 us | 1/6/4 | 1/5/4 | 0/5/2 |
| 143 | 同步采集器预检失败（未进入 benchmark） | NA | NA | NA | NA | NA | NA | NA |
| 144--145 | SMP3 同步 schedstat/state/wchan 归因 | 9999/9999 | 0/0 us | 0/0 us | 1459/1362 us | 3/8 | 2/6 | 1/3 |
| 146 | busy-WFI + main-loop 同步筛选（拒绝） | 9999/9999 | 0 us | 0 us | 1185 us | 8 | 2 | 1 |
| 147 | timer-broker 同步筛选（finalization 产物缺失，无效） | 9999/9999 | 0 us | 0 us | 1236 us | 2 | 1 | 1 |
| 148--150 | timer-broker 三轮同步筛选（稳定性拒绝） | 9999/9999 | 0/5000/5000 us | 0/5000/5000 us | 357/54484/24294 us | 7/59/26 | 0/57/24 | 0/55/24 |
| 151 | QEMU ARM timer 全量 trace（过度扰动诊断） | 9999/9999 | 0 us | 3367 us | 11345 us | 26 | 22 | 19 |
| 152 | QEMU IRQ assert raw-count（缺 offset，无效归因） | 9999/9999 | 0 us | 643 us | 4632 us | 17 | 12 | 8 |
| 153 | QEMU IRQ assert effective-count 诊断 | 9999/9999 | 0 us | 68 us | 4573 us | 10 | 6 | 4 |
| 154 | QEMU assert 到 outer IRQ take 诊断 | 9999/9999 | 0 us | 105 us | 4614 us | 11 | 5 | 4 |
其中第 87 轮虽完成 RTOS callback，但 Linux 因动态 BusyBox 无 loader 未完成网络启动，
不计入正式性能比较；第 88--90 轮才是完整 pCPU 3 候选数据。

## IRQ 边界证据

instrumented guest 在 GIC `arm_gic_get_active()` wrapper 中只对 PPI 27 保存固定大小
ring-buffer 样本，包括 `CNTVCT_EL0`、`CNTV_CVAL_EL0` 和 `CNTV_CTL_EL0`；callback
入口只保存 IRQ-entry 到 callback 的最大值，结束后一次性打印摘要。pCPU 2 诊断轮次为：

| 轮次 | IRQ entries | callbacks | entry->callback max | compare overdue at entry max | callback max |
| ---: | ---: | ---: | ---: | ---: | ---: |
| pCPU 2 | 9997 | 10000 | 336.608 us | 1377.520 us | 26.208 us |
| pCPU 3 r1 | 10000 | 10000 | 167.056 us | 606.512 us | 30.416 us |
| pCPU 3 r2 | 10000 | 10000 | 170.960 us | 887.056 us | 26.672 us |
| pCPU 3 r3 | 9997 | 10000 | 992.208 us | 2103.104 us | 38.688 us |

`entries` 比 `callbacks` 少 3 的轮次来自首个/合并 timer callback 没有对应的独立
GIC wrapper 取中断样本，不影响 phase 统计，但说明后续需要继续细化 timer coalescing
语义。当前证据足以定位优化边界：应优先分析 QEMU TCG 线程和宿主 runqueue 等待，
而不是修改 Zephyr callback 或 AxVM timer wheel；正式 Zephyr `/timer` 仍是 passthrough。

第 31 轮网络路径最终成功，但 Linux-2 的 HTTP 服务尚未就绪导致第一次 TCP
连接被拒绝，随后重试成功，因此 CSV 标记为 `pass_after_retry`，不能按完全无
启动时序问题的 pass 解读。第 35 轮网络也成功，但它是控制实验，实时性结果
明显劣于默认 TCG 配置，故不纳入正式优化结论。

第 5--10、12--21、25--44、55--62、70--82 轮均有有效网络证据（控制台日志；第 30 轮另有
`/tmp/axvisor-net0.pcap` 抓包）：

```text
RTBENCH network samples=9999 expected=9999
```

这些有效轮次均验证了 Linux-1 到 Zephyr、Linux-2 到 Zephyr 的 ICMP 通信，以及
Linux-1 到 Linux-2 的 TCP/8080 通信。第 30 轮三个 guest 同时向控制台输出，
两条 `reached Zephyr` 文本发生字符级交错，但 pcap 中可见两次 ICMP request/reply
和完整 TCP/8080 握手与 HTTP 响应；该轮网络验证因此仍记为 `pass`。

第 61 轮 Linux-2 的 HTTP 服务首次连接被拒绝，随后重试成功，故 CSV 标记为
`pass_after_retry`；其余 60、62 轮三条网络链路均直接完成。三轮内联候选的
`interval_max_abs_ns` 为 `53671424/1042960/4770400`，callback 最大执行时间为
`17024/29008/41584 ns`。callback 本身仍远小于 52.5 ms 长尾，支持将候选拒绝
归因于 IRQ/调度路径行为而非 benchmark 统计开销。

第 70--72 轮的 Linux-2 HTTP 服务也均在第一次拒绝后重试成功，故网络字段标为
`pass_after_retry`。三轮 RR 候选的 `interval_max_abs_ns` 为
`972544/931264/250736`，callback 最大执行时间为 `28992/15872/18256 ns`；
它没有产生 `>1 ms` miss，但相对正式 no-poll 的三轮分布没有稳定收益，故只作为
拒绝候选记录，不改变正式配置。

第 45--50 轮是裸机单 guest 对照，不包含网络验证；其有效性由三轮日志中的
`RTBENCH ... samples=9999 expected=9999`、`RTBENCH complete` 和 ELF loader
启动记录确认。裸机参考不替代“两 Linux + 一个 RTOS、仅网络通信”的正式验收。

完整原始数据见
[`rtos-realtime-iterations.csv`](./rtos-realtime-iterations.csv)。

迭代趋势图见
[`rtos-realtime-iterations.png`](./rtos-realtime-iterations.png)，可由
`plot_rtos_realtime_iterations.py` 从 CSV 重新生成。
图中仍保留 invalid/rejected 运行的数值型 guest output；折线连接数据点不表示候选
有效、采纳或验收通过。运行有效性和候选处置必须结合 CSV 的 `candidate_decision`
与本报告对应叙述判断。

## 结果解释和限制

当前 benchmark 在 Zephyr timer callback 中以 62.5 MHz counter 保存原始
phase-error 和 interval-error cycles，并同时输出 ns 级 min/avg/p50/p95/p99/
p99.9/p99.99/max。它还记录 callback 最大执行时间和基于
`k_uptime_ticks()` 的 tick-gap；这些字段用于排除 callback 自身开销和 tick
合并；本轮 instrumented 镜像进一步记录了 PPI 27 的硬件 compare/IRQ-entry 边界。
旧的 `*_us` 字段仍
是整数微秒 histogram，保留用于兼容历史数据；
大量 `p99=0` 不能解释为真实硬件上的零延迟。CSV 中的 `phase_*_ns` 和
`interval_*_ns` 才用于观察亚微秒量化和单周期抖动。

裸机 QEMU 三轮 idle 的 `phase_p99_99_ns` 为 `0/0/0`，低优先级负载为
`9344/16960/14112`；对应 `callback_duration_max_ns` 为
`51696/50912/49184 ns`（idle）和 `15440/16528/15344 ns`（负载）。这组数据
没有观测到 tick 合并，说明单 guest TCG 在本次宿主状态下可以保持很小的周期
误差；Axvisor 三 guest 网络的长尾因此应继续拆分为网络设备竞争、guest 切换和
宿主调度，而不能仅靠 callback 自身耗时解释。

10 kHz 优化版本的早期三轮 `interval_max_abs_ns` 为 `1412672/270560/782752`，
raw-cycle 最终重测为 `3739424/515456/808080 ns`；正式 no-poll 三轮为
`863296/505008/237248 ns`；semaphore 三轮为 `517200/538496/765776 ns`；
旧绑核 TCG multi 对照为 `4872944 ns`；新测量边界三轮为
`627104/1267200/420912 ns`；8 CPU TCG multi 对照为 `565520 ns`；placement
修复 smoke 为 `6139856 ns`；guest-entry 缓存候选三轮为
`627792/967296/1868192 ns`；最终功能 smoke 为 `4559744 ns`。最大延迟和
interval 数据仍显示 guest
调度、QEMU TCG 和宿主调度会产生长尾，网络轮询已从正式执行路径移除；semaphore
没有把主要长尾从虚拟化/宿主侧移走。

低扰动 callback 三轮的 `interval_max_abs_ns` 为 `1179888/1552928/311248`，
`callback_duration_max_ns` 为 `24928/16416/19968`；它降低了测量 callback 的成本，
但没有降低正式三 guest 的调度长尾。移除 `ic iallu` 候选的 interval 最大值为
`8539344/554896/288192 ns`，与首轮 `8383 us` 长尾一致，支持拒绝该候选并恢复
原始 cache/TLB 维护序列。

内联 external IRQ 候选的 interval 最大值为 `53671424/1042960/4770400 ns`，
其中第一轮远高于正式 no-poll 基线，进一步支持恢复 deferred 路径。

迭代 54--56 的 raw callback 低扰动候选、迭代 57--59 的 `ic iallu` 候选、迭代
70--72 的 `sched-rr` 候选、迭代 73--75 的 AArch64 IRQ fetch 去重候选、迭代
76--78 的宿主 10 kHz tick 候选、迭代 79 的 FIFO one-shot 启动失败候选、迭代
80--82 的外部 deadline provider 候选、迭代 83 的显式 TCG multi 候选和迭代 84--86
的 TCG `tb-size=512` 候选、迭代 112--114 的 FIFO + host `preempt` 候选、迭代
115--120 的 cooperative exit budget 候选，以及迭代 121--123 的 QMP 精确 vCPU
affinity 候选、迭代 124 的 QEMU RAM 2 GiB 筛选、迭代 125--127 的 `SCHED_IDLE`
候选，以及迭代 128--142 的 SMP3 控制、配置诊断和组合/确认候选均已保留在 CSV 及原始日志中；
前者作为测量质量改进，后续性能候选
明确拒绝，不改变正式 no-poll
配置的性能结论。

这组结果适合证明：

1. GIC group 修复后 timer/scheduler 功能可用；
2. 三 guest 网络负载不会让 timer callback 完全丢失；
3. 提高到 10 kHz 并移除 virtio 轮询后，当前 QEMU 配置下正式三轮均无 >1 ms
   miss，最差为 515 us；这只是同一 QEMU 环境下的相对改进。

它不能单独证明硬实时保证。后续应在 KVM 或真实 ARM 平台重复，并记录宿主机
负载、CPU 隔离、QEMU 模式和中断入口时间戳。

## 后续优化计划

1. **先补齐可归因性**：在 benchmark 中分别记录 guest timer compare、IRQ
   入口、Zephyr callback 和网络完成时间；宿主侧同步采集 QEMU 线程 CPU、调度
   等待和 runqueue 事件。验收条件是能把每个长尾样本归到 guest、Axvisor、QEMU
   或宿主调度中的一个阶段，而不是只看 callback 最终时间。
2. **补齐虚拟化分层基线**：在同一 QEMU TCG 配置下依次测 Axvisor 单 RTOS、
   Axvisor 一 Linux+RTOS 网络、当前 Axvisor 两 Linux+RTOS 网络；每层使用同一
   raw-cycle benchmark 和至少三轮重复，才能把 guest 数量、网络设备和 Axvisor
   切换开销分开。裸机单 guest 结果已建立，但它不能解释网络设备和多 guest
   调度的全部差值。
3. **迁移到同板基线**：在同一 ARM 机器上分别测 Zephyr 裸机、Linux+Zephyr
   网络负载、Axvisor+两 Linux+RTOS。当前 x86_64 宿主上的 QEMU TCG 仅用于回归
   和相对比较，不能作为硬实时性能基线。
4. **再评估调度隔离**：在真实 ARM/KVM 环境中控制 CPU isolation、governor、
   IRQ affinity 和 QEMU vCPU affinity，每个配置至少重复 3 次；只有在 p99.9、
   最大延迟和 deadline miss 同时改善时才采纳。
5. **优先测量 passthrough timer 路径**：为 QEMU TCG 运行加入 QMP vCPU 线程映射、
   `/proc/<qemu>/task/<tid>/schedstat` 和 QEMU `cpu_exec` trace；与 Zephyr 的
   CNTVCT/CVAL/IRQ-entry 样本对齐后，先确认长尾发生在宿主 runqueue、QEMU 锁等待、
   Axvisor vCPU loop 还是 guest IRQ 交付，再选择单变量优化。该项已由迭代
   144--145 完成：runqueue 假设被证伪，长尾窗口定位到
   `S/futex_do_wait` 的 halted-vCPU 唤醒；迭代 146 的 busy-WFI 筛选将该比例降至
   `1.507761%`，但性能和单变量门禁未通过，候选仍拒绝。
6. **候选修复顺序**：若时间轴显示 vCPU task 长时间占用 pCPU，先在真实 ARM/KVM
   环境评估受控抢占/时间片；若显示 host comparator 覆盖，仅对非-passthrough
   AxVM timer 建立 `min(periodic, task, AxVM)` deadline broker；若显示 QEMU
   TCG/宿主 runqueue，则保持 Axvisor 代码不变，转为 CPU isolation、governor、
   IRQ affinity 和 KVM/真实板验收。每个候选仍需三轮完整两 Linux + RTOS 网络
   验证，且必须同时改善 p99.9、最大值和 miss 才能采纳。
7. **保持网络约束**：所有正式验收仍使用 Linux 与 RTOS 的 virtio-net/ICMP、
   TCP 流量，禁止用共享内存或 virtio socket 替代网络路径。

## 修复清单

- [x] Zephyr guest 声明 `CONFIG_ARMV8_A_NS=y`。
- [x] 网络 guest 使用 10 kHz system tick，降低 1 ms timer 的调度量化。
- [x] 关闭同步日志并将正式网络 guest 切换到 no-poll；诊断 fallback 保留有界睡眠，完成三轮对照。
- [x] 保存原始 cycle，输出 ns 级 phase/interval 统计，避免 `p99=0` 误读。
- [x] 验证 virtio SPI 中断可独立驱动网络，将 no-poll 设为正式构建默认。
- [x] 评估并拒绝 TCG multi/single 线程配置：最坏值分别达到 2339/9745 us。
- [x] 修复 AArch64 非 passthrough IRQ 退出路径的重复 host dispatch，并加入架构边界回归契约；该修复按正确性修复记录，不归因于 passthrough 延迟改善。
- [x] 评估 completion semaphore 降低 benchmark 主线程唤醒噪声；三轮无稳定改善，保留为未采纳的性能优化尝试。
- [x] 评估宿主绑核 + TCG multi；最坏值 4693 us、8 次 >1 ms，拒绝该配置。
- [x] 评估 guest-entry EL2 上下文缓存；三轮最大值 251/664/1697 us，拒绝并移除候选。
- [x] 三 guest 网络连通性验证通过。
- [x] 单 guest idle/低优先级负载测试完成。
- [x] 三 guest 网络实时性测试和优化迭代持续记录；CSV 已记录 iteration `0--154`，共 155 条数据行
  （含 0 基线、44 轮既有实验、6 条裸机 QEMU 对照、3 条分层对照、3 条低扰动
  测量候选、3 条 `ic iallu` 候选、3 条内联 external IRQ 候选、6 条单 RTOS 分层对照
  、1 条最终 FDT 功能 smoke、3 条 `sched-rr` 候选和 3 条 AArch64 IRQ fetch
  去重候选、3 条宿主 10 kHz tick 候选、1 条 FIFO one-shot 启动失败候选、3 条
  外部 deadline provider 候选、1 条 `tcg_multi` 第四轮补测（83）、3 条
  `tcg_tb512` 候选（84--86）、1 条 PPI trace 启动失败诊断和 3 条 pCPU 3
  placement 候选、1 条 tickless host timer 跨 CPU `Unsupported` 诊断（91）、
  3 条周期 host timer 控制（92--94）、3 条周期 host timer 修复后对照（95--97）、
  4 条 pinned vCPU 本地 tickless 候选（98--101）、3 条宿主 affinity + TCG multi
  tickless 候选（102--104）、3 条同配置 `host_vcpu_yield` 候选（105--107）、
  4 条默认 QEMU `host_vcpu_yield` 候选（108--111）、3 条 FIFO + host `preempt`
  候选、6 条 cooperative exit budget64 候选、3 条 QMP 精确 vCPU affinity 候选、
  1 条 QEMU RAM 2 GiB 筛选、3 条 `SCHED_IDLE` 候选、12 条 SMP3 控制/诊断/组合候选、
  3 条新鲜产物 SMP3 确认轮、3 条同步采集/归因记录、1 条 busy-WFI 筛选、1 条
  缺少 finalization 产物的无效筛选、3 条 timer-broker remediation 筛选和 4 条 QEMU
  timer/IRQ 边界诊断）。其中 iteration
  83--86、91--111 的分类计数为
  `1 + 3 + 1 + 3 + 3 + 4 + 3 + 3 + 4 = 25` 条；全部分类合计 155 条。
- [x] 评估 callback 低扰动统计路径；callback 最大执行时间降至约 `16--25 us`，
  但三轮 latency 未稳定改善，保留为测量质量改进而非实时性收益。
- [x] 评估移除 guest-entry `ic iallu`；三轮最大延迟 `8383/77/104 us`，拒绝并
  恢复原始 cache/TLB 维护序列。
- [x] 评估当前 pinned vCPU loop 内联外部 IRQ 重入；三轮最大延迟
  `53507/855/4558 us`、`>1 ms` miss `60/0/4`，拒绝并恢复 deferred 路径。
- [x] 评估 Axvisor 宿主 `sched-rr` 抢占调度；三轮最大延迟 `810/753/54 us`、
  `>1 ms` miss `0/0/0`，没有稳定优于 FIFO no-poll 基线，拒绝并恢复默认 FIFO。
- [x] 评估 AArch64 IRQ fetch 后去除重复 host dispatch；三轮最大延迟
  `437/1/484 us`、p99.99 为 `43.120/0/94.848 us`，没有稳定优于正式基线，
  拒绝并恢复 deferred dispatch 路径。
- [x] 评估宿主 ArceOS timer tick 从 1 kHz 提升到 10 kHz；三轮最大延迟
  `633/904/292 us`、p99.99 为 `319.904/12.880/111.728 us`，没有稳定优于正式
  基线，拒绝并恢复宿主 1 kHz 配置。
- [x] 评估 FIFO 下取消周期 host timer；候选在 guest 启动前停滞，CSV 迭代 79
  标记为 `failed_startup`，撤回并恢复原周期 timer 路径。
- [x] 评估 ArceOS/AxVM 外部 deadline provider 合并；三轮最大延迟
  `3770/224/18068 us`、`>1 ms` miss `11/0/21`，没有稳定优于正式基线，撤回并
  保留原始日志及 CSV 迭代 80--82。
- [x] 增加 p99.99、callback duration 和 tick-gap 测量；三轮新基线均完成 9999/9999 callback。
- [x] 修正 passthrough SPI 路由使用 vCPU placement，并通过架构契约和网络 smoke；该轮性能未改善。
- [x] 增加 Zephyr PPI 27 `CNTVCT/CVAL/CTL`、IRQ-entry 和 callback 边界诊断；pCPU 2 轮次
  定位到 compare overdue，而非 callback 执行时间。
- [x] 评估 RTOS vCPU 从 pCPU 2 迁移到 pCPU 3；三轮最大延迟 `401/669/1805 us`、
  `>1 ms` miss `0/0/2`，没有稳定改善，拒绝并恢复正式 pCPU 2 配置。
- [x] 修复三 guest setup 的动态 BusyBox initramfs 问题；自动回退到下载 guest initramfs
  中的静态 BusyBox，并增加静态 ELF 校验。
- [x] 修复 tickless host timer 策略从 VMM 启动线程跨 CPU 调用返回 `Unsupported` 的问题，
  改为由 pinned vCPU task 在目标 pCPU 本地应用/恢复策略；修复后四轮候选最大延迟
  `380/1811/660/421 us`，没有稳定优于公平周期控制 `312/633/1190 us`，故不设为默认。
- [x] 评估 `taskset -c 4-11` + TCG multi 的宿主 affinity 候选；最大延迟
  `212/397/3049 us`，`>1 ms` 为 `0/0/4`，拒绝。
- [x] 评估可选 `host_vcpu_yield` 的 vCPU slice yield 候选；最大延迟 `0/648/2370 us`，
  `>1 ms` 为 `0/0/3`，拒绝默认化，默认配置保持 `false`。
- [x] 在默认 QEMU TCG 下重新评估 `host_vcpu_yield`；四轮最大延迟
  `555/243/137/0 us`，`>1 ms` 为 `0/0/0/0`，作为历史候选记录；后续 SMP3
  新鲜产物确认已拒绝稳定收益。
- [x] 评估 FIFO + host `preempt` 候选；三轮最大延迟 `5674/1294/576 us`、p99.9
  为 `1418/0/0 us`、`>1 ms` 为 `13/1/0`，没有改善并引入明显长尾，拒绝且正式
  默认仍为 FIFO。
- [x] 评估 cooperative exit budget 64；审计确认六轮实际均为 budget64，最大延迟
  `338/16307/16320/59544/646/1823 us`，放大长尾，拒绝并撤回热路径代码；未测量
  budget1024。
- [x] 评估 QMP 精确 vCPU affinity；映射确认 QEMU CPU 2 固定到 host CPU 6，三轮
  最大延迟 `8762/1307/2255 us`、`>1 ms` 为 `14/2/2`，拒绝。
- [x] 筛选 QEMU RAM 2 GiB；首轮最大延迟 `3332 us`、`>1 ms` 为 3，拒绝并保持
  正式 8 GiB 配置。
- [x] 评估 Linux QEMU vCPU `SCHED_IDLE`；三轮最大延迟 `1768/610/2005 us`、
  `>1 ms` 为 `1/0/2`，拒绝。
- [x] 修复性能实验的 raw binary 新鲜度证据：启动时打印解析后的 VM host policy，
  affinity runner 拒绝比 ELF 更旧的默认 `.bin`；旧 `61 us` 轮标记为无效。
- [x] 完成 QEMU/Axvisor SMP3 + tickless + yield 历史三轮；最大延迟 `0/0/378 us`，无
  `>500 us`/`>1 ms` miss，只保留为历史最佳样本，未达到裸机参考。
- [x] 关闭 IRQ trace 的同组合三轮为 `710/353/18 us`；callback 开销下降但端到端
  尾延迟未稳定改善，拒绝作为性能收益。
- [x] 用 manifest 绑定的新鲜 SMP3 ELF/raw/TOML 重测 tickless + yield；三轮最大延迟
  `569/4996/2678 us`、`>1 ms` miss `0/5/2`，拒绝其稳定收益结论。raw SHA-256 为
  `2010ab4788aae2d344c1b2d08a23869ceb869127f4953a8649ff47e752156573`。
- [x] 筛选 RTOS busy-WFI；功能和因果门禁通过，`S/futex_do_wait` 降至
  `1.507761%`，但 p99.99/miss 未相对同步对照同时改善，且存在 QEMU/TOML hash
  漂移，iteration 146 明确拒绝该候选；后续 correctness remediation 使用重新冻结
  且 identity 完整的 artifact 独立筛选。
- [x] 完成 timer broker、host RAM reservation 和 current-config consumption 的
  correctness 验证及 safety smoke；iteration 147 因缺少 finalization 产物记为无效失败轮，
  iteration 148 完成单次 TCG screen pass，但不提升为稳定性能或物理验收结论。
- [x] 用同一冻结 artifact 完成 iteration 149--150，否定 iteration 148 的稳定性能收益；
  再以 iteration 151--154 将长尾收敛到 QEMU virtual timer assert 之后、outer IRQ take 之前。
- [ ] 在 KVM/真实硬件上重复实验，建立可用于实时性承诺的测量基线；当前 QEMU
  AArch64 只支持 TCG，x86_64 主机的 `/dev/kvm` 不能提供 AArch64 KVM。

## 验证状态

- Zephyr final build：通过，入口 `0xa0001114`，`CONFIG_ARMV8_A_NS=y`，
  `CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000`，编译命令包含
  `-DAXVISOR_DISABLE_VIRTIO_IRQ_POLL`，且无 `vdev` 未使用变量警告。
- instrumented Zephyr build：通过；最终 ELF 包含 `__wrap_arm_gic_get_active`，最终链接
  命令包含 `-Wl,--wrap=arm_gic_get_active`，诊断默认关闭。
- PPI trace pCPU 2/3 三 guest 运行：pCPU 2 诊断轮次保留为 `failed_initramfs`；pCPU 3
  三轮均完成两条 ICMP、TCP/8080 和 `9999/9999` callback，原始日志为
  `/tmp/axvisor-rtbench-irqtrace-pcpu3-r1.log` 至 `r3.log`。
- Linux initramfs：两个生成 cpio 均包含静态 BusyBox；动态 BusyBox 回退逻辑和静态
  ELF 校验已通过 setup 脚本实际运行。
- 本轮新鲜验证：axvmconfig `20 passed`；AxVM arch boundary `24 passed`；AxVM 配置
  宿主单测 `4 passed`；RTOS 精度、三 guest 静态配置、绘图和 QMP affinity runner
  契约均通过，AxVM 7 组 feature Clippy 全部通过。
- 独立审查后的证据修正：QMP stub 实际走完 SMP3 thread-count/index/affinity 成功路径；
  CSV 新增独立 `candidate_decision`；绘图增加 4 个数据/单位/PNG 行为测试；RT trace
  摘要使用 `*_ticks` 并显式标记 AArch64 `cycles` 或其他架构 `ns`。
- axbuild 全套库测试实际为 `826 passed, 1 failed`；唯一失败是 StarryOS 测试拉取外部
  镜像 registry 超时，未进入本轮代码逻辑，不能作为本轮性能候选失败依据。
- ax-runtime host-test：`5 passed`，新增 nested periodic-timer disable-depth
  语义测试；AArch64 release Axvisor 重新构建成功。
- AArch64 release Axvisor 使用 `qemu-aarch64.toml`、SMP3 和三份确认轮 TOML 重新构建
  成功；未启用 `preempt`，Linux VM 为 periodic/false，RTOS VM 为 tickless/true，
  启动日志逐项确认。
- timer-broker remediation host matrix：`cargo fmt --check` 通过；axvmconfig 25、
  arm_vcpu 6、axvm host-test 197、ax-runtime host-test 7、ax-task 26，Rust 合计
  `261 passed, 0 failed`；precision source、affinity executable artifact、validator
  syntax contract 通过；plot tests 11、report tests 10。
- clean archive、board、ELF/raw、setup/build manifest、三份 VM TOML 和 runner
  sidecar identity 已核对；iteration 148 的 QMP、metadata、schedstat summary 和
  annotated samples 完整，iteration 147 缺少 finalization 产物并按 invalid 记录。
- RTOS 精度、绘图、三 guest 静态验证和 CSV schema 检查：通过；CSV 共 155 条数据行，
  37 列；从迭代 140 起，`network_validation` 只记录网络结果，新列
  `candidate_decision` 独立记录候选处置；历史行保留原有混合状态值并将新列留空。
  延迟扩展列包括 `p99_99_ns`、`callback_duration_max_ns`、`tick_gap_min/max`。
- 裸机 QEMU build：通过；新 ELF entry 为 `0x41001044`，LOAD 段为连续的
  `0x41000000..0x410e2000`，DTS overlay 无节点地址警告；三轮日志均完成
  idle 和低优先级负载的 9999/9999 callback。
- raw-cycle deadline threshold 回归检查：通过；no-poll 诊断和正式构建三轮日志已
  追加为 CSV 迭代 25--30。
- IRQ 单次分发、semaphore 和宿主绑核对照日志已追加为 CSV 迭代 31--35；其中
  31 轮为 `pass_after_retry`，35 轮为 `rejected` 控制实验。
- 新测量边界三轮及 8 CPU TCG multi 对照已追加为 CSV 迭代 36--39；36、38 轮
  为 `pass_after_retry`，39 轮为 `rejected` 控制实验。
- placement 修复 smoke 已追加为 CSV 迭代 40，网络标记为 `pass_after_retry`；其
  `5954 us` 长尾不作为性能改进证据。
- `sched-rr` 候选已完成构建日志、三轮完整网络测试和调度器启动确认；数据已追加
  为 CSV 迭代 70--72，候选拒绝后正式代码恢复 FIFO。
- AArch64 IRQ fetch 去重候选已完成 AxVM 架构边界回归、三轮完整网络测试；数据已
  追加为 CSV 迭代 73--75，候选拒绝后正式代码恢复 deferred host IRQ dispatch。
- guest-entry 缓存候选三轮已追加为 CSV 迭代 41--43；网络和 callback 均通过，
  但相对 no-poll 基线没有改善，并出现一次 `>1 ms` miss，因此候选已移除。
- 候选撤回后的最终功能 smoke 已追加为 CSV 迭代 44；网络和 callback 通过，
  但历史镜像缺少新增测量字段，且单轮长尾为 `4226 us`，仅作功能记录。
- 裸机 QEMU runner、RAM overlay 和统一 raw-cycle benchmark 已加入；三轮
  idle/低优先级负载结果追加为 CSV 迭代 45--50。
- 裸机参考源契约、10 kHz Zephyr build、ELF load segment 和三轮 QEMU 运行
  已验证；该结果只作为同主机 QEMU 归因对照。
- 一个 Linux + 一个 Zephyr 的三轮分层对照已追加为 CSV 迭代 51--53；三轮
  callback 完成、ICMP 通过，网络字段明确标为 `pass_partial_network`。
- 单 RTOS 无网络配置的两种 guest 镜像均在 banner 前复现未配置 MMIO fault，
  已保留原始日志但未纳入性能结论。
- callback 低扰动候选的 Zephyr build、三轮 raw logs 和网络修正记录已完成；第 54
  轮明确标为 `failed_initramfs`，第 55--56 轮网络通过但候选不采纳。
- guest-entry `ic iallu` 候选已完成红绿契约、AxVM/arm_vgic 回归和三轮正式网络
  测试；候选已撤回，最终代码保留 `ic iallu`、`tlbi alle2`、`tlbi alle1`。
- 内联 external IRQ 候选已完成失败契约、AxVM/arm_vgic 回归和三轮正式网络测试；
  候选已撤回，最终代码保留 deferred external IRQ 路径，数据为 CSV 迭代 60--62。
- 单 RTOS FDT/DTB 修复已完成 FDT 单测、端到端 Zephyr 启动和三轮 idle/低优先级
  benchmark；六条记录均完成 `9999/9999` callback，数据为 CSV 迭代 63--68。
- FDT 修复后的最终三 guest 功能 smoke 已完成两条 ICMP、TCP/8080 重试和
  `9999/9999` callback，记录为 `pass_after_retry` 的 CSV 迭代 69；其单轮长尾
  不作为新的性能基线。
- arm_vcpu 其余测试（跳过 `run_all_tests_does_not_exit_after_first_status_count`）：
  通过。该单测依赖工作区未提供的
  `virtualization/arm_vcpu/scripts/.axci/lib/test_flow.sh`，直接运行时失败在
  脚本加载阶段，未进入本次代码逻辑。
