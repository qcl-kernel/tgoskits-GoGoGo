# AxVisor + RT-Thread Docker 复现手册

本文档描述如何在两种环境下复现同一系统：

- **本机直连**（推荐）：机器已安装 Cargo、uv、QEMU AArch64 和交叉工具链时使用；
- **Docker 容器**：使用固定版本镜像隔离复现，适合 CI 或无本机工具链的环境。

两种环境复现同一系统：

- AxVisor 启动一个 2-vCPU Linux 客户机和一个绑定专用物理 CPU 的 RT-Thread 客户机；
- Linux 与 RT-Thread 通过 VirtIO-net、IPv4、UDP 和 RT-IPC 双向通信；
- 执行实时性 benchmark suite、300 秒稳定性测试，以及原生 RT-Thread 对照测试。

客户机拓扑固定如下：

| 客户机 | vCPU 与 AxVisor pCPU | 网络身份 | 服务 |
|---|---|---|---|
| Linux VM[1] | 2 vCPU，两个 vCPU 都可在 `{0,1}` 内抢占和迁移 | `34:54:00:4d:00:01`，`192.168.77.11/24` | RT-IPC client |
| RT-Thread VM[3] | 1 vCPU，固定 pCPU2，`host_vcpu_idle_policy=busy` | `34:54:00:4d:00:03`，`192.168.77.30/24` | UDP 9876 RT-IPC server |

pCPU3 不分配给客户机实时 vCPU。主数据通道只能使用 VirtIO-net 上的 IP/UDP/RT-IPC；共享内存、HyperCall、vsock 和裸 MMIO 均不作为客户机间数据通道。

已有宿主测试的设计、原始数据和结论见[实时性与客户机通信测试报告](./rtthread-realtime-report.md)。本页只规定 Docker 复现流程。Docker 实测数据将在完成端到端测试后追加到该报告，不能与已有宿主数据混为同一组样本。

## 1. 运行边界

本方案只使用 QEMU TCG，不映射 `/dev/kvm`，不使用 `privileged`、host network、host PID/IPC namespace 或设备映射。容器只增加 `SYS_NICE` capability，不设置 CPU、内存或进程数配额。

`RT_REPRO_CPUSET` 只限制容器可运行的 CPU 集合，不会替宿主隔离 CPU，也不会阻止宿主任务进入这些 CPU。正式采样前仍需选择负载较低的 CPU 并观察宿主负载。

Docker 会引入 cgroup、namespace 和容器运行时开销，三类比较必须分开：

1. cleanup 性能退化门禁比较清理前 control 与清理后测试轮。两侧必须使用相同镜像 digest、cpuset、QEMU、VM 配置、客户机产物、工作负载和容器选项；P50/P95/P99 任一指标出现可重复的超过 10% 增幅即判 FAIL。
2. Docker 开销比较同一提交在同一宿主上的宿主直跑与 Docker 运行。两侧同样固定 QEMU、cpuset、VM/客户机产物和工作负载，P50/P95/P99 的 Docker 增幅目标不超过 10%。
3. 原生 RT-Thread 是独立 RTOS 基线，用来量化 AxVisor 虚拟化路径相对原生 QEMU 的影响，不能替代前两项 A/B 门禁。

TCG 结果用于软件回归和相对比较，不能据此宣称硬实时保证。

## 2. 宿主准备

### 2.1 本机环境（推荐）

如果你的机器已经安装 Cargo、uv、QEMU AArch64 和交叉编译工具链，直接在仓库根目录执行：

```bash
./run-native.sh smoke
```

该脚本会检查本机依赖、复用或生成固定客户机输入、构建 AxVisor 与 RT-Thread，
启动一个 2-vCPU Linux 客户机和一个固定 pCPU 的 RT-Thread 客户机，并运行
RT-IPC over virtio-net。日志写入 `tmp/native-runs/<mode>-<UTC-time>.*`。

可选模式：

```bash
./run-native.sh suite       # 1000 请求 + 1000 样本实时性套件
./run-native.sh stability   # 30000 请求 + 300 秒稳定性
```

常用覆盖：

```bash
QEMU=/path/to/qemu-system-aarch64 ./run-native.sh smoke
NATIVE_INPUT_DIR=/path/to/input-dir ./run-native.sh smoke
RTTHREAD_SRC=/path/to/rt-thread-cache ./run-native.sh smoke
```

脚本自动探测 QEMU 路径（优先 `~/.local/qemu-arm/bin/qemu-system-aarch64`，
然后 `command -v`）；如果输入目录不存在会自动下载固定版本 RT-Thread 源码并构建。
首次运行需要下载 RT-Thread 仓库，后续复用缓存。

等价的手工命令：

```bash
export QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64
export LINUX_KERNEL_IMAGE=tmp/vmconfigs/three-guest-net/current/linux-kernel
export LINUX_INITRAMFS_SOURCE=tmp/vmconfigs/three-guest-net/current/linux-1-initramfs.cpio
export ROOTFS_IMAGE=tmp/vmconfigs/three-guest-net/current/rootfs.img
export RTIPC_COUNT=100 RTIPC_TIMEOUT_S=480 QEMU_UCLAMP_MIN=1024
export LOG=tmp/native-runs/smoke.log
export QEMU_LOG=tmp/native-runs/smoke.qemu.log
export ARTIFACT_LOG=tmp/native-runs/smoke.artifacts
bash os/axvisor/scripts/run_rtipc_test.sh
```

### 2.2 Docker 环境

已验证 Docker Engine 29+ 和 Docker Compose 2.40+。Ubuntu 24.04 可先安装发行版软件包：

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git sysstat
sudo usermod -aG docker "$USER"

docker --version
docker compose version
uname -m
nproc
```

执行 usermod 后应注销并重新登录，再运行版本检查。docker 组可以控制 Docker daemon，等价于授予宿主 root 级权限；不接受这一边界时应使用经过配置的 rootless Docker。

如果发行版提供的版本低于上述下限，按 [Docker Engine Ubuntu 安装文档](https://docs.docker.com/engine/install/ubuntu/) 安装官方仓库版本。宿主必须是 x86_64，至少有 4 个可用逻辑 CPU、16 GiB RAM 和 40 GiB 可用磁盘，并预留网络时间用于基础镜像、QEMU 源码、Rust 依赖与 RT-Thread 源码。

```bash
set -euo pipefail
test "$(uname -m)" = x86_64
test "$(nproc)" -ge 4
test "$(awk '/MemTotal:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)" -ge 16
available_gib="$(df --output=avail -BG . | tail -n 1 | tr -dc '0-9')"
test "$available_gib" -ge 40
```

获取代码：

```bash
set -euo pipefail
git clone git@github.com:qcl-kernel/tgoskits-GoGoGo.git tgoskits
cd tgoskits
git switch rtthread-migration
git rev-parse HEAD

for required_commit in \
  cc1bc7e46 212fe813b 678ee42ff 996d13718; do
  git merge-base --is-ancestor "$required_commit" HEAD || {
    echo "missing required commit: $required_commit" >&2
    exit 1
  }
done
```

必须使用包含上述提交或其后继提交的版本，不要使用实时性报告中更早的历史 HEAD 复现 Docker 流程。

## 3. CPU 与输出目录

先查看 CPU 拓扑并选择 4 个负载较低的逻辑 CPU。示例使用 `4-7`，实际机器应按 `lscpu -e` 的 CORE、SOCKET 和 NODE 信息调整，避免无意中选中同一物理核的 SMT sibling。

```bash
set -euo pipefail
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE,MAXMHZ,MINMHZ
mpstat -P ALL 1 5

export RT_REPRO_UID="$(id -u)"
export RT_REPRO_GID="$(id -g)"
export RT_REPRO_CPUSET="4-7"
export COMPOSE_PROJECT_NAME="tgoskits-rtthread-repro"
export RT_REPRO_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
export RT_REPRO_RUN_DIR="docs/docs/build/axvisor/docker-repro/$RT_REPRO_RUN_ID"

test -z "$(git status --porcelain=v1 --untracked-files=all)" || {
  echo "source checkout is dirty; use a clean release checkout" >&2
  exit 1
}
mkdir -p .docker-cache/{home,cargo,uv} docs/docs/build/axvisor/docker-repro
mkdir "$RT_REPRO_RUN_DIR" || {
  echo "run directory already exists: $RT_REPRO_RUN_DIR" >&2
  exit 1
}
```

UID/GID 透传用于保证容器产物归当前宿主用户所有。采样期间可在另一个终端运行 `mpstat -P ALL 1`；QEMU 启动后，runner 还会用 `pidstat` 生成线程级 CPU 日志。

在构建前验证静态和渲染后的运行契约：

```bash
set -euo pipefail
bash container/test-rtthread-repro.sh --self-test
bash container/test-rtthread-repro.sh

docker compose -f compose.rtthread-repro.yml config >/dev/null
RT_REPRO_UID=23456 RT_REPRO_GID=23457 RT_REPRO_CPUSET=5-7 \
  docker compose -f compose.rtthread-repro.yml config --format json >/tmp/rtthread-compose.json
```

两个 shell 命令都应输出 `PASS`。Compose 契约会拒绝额外 capability、设备、host namespace、资源限额、host network、KVM 和非固定构建策略。

## 4. 固定镜像与预检

```bash
set -euo pipefail
docker compose -f compose.rtthread-repro.yml build --pull

docker compose -f compose.rtthread-repro.yml run --rm \
  rtthread-repro rtthread-repro-preflight

docker image inspect tgoskits-rtthread-repro:2026-08-16 \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}} labels={{json .Config.Labels}}'
```

固定输入包括：

- 基础镜像 digest：`sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4`；
- uv 镜像 digest：`sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4`，uv 版本 0.11.16；
- QEMU 11.0.2 commit：`e545d8bb9d63e9dd61542b88463183314cff9482`；
- RT-Thread 5.2.2 commit：`ddf52e2cdd977f14fc04035c88672ac204aec713`。

Compose 使用 `pull_policy: build`，运行镜像只能由仓库内固定 Dockerfile 构建。预检应报告 QEMU 11.0.2、uv 0.11.16、可见 CPU/cpuset、load average、可写缓存目录和 `[rtthread-repro] PASS`。

## 5. 快速回归矩阵

以下命令在一次容器会话中执行格式、Rust、RT-IPC、12 个 shell contract、fresh RT-Thread 构建和 AxVisor axtest：

```bash
docker compose -f compose.rtthread-repro.yml run --rm \
  rtthread-repro bash -lc '
set -euo pipefail

cargo fmt --all -- --check
cargo test -p arm_vcpu
cargo test -p axvmconfig
cargo test -p axvirtio-net
cargo test -p axvm --features host-test
make -C os/axvisor/guests/rt-ipc/tests clean test
bash container/test-rtthread-repro.sh

for test_script in \
  test_host_realtime_contract.sh \
  test_host_benchmark_timing.sh \
  test_qemu_realtime_controls.sh \
  test_rtbench_precision.sh \
  test_rtbench_suite_gate.sh \
  test_rtbench_stability_gate.sh \
  test_rtipc_result_gate.sh \
  test_rtipc_runner_lifecycle.sh \
  test_rtthread_native_baseline_contract.sh \
  test_rtthread_reproducibility_contract.sh \
  test_generate_linux_vmconfig.sh \
  test_run_until_log_marker.sh; do
  bash "os/axvisor/scripts/$test_script"
done

RTTHREAD_TEST_BUILD=1 \
  bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
cargo xtask ktest qemu -p axvisor --test axtest --arch aarch64
'
```

当前预期计数为：`arm_vcpu` 17 tests + 1 doctest、`axvmconfig` 13 tests、`axvirtio-net` 14 unit + 17 integration、`axvm --features host-test` 258 unit + 1 contract，shell contracts 12/12，以及：

```text
AXTEST_SUMMARY pass=83 fail=0 skip=0 total=83
AXTEST_SUITE_OK
```

RT-Thread 上游源码可能产生既有编译 warning。只有构建退出码为 0、fresh patchset 测试通过且后续门禁为 PASS 时，这些 warning 才可判为非阻断。

## 6. 端到端与实时性测试

所有命令都在同一镜像和 cpuset 下运行。每次复现必须重新生成 `RT_REPRO_RUN_ID`，并由无 `-p` 的 `mkdir` 拒绝复用已有目录。suite 和 stability runner 会在主日志旁生成 `.qemu`、`.artifacts` 和 `.timing` 文件；不启用 benchmark 的 smoke 只生成主日志、`.qemu` 和 `.artifacts`，不要求 `.timing`。

### 6.1 100 请求 smoke

```bash
docker compose -f compose.rtthread-repro.yml run --rm \
  -e RT_REPRO_RUN_DIR rtthread-repro bash -lc '
set -euo pipefail
case_dir="${RT_REPRO_RUN_DIR}/smoke"
mkdir "$case_dir"
env RTIPC_COUNT=100 RTIPC_TIMEOUT_S=480 \
  QEMU_UCLAMP_MIN=1024 \
  LOG="$case_dir/run.log" \
  bash os/axvisor/scripts/run_rtipc_test.sh
'
```

smoke 必须同时出现 Linux 2-vCPU/SMP 证据、RT-Thread lwIP 与 RT-IPC server ready 标记；三档 payload 均应为 100/100。每档应用层必须满足 `request_timeouts=0 protocol_errors=0`，传输层必须满足 `timeouts=0 errors=0`；结果门禁必须 PASS。

### 6.2 1000 样本 suite

```bash
docker compose -f compose.rtthread-repro.yml run --rm \
  -e RT_REPRO_RUN_DIR rtthread-repro bash -lc '
set -euo pipefail
case_dir="${RT_REPRO_RUN_DIR}/suite"
mkdir "$case_dir"
env RTIPC_COUNT=1000 RTBENCH_SUITE_SAMPLES=1000 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG="$case_dir/run.log" \
  CPU_LOAD_LOG="$case_dir/cpu.log" \
  bash os/axvisor/scripts/run_rtipc_test.sh
'
```

三档 payload 必须各 1000/1000；每档应用层 `request_timeouts=0 protocol_errors=0`，传输层 `timeouts=0 errors=0`。每项 benchmark 必须满足 `expected=1000 collected=1000 missing=0`，最终 `RTBENCH_END status=PASS`。

### 6.3 300 秒稳定性

```bash
docker compose -f compose.rtthread-repro.yml run --rm \
  -e RT_REPRO_RUN_DIR rtthread-repro bash -lc '
set -euo pipefail
case_dir="${RT_REPRO_RUN_DIR}/stability"
mkdir "$case_dir"
env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG="$case_dir/run.log" \
  CPU_LOAD_LOG="$case_dir/cpu.log" \
  bash os/axvisor/scripts/run_rtipc_test.sh
'
```

成功条件包括 90000/90000 个网络请求；三档 payload 的应用层 `request_timeouts=0 protocol_errors=0`，传输层 `timeouts=0 errors=0`；稳定性任务 `expected=299999 collected=299999 missing=0`。如果只有最大值或 `miss_1ms` 变差，而 P50/P95/P99 和功能门禁正常，应使用新的 run ID 在相同条件下再运行一轮，然后再判断是否退化。

### 6.4 同容器原生 RT-Thread 基线

```bash
docker compose -f compose.rtthread-repro.yml run --rm \
  -e RT_REPRO_RUN_DIR rtthread-repro bash -lc '
set -euo pipefail
case_dir="/workspace/${RT_REPRO_RUN_DIR}/native"
mkdir "$case_dir"
env RTBENCH_STABILITY_SECONDS=300 RTBENCH_TIMEOUT_S=480 \
  QEMU=/opt/qemu-11.0.2/bin/qemu-system-aarch64 \
  QEMU_UCLAMP_MIN=1024 \
  RTTHREAD_NATIVE_SRC=/workspace/.docker-cache/rt-thread-5.2.2-native \
  NATIVE_GUEST_LOG="$case_dir/run.log" \
  NATIVE_QEMU_LOG="$case_dir/qemu.log" \
  NATIVE_CPU_LOAD_LOG="$case_dir/cpu.log" \
  bash os/axvisor/scripts/run_rtthread_native_baseline.sh
'
```

原生轮次必须使用与 AxVisor 轮次相同的镜像、cpuset、QEMU 和 uclamp 值。比较时至少记录周期抖动、调度/回调延迟的 P50/P95/P99/max、`miss_1ms` 和 CPU 分布。

## 7. 门禁与证据采集

runner 会自动调用结果门禁。需要手工复核时，在仓库根目录执行：

```bash
set -euo pipefail
# smoke 网络结果；最后两个参数为 QEMU 退出码和 fault profile
bash os/axvisor/scripts/verify_rtipc_results.sh \
  "$RT_REPRO_RUN_DIR/smoke/run.log" 100 0 none

# suite 网络与实时性结果
bash os/axvisor/scripts/verify_rtipc_results.sh \
  "$RT_REPRO_RUN_DIR/suite/run.log" 1000 0 none
bash os/axvisor/scripts/verify_rtbench_suite.sh \
  "$RT_REPRO_RUN_DIR/suite/run.log" 1000 0

# 300 秒网络与稳定性结果
bash os/axvisor/scripts/verify_rtipc_results.sh \
  "$RT_REPRO_RUN_DIR/stability/run.log" 30000 0 none
bash os/axvisor/scripts/verify_rtbench_stability.sh \
  "$RT_REPRO_RUN_DIR/stability/run.log" 300 0
```

这些手工命令中的 QEMU 退出码 `0` 只适用于 QEMU 正常退出的已完成日志；超时或异常退出必须使用 runner 实际记录的退出码，不能把失败改写为 0。

提取成功标记、错误计数、样本完整性和分位数：

```bash
set -euo pipefail
rg -a 'Linux SMP|RTIPC_SERVER_READY|RTIPC_RESULT|RTBENCH_(BEGIN|END|STABILITY)|expected=|collected=|missing=|p50=|p95=|p99=|max=|miss_1ms=' \
  "$RT_REPRO_RUN_DIR"

rg -a 'ERROR|FAIL|request_timeouts=[1-9]|protocol_errors=[1-9]|timeouts=[1-9]|errors=[1-9]|panic|assert' \
  "$RT_REPRO_RUN_DIR"

sed -n '1,240p' "$RT_REPRO_RUN_DIR/stability/cpu.log"
```

每次正式测试还应保存环境和不可变性证据：

```bash
set -euo pipefail
{
  date --iso-8601=seconds
  docker --version
  docker compose version
  uname -a
  lscpu
  printf 'cpuset=%s\n' "$RT_REPRO_CPUSET"
  git rev-parse HEAD
  git status --short
  docker image inspect tgoskits-rtthread-repro:2026-08-16 \
    --format 'id={{.Id}} repo_digests={{json .RepoDigests}} labels={{json .Config.Labels}}'
} >"$RT_REPRO_RUN_DIR/environment.txt"

manifest_tmp="$(mktemp "${RT_REPRO_RUN_DIR}.SHA256SUMS.tmp.XXXXXX")"
trap 'rm -f -- "$manifest_tmp"' EXIT
{
  sha256sum container/Dockerfile.rtthread-repro compose.rtthread-repro.yml
  find "$RT_REPRO_RUN_DIR" -type f \
    ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 -r sha256sum
} >"$manifest_tmp"
mv -- "$manifest_tmp" "$RT_REPRO_RUN_DIR/SHA256SUMS"
trap - EXIT
```

先完成所有日志写入，再通过临时文件原子生成 `SHA256SUMS`；manifest 明确排除自身。run 目录禁止复用，因此正式证据不会被下一轮截断覆盖。报告中应记录命令、运行时长、退出码、镜像 ID、宿主内核/CPU、cpuset、CPU 负载、三档请求成功率、应用层错误、应用与传输超时、恢复行为、RTT/吞吐量和实时性分位数。

误差来源包括 TCG 线程调度、cgroup/cpuset、宿主背景负载、DVFS、SMT sibling、宿主与客户机定时器、日志 I/O 和 Docker runtime。A/B 比较必须控制这些变量；不能用不同宿主或不同镜像的数据计算 10% 开销。

## 8. 常见问题

### 可见 CPU 少于 4 个

检查 `RT_REPRO_CPUSET` 是否有效，并用 `docker compose ... config` 查看渲染值。cpuset 必须选择至少 4 个在线 CPU。

### `uclampset` 或 `SYS_NICE` 失败

确认 Compose 中只有 `cap_add: [SYS_NICE]`，宿主内核支持 utilization clamp，并重新运行 preflight。不要通过 `privileged: true` 绕过检查。

### 输出文件属于 root 或目录不可写

重新导出当前用户的 UID/GID，确认 `.docker-cache` 和 `docker-repro` 由当前用户创建。不要在前面加 `sudo docker compose`，否则会改变所有权和 Docker 环境。

### QEMU/uv 版本不匹配

执行 `docker compose ... build --pull`，再检查镜像标签和 preflight 输出。不要用系统 QEMU 替换 `/opt/qemu-11.0.2/bin/qemu-system-aarch64`。

### 构建提示缺少 buildx

部分发行版 Docker 会提示 legacy builder 或 Compose Bake 缺少 buildx。以构建最终退出码和镜像标签为准；如果构建失败，安装与 Docker 版本匹配的 buildx 插件后重试，不要改用未固定的远端镜像。

### 运行超时或结果不稳定

先检查 `.qemu`、`.timing`、CPU 日志和宿主 `mpstat`。确认没有其他 QEMU 实例占用同一 cpuset。只有最大值或 `miss_1ms` 单项异常时按相同条件复验一次；功能门禁、样本缺失或 P50/P95/P99 失败时不能用复验掩盖失败。

## 9. 停止与清理

只暂停容器时使用 `stop`。确认不再需要保留容器状态后，`down` 会删除专用项目 `tgoskits-rtthread-repro` 的容器和网络，但不删除证据、缓存或镜像：

```bash
set -euo pipefail
docker compose -f compose.rtthread-repro.yml stop
docker compose -f compose.rtthread-repro.yml down
```

`.docker-cache/` 和 `docs/docs/build/axvisor/docker-repro/` 均被保留。删除镜像、缓存或证据属于显式清理操作，应在完成哈希归档并确认不再需要复验后单独执行。
