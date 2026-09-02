# Axvisor 物理板卡上板说明

本文说明如何把 Axvisor 编译产物刷到物理开发板并运行 board 测试，覆盖板卡资源
申请、guest 资产准备、构建、刷写、运行判定与常见问题。目标读者是需要在真实
ARM/x86 板上跑 Axvisor guest（当前仓库已验证的形态包含 ROCK 4D 上的
**RT-Thread/Zephyr + Linux/StarryOS 四种组合**）的
开发者。

本文依据仓库现有资产编写：

- 板卡配置：`os/axvisor/configs/board/*.toml` 与 `os/axvisor/configs/vms/*/`
- 板级测试用例：`test-suit/axvisor/normal/board-*`
- 运行/板卡管理文档：`docs/docs/build/axvisor/runtime.md`、`docs/docs/build/board.md`、
  `docs/docs/build/axvisor/real-arm-board-run.md`、`docs/docs/build/axvisor/rock-4d.md`
- 板级 CI：`.github/workflows/ci.yml`（自托管 board 任务）

---

## 1. 支持板型与状态

正式 board 配置在 `os/axvisor/configs/board/`，每块板一个 TOML；guest 配置在
`os/axvisor/configs/vms/<板名>/`。当前支持矩阵：

| 板型 | SoC | 架构 | 仓库内 board DTB | 已配置 guest | CI 常态验证 |
|------|-----|------|------------------|-------------|------------|
| Orange Pi 5 Plus | RK3588 | aarch64 | 有（`orangepi-5-plus.dtb`） | linux / starry / arceos / freertos / zephyr | ✅ linux、starry、robot-linux、robot-starry |
| ROC-RK3568-PC | RK3568（Firefly） | aarch64 | 无（外部提供） | linux smp1/smp2、arceos smp1/smp2 | ✅ roc-rk3568-pc-linux |
| PhytiumPi | 飞腾 PE2204 | aarch64 | 无（外部提供） | linux/arceos smp1+smp2、freertos、zephyr、rtthread | ✅ phytiumpi-linux |
| ASUS NUC15CRH | x86_64（ACPI） | x86_64 | 无（ACPI） | linux smp1 | ✅ asus-nuc15crh-linux |
| Rock 4D | RK3576（Radxa） | aarch64 | 有（`rock-4d.dtb`） | RT-Thread/Zephyr + Linux/StarryOS 四组合 | ✅ 手工完成四组合 |
| TAC-E400 | 飞腾系（复用 pe2204 DTS） | aarch64 | 无 | linux、arceos、freertos、zephyr | ❌ |
| RDK-S100 | D-Robotics S100P | aarch64 | 无 | linux smp1、arceos smp1 | ❌ |

仅 VM 配置、无 board 配置的（`configs/vms/` 里存在但 `configs/board/` 里没有对应
TOML）属于实验性/占位：RK3588 generic（`vms/rk3588/linux-smp8.toml`，DTS 是
Firefly ITX-3588J，镜像路径为占位符）、BST A1000B（`vms/a1000/linux-smp8-*.toml`）、
EVM3588（仅 README 提及，无任何配置/DTB/测试）。这些不能直接上板。

> **当前状态（2026-08-25）**：ROCK 4D 已完成 RT-Thread/Zephyr 与 Linux/StarryOS
> 的四种组合真机验证。每个组合均通过 Task 2、Task 3 和 Task123 门禁，并采集完整
> 的 16 项纳秒 RTBench 指标。早期“单 Linux/RTOS 占位镜像”的描述仅适用于历史
> 阶段，不适用于当前 Task123 配置。

最终数据见 `GoGoGo-成果材料/数据报告/task123/report/2026-08-25/tgoskits/`
和 `GoGoGo-成果材料/图标数据/`。

---

## 2. 前置条件

### 2.1 硬件与板卡固件

- 真实板卡，接好电源（可软件复位/断电）、串口、以及可被 TFTP 访问的网络接口。
- 板卡上已烧好厂商 U-Boot 与可用根文件系统（SD 卡 / eMMC）。**U-Boot 不在本仓库，
  也不由仓库构建**，版本取决于板卡厂商固件（Rock 4D 来自 Radxa BSP，Orange Pi 5
  Plus 环境参考 U-Boot 2024.10，见
  `docs/docs/architecture/driver/usb/rk3588-device-discovery.md`）。仓库唯一要求是
  该 U-Boot 支持串口交互 + `tftp`/`bootm`。
- host DTB（U-Boot/hypervisor 使用的设备树）与板卡固件、内存容量、启动地址匹配。
  Orange Pi 5 Plus / Rock 4D 有仓库内候选 DTB（`configs/board/*.dtb`）；PhytiumPi、
  ROC-RK3568-PC 等必须从板卡或外部镜像提供，通过 `BOARD_DTB` 环境变量传入。

### 2.2 板卡服务（ostool-server）

板卡测试依赖 `ostool-server`：运行在连接物理板的宿主机上，提供板卡分配、固件
部署、串口转发、电源控制。axbuild 通过 HTTP 与之交互。首次使用先配置服务地址：

```bash
cargo xtask board config   # 编辑 ostool 全局配置（server / port）
cargo xtask board ls       # 列出可用板型与数量
```

人工串口调试（进 U-Boot、看引导日志、准备板卡文件）用：

```bash
cargo xtask board connect -b OrangePi-5-Plus   # 占用板卡并透传串口，Ctrl+D 释放
```

### 2.3 环境变量

板级测试通过以下环境变量把板卡连接信息交给 runner（`.github/workflows/uboot.toml`
里全部以 `${env:...}` 引用）：

```text
BOARD_COMM_UART_DEV   板卡串口设备路径
BOARD_COMM_UART_BAUD  串口波特率
BOARD_POWER_OFF       断电命令
BOARD_POWER_RESET     复位命令
BOARD_COMM_NET_IFACE  TFTP 使用的网卡
TFTP_DIR              TFTP 根目录（存放 image.fit）
BOARD_DTB             host DTB 路径
```

---

## 3. guest 资产准备

对于 `image_location = "fs"` 的 guest 配置（如 Rock 4D、Orange Pi 5 Plus），Axvisor
从**板卡根文件系统**读取 guest 内核与 guest DTB，仓库构建**不会**自动生成或安装它们，
必须手工部署。以 Rock 4D 为例（完整流程见 `docs/docs/build/axvisor/rock-4d.md`）：

```bash
export TGOSKITS_ROOT=/path/to/tgoskits
export ROCK4D_BSP=/path/to/rock-4d/bsp
export ROCK4D_HOST=<board-linux-ip>
export ROCK4D_USER=radxa

# 1) 用 Radxa BSP 构建 guest 内核 Image（linux/rk2410 profile）
cd "${ROCK4D_BSP}" && ./bsp linux rk2410
test -s .src/linux/arch/arm64/boot/Image

# 2) 用仓库维护的 DTS 生成 guest DTB
cd "${TGOSKITS_ROOT}"
mkdir -p tmp/axvisor/rock-4d
dtc -I dts -O dtb \
  -o tmp/axvisor/rock-4d/rock-4d-linux-smp1.dtb \
  os/axvisor/configs/vms/rock-4d/linux-smp1.dts
test -s tmp/axvisor/rock-4d/rock-4d-linux-smp1.dtb

# 3) 部署到板卡 Axvisor guest 目录并 sync
scp "${ROCK4D_BSP}/.src/linux/arch/arm64/boot/Image" \
    tmp/axvisor/rock-4d/rock-4d-linux-smp1.dtb \
    "${ROCK4D_USER}@${ROCK4D_HOST}:/tmp/"
ssh "${ROCK4D_USER}@${ROCK4D_HOST}" \
  'sudo install -D -m 0644 /tmp/Image /guest/linux/rock-4d && \
   sudo install -m 0644 /tmp/rock-4d-linux-smp1.dtb \
     /guest/linux/rock-4d-linux-smp1.dtb && \
   sudo sync && \
   test -s /guest/linux/rock-4d && \
   test -s /guest/linux/rock-4d-linux-smp1.dtb'
```

guest TOML 里对应的路径是：

```toml
[kernel]
kernel_path = "/guest/linux/rock-4d"
dtb_path    = "/guest/linux/rock-4d-linux-smp1.dtb"
```

**部署失败必须停止**，不得使用旧内核或旧 DTB 继续测试。更新 BSP 内核或 guest DTS
后必须重跑构建、部署、`sync` 三步。

---

## 4. 上板测试命令与流程

### 4.0 Task123 真机四组合入口（2026-08-25）

以下四条命令分别完成构建、guest 资产准备、AxVisor/U-Boot 启动和结果门禁。命令中的
`rock-4d-uboot-local.toml` 只保留在本机，需按实际串口和电源控制方式配置：

```bash
# RT-Thread + Linux
cargo xtask axvisor task123 uboot --rtos rtthread --app-guest linux \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-linuxleg.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# RT-Thread + StarryOS
cargo xtask axvisor task123 uboot --rtos rtthread --app-guest starryos \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-twoguest.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# Zephyr + Linux
cargo xtask axvisor task123 uboot --rtos zephyr --app-guest linux \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-zephyr-linux.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml

# Zephyr + StarryOS
cargo xtask axvisor task123 uboot --rtos zephyr --app-guest starryos \
  --realtime-suite --rtbench-samples 10 \
  --config os/axvisor/configs/board/rock-4d-task123-zephyr-starryos.toml \
  --uboot-config os/StarryOS/configs/board/rock-4d-uboot-local.toml
```

四条命令均要求对应客户机输出 `TASK123_*_END status=PASS`，并要求 RTBench 每项
满足 `expected=10 collected=10 missing=0`。Task 2 请求数由板级 VM 配置固定为 10。

### 4.1 标准 board smoke 测试

一条命令完成「编译 → 打包 FIT → 经 ostool 刷写 → U-Boot `tftp image.fit && bootm`
→ 收集串口 → 匹配成败」：

```bash
cargo xtask axvisor test board --board rock-4d-linux
```

`--board` 是**测试组名**（来自 `test-suit/axvisor/normal/board-*/smoke/*.toml`），
不是板型名，也不要和 `--board-type`（硬件服务类型）混淆。可用组名：

```text
orangepi-5-plus-linux        orangepi-5-plus-starry
orangepi-5-plus-robot-linux  orangepi-5-plus-robot-starry
roc-rk3568-pc-linux          phytiumpi-linux
asus-nuc15crh-linux          rock-4d-linux          rdk-s100-linux
```

查看实际发现到的名称：

```bash
cargo xtask axvisor config ls
cargo xtask axvisor test board --list
```

### 4.2 U-Boot 单 guest 入口（历史命令形态）

`real-arm-board-run.md` 记录的单 Linux 入口：

```bash
cargo xtask axvisor test uboot --board orangepi-5-plus --guest linux
cargo xtask axvisor test uboot --board phytiumpi --guest linux
```

### 4.3 每个测试组的判定

smoke TOML 定义 `success_regex` / `fail_regex` / `timeout`（默认 300s）。例子：

| 组 | success_regex | 说明 |
|----|---------------|------|
| orangepi-5-plus-linux | `^test pass$`（`shell_init_cmd` 打印） | 通过 shell 命令确认 |
| phytiumpi-linux | `^phytiumpi login:` | 到 guest Linux 登录提示 |
| rock-4d-linux | `^rock-4d-spi login:` | 到 guest Linux 登录提示 |
| roc-rk3568-pc-linux | `login:` | 到 guest Linux 登录提示 |

`fail_regex` 通用包含 panic / kernel panic / SError / login incorrect /
permission denied 等。

---

## 5. 一次完整上板流程（以 Rock 4D 为例）

1. 一次性配置：`cargo xtask board config`，填好 ostool-server 地址。
2. 确认板卡可用：`cargo xtask board ls` 看到 `Rock-4D`。
3. 准备 guest 资产：按第 3 节构建 kernel + 编译 DTB + `scp` 部署 + `sync`。
4. 设置环境变量（串口、电源、TFTP、`BOARD_DTB` 等，见 2.3）。
5. 运行：`cargo xtask axvisor test board --board rock-4d-linux`。
6. 观察：runner 输出 boot banner、Axvisor 启动日志、guest Linux 直到
   `rock-4d-spi login:` 匹配即通过；超时/匹配到 panic 则失败。
7. 失败排查用人工串口：`cargo xtask board connect -b Rock-4D`，手动打断 U-Boot、
   看 hypervisor 日志、检查 guest 内核/DTB 是否部署正确。

---

## 6. 引导链回顾（Rock 4D 为例）

```
U-Boot(板上固件) --tftp image.fit && bootm--> Axvisor(EL2, host DTB)
  --> somehal/rdrive 探测 RK3576 设备
  --> rockchip-dwmmc 驱动拿到 eMMC/SD 块设备
  --> fs feature 挂载板上 ext4 根文件系统
  --> 从 /guest/linux/ 读 guest 内核(0x80200000) + guest DTB(0x80000000)
  --> 卸载 host 文件系统 --> 直通 guest Linux 启动
```

`phys_cpu_ids = [0x102]`（MPIDR 亲和性）把 guest vCPU 固定到物理核；内存区
`[0x80000000, 0x40000000]`（1 GB）。板配置里唯一的 SoC 特定驱动开关是 features：
Rock 4D 用 `ax-driver/rockchip-dwmmc`，Orange Pi 5 Plus 用 `ax-driver/rockchip-sdhci`。

---

## 7. 常见问题

- **QEMU 与板卡数据不可混用**：当前四种 ROCK 4D 组合均已通过功能门禁；QEMU
  TCG 的 host 资源和 timer 长尾仍只能作为仿真数据，不能替代真机实时性上界。
- **`--board evm3588 ...` 报找不到**：EVM3588 没有 board case，也不要用
  `vms/rk3588/linux-smp8.toml` 冒充（其 DTS 是 Firefly ITX-3588J、路径是占位符）。
- **串口无输出 / 停在 rdrive**：确认 `BOARD_DTB` 与板卡固件/内存映射一致；Orange Pi
  的候选 DTB 仍需核对实际固件。
- **`-netdev user` 相关错误**：宿主 QEMU 缺 user 网络后端是 QEMU 侧问题，与板卡无关；
  板卡走 TFTP + 物理网卡，不走 QEMU user 网络。
- **`bootm` 找不到 image.fit**：确认 `TFTP_DIR` 正确、板卡与宿主网卡同网段、
  `BOARD_COMM_NET_IFACE` 选对网卡。
- **测试组名与板型名混淆**：`--board` 是测试组名（`...-linux` / `...-starry`），
  `--board-type` 才是 `Rock-4D` / `OrangePi-5-Plus` 这类硬件服务类型。

---

## 8. 数据真实性要求

上板测得的延迟/稳定性数据不能与 QEMU TCG 数据混为一谈。板级数据才可用于硬件声明；
QEMU 数据只用于功能与相对回归。报告时必须注明宿主、板型、固件/U-Boot 版本、串口
波特率、guest 内核/DTB 版本、以及单 Linux 还是多 guest 拓扑。
