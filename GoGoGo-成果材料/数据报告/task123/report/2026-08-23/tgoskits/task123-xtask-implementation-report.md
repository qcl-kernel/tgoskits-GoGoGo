# Task123 cargo xtask 实现与验证报告

## 1. 报告范围

本报告记录 `tgoskits` 的 `Task123 cargo xtask` 阶段，包括：

- 将 Task 1、Task 2、Task 3 的集成运行入口接入 `cargo xtask axvisor task123`；
- 保留并复用现有 QEMU、客户机生命周期、网络、AI、RTBench 和结果门禁实现；
- 修复持久缓存、RT-Thread 镜像元数据、QEMU PMU/计数器和日志解析问题；
- 在真实 `qemu-system-aarch64` 上完成 Linux/StarryOS 两种客户机运行；
- 保存相对 `origin/dev` 的完整 tracked diff。

报告日期：2026-08-23

## 2. 代码状态与变更范围

代码 worktree：

```text
/home/yfblock/Code/hyper-rtos/.worktrees/tgoskits-task123-xtask
```

| 项目 | 值 |
|---|---|
| 分支 | `codex/task123-xtask` |
| 基线 | `origin/dev` (`5c4513335`) |
| 当前 HEAD | `da8377c14` |
| 基线之后的提交 | 2 个 |
| tracked 变更文件 | 27 个 |
| tracked 新增行 | 978 |
| tracked 删除行 | 113 |
| tracked 总变更 | 1091 行 |
| 当前未跟踪 Task 3 文档 | 46 个，246948 字节 |

两个已提交变更为：

```text
112b6bb77 refactor(task123): route direct entry through xtask
da8377c14 fix(task123): enable virtual PMU for RTBench runs
```

当前 worktree 中还有本轮未提交的 runner、测试、RTBench、RT-Thread patch 和 Task 3
文档变更。本报告不执行提交，也不清理用户已有的缓存和 worktree 内容。

完整 tracked patch：

[task123-xtask-origin-dev.diff](../../../evidence/2026-08-23/tgoskits/task123-xtask-origin-dev.diff)

该 diff 是以下命令生成的：

```bash
git diff --binary origin/dev
```

| Diff 属性 | 值 |
|---|---|
| 文件 | `task123-xtask-origin-dev.diff` |
| 行数 | 1585 |
| 字节数 | 65757 |
| SHA-256 | `3f37bf642dee626927cd166476c1de22cc6b167be31f262d58bdcaffd409f513` |

说明：diff 覆盖相对 `origin/dev` 的已跟踪文件，包括两个 commit 和当前未提交修改；
`os/axvisor/guests/task3/docs/` 下的 46 个未跟踪证据文件不属于该 tracked diff，
但已在本报告第 8 节列出。

## 3. 总体实现方案

最终调用链为：

```text
cargo xtask axvisor task123
        |
        +-- Rust Task123 planner
        |     |- 选择 RT-Thread 镜像和 metadata
        |     |- 校验补丁集合 SHA-256
        |     |- 转发 quick/full、output、cache 参数
        |     `- 以前台进程继承终端输出启动 runner
        |
        `-- os/axvisor/scripts/run_task123_guest_comparison.sh
              |- 依次运行 Linux 和 StarryOS 客户机
              |- 调用 run_task123.sh 完成 QEMU 生命周期
              |- 采集 Task 1/2/3 证据
              |- 执行结果门禁
              `- 生成 comparison.json 和 comparison-report.md
```

设计原则是只在 Rust xtask 中增加入口和输入选择策略，客户机启动、QEMU 生命周期、
日志采集、结果门禁和对比分析仍由已有 runner 负责。这样可以保持原有测试行为，且
`run-task123.sh` 继续作为兼容入口。

## 4. cargo xtask 入口改动

### 4.1 AxVisor 子命令注册

文件：

- `scripts/axbuild/src/axvisor/mod.rs`
- `os/axvisor/xtask/src/main.rs`

具体改动：

1. 新增 `pub mod task123`。
2. 在 AxVisor 子命令中增加 `Task123(task123::Task123Args)`。
3. 在命令分发中调用 `task123::run`。
4. 在路径规范化逻辑中识别 Task123 命令，保证相对路径处理一致。
5. 增加 clap 命令解析单测，验证 `--quick`、`--output` 和 `--cache`。

### 4.2 Rust Task123 planner

文件：

`scripts/axbuild/src/axvisor/task123.rs`

新增功能：

- 支持 `--quick` 和 `--full`，二者互斥；默认转发 quick 模式；
- 支持 `--output DIR`；当父目录不存在时由 xtask 创建；
- 支持 `--cache DIR`；
- 支持 `--allow-qemu-timer-limit`；
- 优先读取 `RTTHREAD_IMAGE` 和 `RTTHREAD_IMAGE_META`；
- 未指定镜像时查找持久镜像：

  ```text
  tmp/source-cache/task123-rtthread-current/rtthread.bin
  ```

- 只有镜像文件和 metadata 同时存在、metadata schema 为 1 且补丁集合摘要匹配时，
  才复用持久镜像；否则交给 runner 构建；
- 通过 `Command::status()` 继承 runner 的标准输入、标准输出和标准错误，保证 QEMU
  和客户机过程的实时输出可直接显示；
- 传递 `RTTHREAD_REQUIRE_IMAGE_METADATA=1`，避免使用未认证的 RT-Thread 镜像；
- 将 runner 非零退出码转换为 xtask 错误。

补丁摘要覆盖以下 10 个 RT-Thread patch：

```text
0000-axvisor-aarch64-port.patch
0009-native-qemu-memory-layout.patch
0002-lwip-rx-mailbox-recover-notice.patch
0003-virtio-net-reclaim-tx-used-ring.patch
0004-virtio-net-use-rx-used-ring-head.patch
0005-lwip-configurable-udp-recv-mailbox.patch
0006-gicv3-use-redistributor-pending-registers.patch
0007-gicv3-query-interrupt-enable-state.patch
0008-aarch64-gtimer-use-absolute-deadlines.patch
0010-virtio-net-benchmark-packet-hook.patch
```

新增 Rust 单测覆盖：CLI 参数、默认模式、路径转发、显式镜像、持久镜像、缺失 metadata、
过期补丁集合、metadata schema 和 patch digest。

### 4.3 根目录兼容脚本

文件：

`run-task123.sh`

旧脚本中重复的 RT-Thread 镜像选择和环境拼接逻辑被移除，改为精简兼容层：

```text
run-task123.sh
  -> cargo xtask axvisor task123
  -> run_task123_guest_comparison.sh
```

无参数时默认执行：

```text
cargo xtask axvisor task123 --quick --allow-qemu-timer-limit
```

显式的 `--full`、`--output`、`--cache` 等参数原样传递。脚本使用 `exec`，因此 Ctrl+C
和终端信号能到达前台 cargo/QEMU 进程组。

## 5. QEMU、缓存与运行期改动

### 5.1 QEMU PMU 和计数器策略

文件：

- `os/axvisor/scripts/run_task123.sh`
- `os/axvisor/scripts/test_qemu_realtime_controls.sh`
- `os/axvisor/scripts/test_task123_runner_lifecycle.sh`

改动内容：

- 默认使用 QEMU wall clock 和多线程 TCG，避免固定 `-icount` 串行化网络压力测试；
- QEMU CPU 改为 `cortex-a72,pmu=on`，让 guest RTBench 能读取虚拟 PMU/architectural counter；
- `QEMU_ICOUNT` 变为显式可选项；若设置，校验为 `shift=0..10` 并切换到单线程 TCG；
- manifest 新增 `qemu_cpu`、`qemu_icount`、`qemu_pmu` 等字段；
- NVMe `max_ioqpairs` 从 64 调整为 4，降低无必要的 QEMU 设备开销；
- 测试覆盖默认不带 `-icount` 和显式 `QEMU_ICOUNT=shift=0` 两条路径。

### 5.2 持久 artifact cache

文件：

- `os/axvisor/scripts/run_task123.sh`
- `os/axvisor/scripts/run_task123_guest_comparison.sh`
- `os/axvisor/guests/task3/scripts/build_alpine_linux.sh`
- `os/axvisor/guests/task3/tests/test_build_contracts.sh`

持久缓存路径：

```text
tmp/source-cache/
  task123-rootfs-current/rootfs.img
  task123-rtthread-current/rtthread.bin
  task123-rtthread-current/rtthread.bin.meta.json
  rt-thread/<commit>/source/
  task3-alpine-linux/<version>/
  task3-model/
  arm-gnu-toolchain/<version>/
```

行为变化：

- Linux rootfs 首次准备后发布到 `task123-rootfs-current`，后续运行直接复用；
- RT-Thread 构建完成后以临时文件、metadata 校验、原子 rename 的顺序发布；
- RT-Thread 原始源代码按固定 commit 缓存，构建时复制到 runtime source tree，再应用
  patch，不污染原始 source cache；
- Alpine Linux、模型和 ARM 工具链使用同一持久 cache；
- 构建契约测试改为验证 source-cache 的 origin、commit、detached HEAD 和损坏归档行为；
- `build_alpine_linux.sh` 增加模型缓存准备，避免每次重复生成模型资源。

### 5.3 对比和超时策略

文件：

- `os/axvisor/scripts/run_task123_guest_comparison.sh`
- `os/axvisor/scripts/compare_task123_guests.py`
- `os/axvisor/scripts/test_task123_guest_comparison.sh`
- `os/axvisor/scripts/test_compare_task123_guests.sh`

改动内容：

- comparison 统一使用一份 RT-Thread 镜像；Task 3 fault profile 改为运行期配置，不再
  要求 `rtthread-normal`、`rtthread-drop-status`、`rtthread-delayed-server` 三份镜像；
- quick 模式仍为 300 秒稳定性、每种 payload 30000 次请求，但 runner 超时预算提高到
  `stability_seconds + 1800`，覆盖 StarryOS 较慢的用户态网络路径；
- full 模式超时预算为 `stability_seconds + 3600`；
- 对比分析器和测试 fixture 同步新的单 RT-Thread artifact manifest。

## 6. RTBench 和 RT-Thread 代码改动

### 6.1 RTBench 稳定性校准信息

文件：

`os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c`

`rtbench_stability` 现在输出：

- `frequency`：architectural counter 频率；
- `tick_hz`：RT-Thread tick 频率；
- `start_tick`、`start_counter`；
- `end_tick`、`end_counter`；
- `counter_elapsed_ns`。

这使报告可以区分 guest 计时器样本、RT-Thread tick 经过时间和 architectural counter
经过时间，验证周期漂移和 QEMU TCG 长尾，而不是只依赖单一 wall-clock 结果。稳定性
测试保留完整样本收集，不在达到样本数后提前停止 timer，以便观察完整窗口行为。

### 6.2 RT-Thread virtio-net 和补丁一致性

文件：

- `os/axvisor/patches/rtthread/0000-axvisor-aarch64-port.patch`
- `os/axvisor/patches/rtthread/apply-rtthread-patches.sh`
- `os/axvisor/patches/rtthread/test-rtthread-patches.sh`

具体改动：

- virtio-mmio vendor ID 修正为 QEMU 的 `0x554d4551`；
- patch digest 改为在 patch 目录内用相对文件名计算，避免绝对路径进入 digest；
- patch invariant 增加 `RTBENCH_STABILITY_CLOCK` 输出检查；
- 保持 RX used-ring、TX buffer、GICv3 redistributor、absolute timer 和 UDP mailbox 等
  既有修复不被重复应用或 stale source 覆盖。

正式 fresh patch-set 测试验证了：

1. 从 commit cache 复制新源代码；
2. 首次应用完整 patch set；
3. 再次应用 patch set，确认幂等；
4. 运行 patch invariant；
5. 使用 `uv` + SCons 完整编译 RT-Thread；
6. 检查 `rtbench_stability`、`rtipc_server_start`、`task3_server_start` 等符号。

## 7. 结果门禁和日志解析改动

文件：

- `os/axvisor/scripts/verify_task123_results.sh`
- `os/axvisor/scripts/verify_rtbench_stability.sh`
- `os/axvisor/scripts/test_task123_result_gate.sh`
- `os/axvisor/scripts/test_rtbench_stability_gate.sh`
- `os/axvisor/scripts/test_task123_runner_lifecycle.sh`

### 7.1 稳定性 marker

稳定性开始 marker 允许 RT-Thread 附加经过认证的 `key=value` 校准字段，同时严格保留
`seconds` 和 `expected` 的检查，避免因为新增计时字段误判失败。

### 7.2 串口交错和 shell prompt

结果解析器增加了针对真实日志形态的有限归一化：

- 删除交错 AxVisor 输出造成的重复 `[VM 1]` 前缀；
- 去除 RT-Thread shell prompt 粘连；
- 修复 `tick_hz` 字段被 prompt 分割的情况；
- 合并 `p99_9_ns` 字段被换行切断的情况。

归一化只作用于已知 marker 和字段，不放宽 payload、序号、成功率、样本数等核心门禁。

## 8. 测试代码和测试结果

### 8.1 新增或强化的测试路径

- `os/axvisor/scripts/test_run_task123_entrypoint.sh`：验证根入口委托给 cargo xtask、
  参数转发和前台执行语义；
- `os/axvisor/scripts/test_qemu_realtime_controls.sh`：验证 PMU、wall clock、icount 和
  TCG thread 选择；
- `os/axvisor/scripts/test_rtbench_stability_gate.sh`：验证带校准字段的 marker；
- `os/axvisor/scripts/test_task123_result_gate.sh`：验证重复 VM 前缀、shell prompt、
  ANSI、缺失样本和失败 marker；
- `os/axvisor/scripts/test_task123_runner_lifecycle.sh`：验证 QEMU 生命周期、reap、
  cache、rootfs、显式 icount 和异常退出；
- `os/axvisor/scripts/test_task123_guest_comparison.sh` 和
  `test_compare_task123_guests.sh`：验证 Linux/StarryOS 两端运行和 comparison 产物；
- `os/axvisor/guests/task3/tests/test_build_contracts.sh`：验证持久 source cache 和归档
  校验；
- `os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh`：验证 RT-Thread 补丁幂等
  应用和真实编译；
- `os/axvisor/guests/task3/tests/`：C、Python、模型、协议、会话、指标、deadline、
  Linux CLI、RT-Thread server 和 fault 测试。

### 8.2 已执行结果

| 测试 | 结果 |
|---|---|
| `cargo test -p axbuild task123 --lib` | 14 passed, 0 failed |
| `cargo fmt --all -- --check` | PASS |
| `git diff --check` | PASS |
| `test_build_contracts.sh` | PASS |
| Task 3 C/Python 全套 `make -C os/axvisor/guests/task3/tests test` | PASS |
| RTBench stability gate | PASS |
| QEMU realtime controls | PASS |
| Task123 result gate | PASS |
| Linux/StarryOS comparison analyzer | PASS |
| RT-Thread guest memory/image metadata contract | PASS |
| fresh RT-Thread patch-set apply/build/invariant | PASS |

## 9. 真实 QEMU Task 1/2/3 结果

运行命令：

```bash
cargo xtask axvisor task123 \
  --quick \
  --allow-qemu-timer-limit \
  --cache "$PWD/tmp/task123-cargo-xtask-final-cache-20260823T080133Z" \
  --output "$PWD/tmp/task123-cargo-xtask-final-output/20260823T080133Z"
```

QEMU：`/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64`，版本 11.0.2，AArch64
`virt`、Cortex-A72、TCG、PMU enabled。

结果目录：

```text
tmp/task123-cargo-xtask-final-output/20260823T080133Z/
  linux/
  starryos/
  comparison/
```

### Task 1

Linux 和 StarryOS 均完成：

```text
RTBENCH_STABILITY_BEGIN seconds=300 expected=299999
RTBENCH_STABILITY_END status=PASS expected=299999 collected=299999 missing=0
```

StarryOS 侧主要结果：

| 指标 | 结果 |
|---|---:|
| stability jitter P50 | 8944 ns |
| stability jitter P95 | 316640 ns |
| stability jitter P99 | 407792 ns |
| stability jitter P99.9 | 481072 ns |
| stability jitter max | 969184 ns |
| `miss_1ms` | 0 |
| callback exec P99 | 2368 ns |
| callback exec max | 172576 ns |

### Task 2

64B、256B、1024B 三种 payload 均完成 `30000/30000`。请求超时、协议错误、传输重传、
重复和乱序均为 0；64B fault profile 中的主动断连恢复成功。

StarryOS 侧平均 RTT 分别为 6 ms、6 ms、6 ms，P99.9 均为 45 ms。该结果用于 QEMU TCG
下的工程对比，不等价于物理 ARM 平台的网络上限。

### Task 3

Linux 和 StarryOS 均输出：

```text
requests=6 successes=6 success_rate=1.000000
classification accuracy=1.000000
TASK3_*_END status=PASS
```

StarryOS 侧 AI 推理平均 606 us，端到端 round trip 平均 6105 us，RTOS 处理平均 139 us。

对比结果文件：

- `linux/summary.json`
- `starryos/summary.json`
- `comparison/comparison.json`
- `comparison/comparison-report.md`

两侧 result gate 均为 `PASS_WITH_QEMU_TIMER_LIMIT`。这表示样本完整且功能门禁通过，同时
明确保留 QEMU TCG timer 长尾限制；不能将该状态解释为硬实时保证。

## 10. 未跟踪的 Task 3 证据文档

当前 worktree 另有以下目录尚未加入 git：

```text
os/axvisor/guests/task3/docs/
```

共 46 个文件、246948 字节，内容包括：

- `protocol.md`：Task 3 协议说明；
- `results/task3-report.md`：Task 3 报告；
- `results/evidence/normal/`：正常运行证据；
- `results/evidence/faults/`：delayed-server、drop-control、drop-status、duplicate-frame、
  malformed 等故障注入证据；
- `commands.txt`、`versions.txt`、`frames.csv`、`summary.json`、`linux.log` 和
  `rtthread.log` 等复现材料。

这些文件没有被写入本报告所引用的 tracked diff，以免把当前未跟踪证据误认为已纳入
`origin/dev` 的代码补丁。

## 11. 复现入口

默认兼容入口：

```bash
./run-task123.sh
```

canonical xtask 入口：

```bash
cargo xtask axvisor task123 --quick --allow-qemu-timer-limit
```

正式长测入口：

```bash
cargo xtask axvisor task123 --full --allow-qemu-timer-limit
```

默认 quick 模式已在真实 QEMU 上完成；full 模式保留为一小时稳定性和 240000 请求/每种
payload 的正式压力测试入口，本轮没有重复执行一小时测试。

## 12. 当前边界和后续注意事项

1. `PASS_WITH_QEMU_TIMER_LIMIT` 是 QEMU TCG 仿真环境下的有条件通过，不是硬实时 WCET。
2. Linux/StarryOS comparison 是串行两轮运行，宿主负载和 TCG 翻译缓存会影响相对值。
3. RT-Thread 原始 source cache 与运行时 patched source tree 分离，不能直接对 pristine
   source cache 运行需要 patch invariant 的检查脚本；应使用
   `test_fresh_rtthread_patchset.sh` 或显式传入已 patch 的 source tree。
4. 本报告和 diff 文件位于 hyper-rtos 的 `history-docs` archive，不改变 tgoskits 当前
   worktree 的提交状态。
