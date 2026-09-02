# AxVisor Task 1/2/3 中文复现指南

本文复现一个 2-vCPU Linux 客户机和一个固定核 RT-Thread 客户机，并在同一
AxVisor 实例中运行实时性测试、RT-IPC 网络通信和 AI 控制闭环。

## 1. 固定版本

| 项目 | 版本 |
|---|---|
| 分支 | `feat/axvisor-task123` |
| 受测 runtime 提交 | `7e25b6ceeb8a1613705b90d47969482479a10dda` |
| RTOS | RT-Thread 5.2.2 |
| RT-Thread commit | `ddf52e2cdd977f14fc04035c88672ac204aec713` |
| 宿主 | Ubuntu 24.04，kernel `6.17.0-40` |
| QEMU | QEMU 11.0.2 |
| Rust | nightly `2026-07-14` |
| Python/SCons | uv 0.11.16 临时环境 |
| AArch64 GCC | 13.3.0 |

所有修改必须在
`/home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123-integration`
中进行。原始 `tgoskits` 和 `qemu-task3` checkout 是只读输入。
报告提交可以晚于受测 runtime commit，但
`git diff --name-only 7e25b6cee..HEAD` 必须只包含报告、文档契约或导入
baseline 文本规范化，不得包含可执行源码、配置或 runner 逻辑。

## 2. 宿主依赖

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git curl ca-certificates pkg-config \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  python3 python3-venv cpio rsync file bc

uv --version
aarch64-linux-gnu-gcc --version
/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 --version
```

SCons 不安装到系统 Python。构建 RT-Thread 时统一使用
`uv run --with scons`。

普通用户环境的 `ulimit -r=0`、`ulimit -e=0` 不能设置实时调度优先级。
Docker 会增加调度噪声，可以验证构建和功能，但不是权威实时环境。300 秒
实时性数据应在宿主直接运行，且必须注明 QEMU TCG 限制。

## 3. 拓扑

| 对象 | CPU | 内存 | MAC/IP | 服务 |
|---|---|---|---|---|
| Linux VM[1] | `phys_cpu_ids=[0,1]`，两个 mask `0b1011`，可在 pCPU 0/1/3 调度 | `0x80000000..0x9fffffff`，512 MiB | `52:54:00:77:00:01` / `192.168.77.11/24` | UDP 9876、UDP 9877 |
| RT-Thread VM[3] | `phys_cpu_ids=[2]`，mask `0b0100`，固定 pCPU 2，busy WFI | `0xa0000000..0xafffffff`，256 MiB | `52:54:00:77:00:03` / `192.168.77.30/24` | UDP 9876、UDP 9877 |

两端同属 `192.168.77.0/24`。网络拓扑是 AxVisor virtio-net 内部 L2 switch，
无 gateway、无 NAT、无 TAP、无 bridge、无 firewall 入站规则。VirtIO RX
准备好数据后，经 vCPU wakeup 和 VGIC SPI 即时事件路径进入 guest ISR。

应用数据只能使用 IPv4/UDP/RT-IPC v2 网络通道。禁止使用共享内存、HyperCall、
raw MMIO、vsock 或其他非网络应用数据通道；这些机制即使存在于虚拟化控制面，
也不得承载 Task 2/3 的控制、状态或模型输出。

## 4. 工作目录和环境变量

```bash
cd /home/yfblock/Code/hyper-rtos/.worktrees/axvisor-task123-integration

export QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64
export RTTHREAD_REPOSITORY=/path/to/rt-thread-5.2.2
export ROOTFS_IMAGE=/path/to/rootfs.img
export LINUX_KERNEL_IMAGE="$PWD/tmp/task123-linux-build-v3/images/linux/Image"
export LINUX_INITRAMFS_IMAGE="$PWD/tmp/task123-linux-build-v3/images/linux/rootfs.cpio"
export TASK123_TIMEOUT_S=600
export QEMU_TIMER_SLACK_NS=1
```

runner 会校验所有输入文件是规范绝对路径、输出目录不与输入重叠，并只管理本轮
记录的 QEMU PID。

## 5. RT-Thread 构建

准备脚本校验 RT-Thread 5.2.2 固定提交，然后在生成目录应用 AxVisor、
virtio-net、lwIP、timer、RT-IPC 与 Task 3 补丁：

```bash
os/axvisor/patches/rtthread/prepare_rtthread_source.sh tmp/task123-rtthread
os/axvisor/patches/rtthread/apply-rtthread-patches.sh tmp/task123-rtthread

uv run --with scons scons \
  -C tmp/task123-rtthread/bsp/qemu-virt64-aarch64 \
  -j"$(getconf _NPROCESSORS_ONLN)"

test -s tmp/task123-rtthread/bsp/qemu-virt64-aarch64/rtthread.bin
```

从全新源验证补丁集：

```bash
bash os/axvisor/patches/rtthread/test_prepare_rtthread_source.sh
bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
```

## 6. AI 模型和 Linux 镜像

```bash
BUILD_DIR="$PWD/tmp/task123-model-build" \
  os/axvisor/guests/task3/scripts/build_model.sh

BUILD_DIR="$PWD/tmp/task123-linux-build-v3" \
  os/axvisor/guests/task3/scripts/build_linux.sh

test -s tmp/task123-linux-build-v3/images/linux/Image
test -s tmp/task123-linux-build-v3/images/linux/rootfs.cpio
bash os/axvisor/scripts/test_task123_linux_image_contract.sh
```

Linux initramfs 同时包含 Task 2 客户端、Task 3 模型/视频/程序和 `/init`。
guest cmdline 由 runner 写入生成的 VM TOML，不使用外层 QEMU `-append` 传递
guest workload 参数。

## 7. AxVisor 构建

下列命令生成真实、可执行的不可变 VM 配置并构建 AxVisor：

```bash
LINUX_RUNTIME_DIR="$(mktemp -d "$PWD/tmp/rtipc-runtime.XXXXXX")"
RTTHREAD_RUNTIME_DIR="$(mktemp -d "$PWD/tmp/rtthread-runtime.XXXXXX")"
GUEST_CMDLINE='console=ttyAMA0 rdinit=/init task2.count=1000 task2.fault=none task3.frames=3 task3.fault=normal'

LINUX_VMCONFIG="$(
  os/axvisor/scripts/generate_linux_vmconfig.sh \
    "$PWD" os/axvisor/configs/vms/qemu/aarch64/linux-net.toml \
    "$LINUX_KERNEL_IMAGE" "$LINUX_INITRAMFS_IMAGE" \
    "$LINUX_RUNTIME_DIR" "$GUEST_CMDLINE"
)"
RTTHREAD_VMCONFIG="$(
  os/axvisor/scripts/generate_rtthread_vmconfig.sh \
    "$PWD" os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml \
    "$PWD/tmp/task123-rtthread/bsp/qemu-virt64-aarch64/rtthread.bin" \
    "$RTTHREAD_RUNTIME_DIR"
)"

cargo xtask axvisor build --config qemu-aarch64-two-guest-net \
  --vmconfigs "$LINUX_VMCONFIG" \
  --vmconfigs "$RTTHREAD_VMCONFIG"
```

推荐直接运行下一节的 runner，它会完成同样的生成、
`cargo xtask axvisor build`、strip、objcopy、单 QEMU 启动、marker 门禁和哈希记录，
并在退出时删除临时 VM 配置目录。

## 7.1 一键复现（推荐）

日常复现只需要在仓库根目录执行一条命令，不需要预先设置环境变量：

```bash
# Linux 2-vCPU + RT-Thread + virtio-net/RT-IPC 快速验证
./run-native.sh smoke

# 1000 样本实时性测试
./run-native.sh suite

# 300 秒长时间稳定性测试
./run-native.sh stability
```

脚本直接使用 `PATH` 中的 `qemu-system-aarch64`，自动选择本地 Linux
kernel、initramfs、rootfs、模型和固定提交的完整 RT-Thread 源码。默认结果写到
`tmp/native-runs/<mode>-<UTC 时间>`，终端会持续显示底层 runner 的
`PHASE`/`STEP` 进度。需要指定结果目录时使用：

```bash
./run-native.sh smoke --output tmp/my-task123-smoke
```

只有调试非默认输入时才需要可选覆盖：`NATIVE_INPUT_DIR` 指定包含
`linux-kernel`、initramfs 和 `rootfs.img` 的目录，`RTTHREAD_SRC` 指定固定版本、
对象完整且工作树干净的 RT-Thread Git 仓库。显式输入无效时脚本直接失败，
不会静默改用其他路径。正式实时性数据应直接在宿主运行；Docker 结果仅用于
构建和功能复现。

需要一次执行 smoke、短实时性、Task 3 或完整故障矩阵时，使用聚合复现脚本：

```bash
# 默认 quick：smoke、100 样本实时性 suite、30+30 帧 Task 3
os/axvisor/scripts/reproduce_task123.sh

# 完整验收：1000 样本实时性 suite、300 秒长稳、600+600 帧 Task 3、五种故障场景
os/axvisor/scripts/reproduce_task123.sh --full \
  --output tmp/task123-reproduction-full
```

`--quick` 是默认模式；镜像已准备时，适合几分钟级功能和短时实时性验证；
`--full` 执行完整验收。脚本继承第 4 节的镜像和工具环境变量；未提供预构建镜像时，底层
`run_task123.sh` 会下载固定版本源码并构建所需镜像。每个阶段仍由统一 runner
负责 QEMU 生命周期、marker 和结果门禁，一键脚本不复制这些逻辑。

成功后输出目录包含 `reproduction-summary.txt`、`system-info.txt`、各阶段原始
结果、`task123-quick-evidence.tar.gz` 或 `task123-full-evidence.tar.gz`，以及对应
`.sha256` 文件。除已确认的 QEMU/TCG 1 ms 长稳限制外，任一依赖、构建、网络、
协议、Task 3、结果格式或归档错误都会立即失败。完整模式只有在 Linux、Task 2
和 Task 3 均已通过且日志明确记录非零 `miss_1ms` 时才继续，并将最终状态写为
`PASS_WITH_QEMU_TIMER_LIMIT`，不会把该结果伪装成无条件 PASS。

运行期间，终端会实时显示输出目录、总日志路径以及底层 runner 的 `PHASE`/`STEP`
进度。首次下载或构建可能在某个 `STEP` 停留数分钟；详细输出同时保存在
`reproduction.log` 和各阶段的 `runner.log` 中，可在另一个终端使用 `tail -f`
观察，不需要等待阶段结束。

Docker 可以执行构建和功能复现，但容器调度噪声会影响延迟尾部。因此一键脚本
默认直接在宿主运行；实时性报告只接受宿主机运行结果，Docker 结果不得作为
300 秒确定性结论。

## 8. 统一运行命令

先创建输出父目录：

```bash
mkdir -p tmp/task123-results/task3-faults
```

每个命令都使用同一组环境：

```bash
run_task123() {
  env \
    LINUX_KERNEL_IMAGE="$LINUX_KERNEL_IMAGE" \
    LINUX_INITRAMFS_IMAGE="$LINUX_INITRAMFS_IMAGE" \
    ROOTFS_IMAGE="$ROOTFS_IMAGE" \
    RTTHREAD_REPOSITORY="$RTTHREAD_REPOSITORY" \
    QEMU="$QEMU" \
    TASK123_TIMEOUT_S="$TASK123_TIMEOUT_S" \
    QEMU_TIMER_SLACK_NS="$QEMU_TIMER_SLACK_NS" \
    os/axvisor/scripts/run_task123.sh "$@"
}
```

### 8.1 Smoke

```bash
run_task123 --mode smoke --task2-count 1000 --task3-frames 3 \
  --output tmp/task123-results/smoke
```

### 8.2 实时性 suite

```bash
run_task123 --mode realtime-suite --rtbench-samples 1000 \
  --task2-count 1000 \
  --output tmp/task123-results/realtime-suite-r5-final
```

### 8.3 300 秒稳定性

```bash
run_task123 --mode stability --seconds 300 --task2-count 30000 \
  --output tmp/task123-results/stability-300s
```

该命令在严格 `miss_1ms=0` 门禁失败时返回非零，这是有效结果，不能删除
`console.log` 或反复运行直到偶然 PASS。

### 8.4 Task 3 正常场景

```bash
run_task123 --mode task3 --task3-frames 600 \
  --output tmp/task123-results/task3-normal
```

### 8.5 Task 3 故障场景

配置列表：`drop-control drop-status duplicate-frame delayed-server malformed`。

```bash
for profile in drop-control drop-status duplicate-frame delayed-server malformed; do
  run_task123 --mode task3-fault --task3-fault "$profile" \
    --task3-frames 3 \
    --output "tmp/task123-results/task3-faults/$profile"
done

python3 os/axvisor/guests/task3/scripts/summarize_faults.py \
  --suite-dir tmp/task123-results/task3-faults
```

## 9. 预期 marker

架构和网络：

```text
LINUX_SMP_READY configured=2
TASK123_LINUX_NET_READY
RTIPC_SERVER_READY ip=192.168.77.30 port=9876
TASK3_RTOS_READY ip=192.168.77.30 port=9877
```

应用和门禁：

```text
TASK2_LINUX_END status=PASS
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
RTBENCH_END status=PASS
TASK3_RTOS_FINAL requests=...
result_gate=PASS
```

runner 将 `panic`、`assert`、`fatal`、`TASK123_LINUX_END status=FAIL`
和 benchmark FAIL 视为失败，保存日志并只回收本轮进程组。

## 10. 结果目录

每个成功目录至少包括：

```text
axvisor.bin
console.log
linux.log
rtthread.log
frames.csv
summary.raw.json
summary.json
manifest.txt
runner.log
```

`manifest.txt` 记录 mode、参数、`qemu_timer_slack_ns`、QEMU/内核/initramfs/
RT-Thread/VM config/model/protocol/rootfs 哈希、QEMU 原始退出状态、termination reason
和结果门禁。

## 11. 原始哈希复核

已接受数据：

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

```bash
sha256sum \
  tmp/task123-results/task3-normal/manifest.txt \
  tmp/task123-results/task3-normal/summary.json \
  tmp/task123-results/task3-normal/frames.csv \
  tmp/task123-results/task3-normal/console.log \
  tmp/task123-results/realtime-suite-r5-final/manifest.txt \
  tmp/task123-results/stability-300s/console.log \
  tmp/task123-results/stability-300s-r2-timerslack1/console.log \
  tmp/task123-results/stability-300s-r3-timerslack1/console.log \
  tmp/task123-results/stability-300s-r4-low-host-load/console.log \
  tmp/task123-results/task3-faults/fault-summary.json
```

完整交付归档：

```bash
sha256sum tmp/task123-results/task123-evidence-7e25b6cee.tar.gz
# 期望：
# 5e2f220eeb7e22bbd540172c77d9818a606f9d0228e81ae8025acc792c5a62ba
gzip -t tmp/task123-results/task123-evidence-7e25b6cee.tar.gz
tar -tzf tmp/task123-results/task123-evidence-7e25b6cee.tar.gz
```

归档包含 99 个条目，覆盖 suite、四轮 300 秒、Task 3 normal/fault 和
`evidence-runtime-commit.txt`。它位于共享工作区 `tmp`，按计划不提交 Git。

## 12. 故障诊断

| 现象 | 检查 |
|---|---|
| 输出父目录错误 | 先 `mkdir -p` 父目录；输出目录本身应由 runner 创建 |
| Linux 未启动 2 vCPU | 查 `LINUX_SMP_READY`、PSCI CPU_ON、生成的 Linux TOML |
| RT-Thread 未 READY | 查网络、socket、receive-timeout、bind ERROR marker |
| Task 2 TX timeout | 查两个 virtio-net MAC、IP、VGIC SPI 和 RT-Thread ISR；不要加 RX 轮询 |
| benchmark 没有最终数据 | 查 console mux 的 VM1/VM3 切换和 `failure-marker` |
| 300 秒实时门禁 FAIL | 保留完整原始日志；区分 QEMU timer assert 前和 TCG 调度等待 |
| manifest 缺失 | 查 `runner.log` 中 build、marker、QEMU exit 或 result gate 失败 |

Docker 中可运行静态测试、C/Rust 单测和构建复现，但 Docker 会增加调度噪声，
不是权威实时环境。QEMU TCG 结果也不能替代隔离硬件/PREEMPT_RT 上的 WCET 验证。
