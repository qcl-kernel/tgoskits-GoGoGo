# Task123 当前结果复现指南

本文是成果材料的统一复现入口，覆盖 Task 1 实时性、Task 2 客户机通信和 Task 3 AI
控制闭环。当前结果矩阵包含 2 种 RTOS、2 种应用客户机和 2 种运行平台：

| 平台 | RTOS | 应用客户机 |
|---|---|---|
| QEMU AArch64 TCG | RT-Thread | Linux / StarryOS |
| QEMU AArch64 TCG | Zephyr | Linux / StarryOS |
| ROCK 4D 真机 | RT-Thread | Linux / StarryOS |
| ROCK 4D 真机 | Zephyr | Linux / StarryOS |

QEMU 和 ROCK 4D 的最终数据、日志和图表见 [`图标数据/`](图标数据/)；八个组合的验收
汇总见[最终验证报告](数据报告/task123/report/2026-08-25/tgoskits/task123-final-qemu-rock4d-report.md)。

## 1. 前置条件

所有命令从仓库根目录执行。需要：

- Rust pinned nightly toolchain、`cargo xtask` 和仓库依赖；
- QEMU 复现需要 `qemu-system-aarch64`、AArch64 编译工具链，以及网络/模型构建依赖；
- ROCK 4D 复现需要可用的 `ostool-server`、串口、电源/复位控制和板卡 Linux 根文件系统；
- 真机必须准备个人配置 `os/StarryOS/configs/board/rock-4d-uboot-local.toml`。该文件
  只包含本机串口和电源控制信息，不提交到成果材料。

先确认 QEMU 和 xtask 可用：

```bash
qemu-system-aarch64 --version
cargo xtask --help
```

## 2. QEMU 四组合

### 2.1 一次运行完整矩阵

`--output` 必须为空目录；`--cache` 可让四个组合共享构建产物。下面的参数与最终
成果数据一致：10 个 Task 2 请求和每个 RTBench 指标 10 个样本。

```bash
rm -rf tmp/task123-qemu-final
cargo xtask axvisor task123 \
  --realtime-suite \
  --matrix all \
  --rtbench-samples 10 \
  --task2-count 10 \
  --cache tmp/task123-artifact-cache \
  --output tmp/task123-qemu-final
```

矩阵完成后检查：

```bash
cat tmp/task123-qemu-final/matrix-report.md
cat tmp/task123-qemu-final/matrix-summary.json
```

### 2.2 分别运行四个组合

需要单独留存某个组合日志时，使用下列命令。每个 `--output` 目录都必须是新的空目录。

```bash
# QEMU + RT-Thread + Linux
cargo xtask axvisor task123 --realtime-suite \
  --rtos rtthread --app-guest linux \
  --rtbench-samples 10 --task2-count 10 \
  --output tmp/task123-qemu-rtthread-linux

# QEMU + RT-Thread + StarryOS
cargo xtask axvisor task123 --realtime-suite \
  --rtos rtthread --app-guest starryos \
  --rtbench-samples 10 --task2-count 10 \
  --output tmp/task123-qemu-rtthread-starryos

# QEMU + Zephyr + Linux
cargo xtask axvisor task123 --realtime-suite \
  --rtos zephyr --app-guest linux \
  --rtbench-samples 10 --task2-count 10 \
  --output tmp/task123-qemu-zephyr-linux

# QEMU + Zephyr + StarryOS
cargo xtask axvisor task123 --realtime-suite \
  --rtos zephyr --app-guest starryos \
  --rtbench-samples 10 --task2-count 10 \
  --output tmp/task123-qemu-zephyr-starryos
```

每个组合目录包含 `summary.json`、guest 日志、RTBench 日志、`frames.csv`、
`manifest.txt` 和 QEMU `host-metrics.txt`。QEMU 的 TCG timer 长尾需要结合报告中的
限制解释，不能将 QEMU 数值直接当作真机硬实时 WCET。

## 3. ROCK 4D 真机四组合

先按板卡说明准备 DTB、Linux/StarryOS guest 资产、网络和 U-Boot。确认本机配置中的
串口设备存在，并检查板卡服务：

```bash
test -e /dev/ttyUSB0
cargo xtask board ls
```

如果串口不是 `/dev/ttyUSB0`，在本机 `rock-4d-uboot-local.toml` 中填写实际路径；不要
修改下面命令中的仓库配置路径。四条命令分别对应四种组合：

```bash
# ROCK 4D + RT-Thread + Linux
cargo xtask axvisor task123 uboot --rtos rtthread --app-guest linux \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-linuxleg.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# ROCK 4D + RT-Thread + StarryOS
cargo xtask axvisor task123 uboot --rtos rtthread --app-guest starryos \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-twoguest.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# ROCK 4D + Zephyr + Linux
cargo xtask axvisor task123 uboot --rtos zephyr --app-guest linux \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-zephyr-linux.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# ROCK 4D + Zephyr + StarryOS
cargo xtask axvisor task123 uboot --rtos zephyr --app-guest starryos \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-zephyr-starryos.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml
```

U-Boot 运行期间保存完整串口输出；不要用旧内核、旧 DTB 或旧 RTOS 镜像继续测试。
每条命令都必须同时满足：

1. 对应客户机输出 `TASK123_*_END status=PASS`；
2. 16 项纳秒 RTBench 指标均为 `expected=10 collected=10 missing=0`；
3. Task 2、Task 3 和 Task123 结果门禁均为 `PASS`。

真机没有 QEMU 进程采样器，因此 host CPU/RSS 图中的 ROCK 4D host 字段显示 `NA` 是
预期行为；这不表示真机 RTBench 指标缺失。

## 4. 重新生成图表

使用已保存的 QEMU 和 ROCK 4D 日志重建 CSV、JSON 和 SVG：

```bash
python3 GoGoGo-成果材料/图标数据/plot_task123.py
```

脚本只将完整的纳秒记录纳入 RTBench 图表，不用 `16`、`0` 或其它值填充缺失数据；图中
出现 `16` 时，含义是实际测得的 16 ns。生成结果位于：

```text
GoGoGo-成果材料/图标数据/parsed-data.json
GoGoGo-成果材料/图标数据/*-metrics.csv
GoGoGo-成果材料/图标数据/plots/*.svg
```

## 5. 结果判定与证据

最终八组合的 timer jitter p99 轮次最大值和完整性见[最终验证报告](数据报告/task123/report/2026-08-25/tgoskits/task123-final-qemu-rock4d-report.md)。
原始证据按平台存放在：

- `GoGoGo-成果材料/图标数据/qemu/`：QEMU 四组合日志和矩阵汇总；
- `GoGoGo-成果材料/图标数据/rock4d/`：ROCK 4D 四组合串口日志；
- `GoGoGo-成果材料/图标数据/plots/`：Task 2、Task 3 和 RTBench 对比图。

PMU cycles/instructions 是可选扩展，不作为 QEMU 与 ROCK 4D 的跨平台完整性条件。
