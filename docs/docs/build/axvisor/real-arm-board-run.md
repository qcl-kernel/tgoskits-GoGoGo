---
sidebar_position: 5
sidebar_label: "真实 ARM 板运行"
---

# 真实 ARM 板运行说明

本文只描述仓库当前可核对的 AArch64 板级 Axvisor 资产。目标 workload 是两个
Linux guest 和一个 RTOS guest，三个 guest 通过网络通信；不使用共享内存、IVC
或 virtio socket。

## 结论先行

当前仓库不能在 Orange Pi 5 Plus、Phytium Pi 或所谓 EVM3588 上直接运行这个三
guest 网络 workload。原因不是缺少一条启动命令，而是板级 VM 配置没有为三个
guest 提供三份相互独立的网络设备和设备树描述：Orange Pi 与 Phytium 的现有
Linux 配置使用物理设备树直通，RTOS 配置没有 virtio-net；EVM3588 则没有
Axvisor board 配置、DTB、VM 配置或测试用例。

因此，下文给出的实体板命令只验证仓库已经维护的单 Linux 启动链路。三 guest
网络命令仍可在 QEMU 中运行，但不能替代真实板验证。

## 板级资产矩阵

| 板型 | 仓库资产 | 当前可运行范围 | 网络结论 |
| --- | --- | --- | --- |
| Orange Pi 5 Plus / RK3588 | `configs/board/orangepi-5-plus.toml`、配套 `orangepi-5-plus.dtb`、Linux VM 与 board/uboot 单 Linux 测试 | 单 Linux | Linux guest DTS 有 RK3588 GMAC，但 VM TOML 没有 virtio-net；RTOS VM 是占位镜像/非网络配置 |
| Phytium Pi | `configs/board/phytiumpi.toml`、Linux/RTOS VM 与单 Linux board/uboot 测试 | 单 Linux | Linux guest DTS 有 4 个以太网节点；RTOS DTS 没有以太网或 virtio-net，RTOS 镜像路径仍是占位符 |
| RK3588 generic | `configs/vms/rk3588/linux-smp8.toml` 与 Firefly ITX-3588J DTS | 不能据此声明 EVM3588 支持 | 文件中的 `model` 是 Firefly ITX-3588J，不是 EVM3588；镜像和 DTB 是 `/path/to/...` 占位路径，也没有 virtio-net |
| EVM3588 | README 中只有板型条目 | 不可运行 | `configs/board`、EVM DTB、EVM VM 配置和 `test-suit/axvisor` board case 均不存在 |

## 真实板前置条件

实体板启动需要下列外部条件；它们不由本仓库的 board TOML 自动提供：

1. 对应的真实板卡、可复位/断电的电源控制、U-Boot、串口设备和正确的串口波特率。
2. `ostool-server` 或仓库测试框架配置的远程板卡服务。`test board` 的 `--board`
   是测试组名，硬件服务类型使用 `--board-type`，不要把二者混用。
3. 可访问板卡的 TFTP/网络接口，以及 `BOARD_DTB`、`BOARD_COMM_UART_DEV`、
   `BOARD_COMM_UART_BAUD`、`BOARD_POWER_OFF`、`BOARD_POWER_RESET`、
   `BOARD_COMM_NET_IFACE`、`TFTP_DIR` 环境变量。
4. 与板卡固件和内存映射匹配的 host DTB。`BOARD_DTB` 是 U-Boot/host 使用的
   DTB，不是 guest DTB。Orange Pi 的 `configs/board/orangepi-5-plus.dtb`
   可以作为仓库内候选文件，但仍需确认它与实际板卡固件、内存容量和启动地址一致；
   Phytium Pi 没有仓库内 board DTB，必须提供板卡或外部镜像中的 DTB。
5. 单 Linux 启动所需的 guest kernel、initramfs/rootfs 镜像。`/guest/...` 是
   测试环境中的文件系统路径，不是本机自动存在的文件。
6. 若要做三 guest 网络测试，还需要两个 Linux 镜像、一个带网络驱动和 IPv4/TCP-IP
   栈的 RTOS 镜像、三个匹配的 guest DTB，以及三份独占的网络设备/IRQ/DMA 所有权。
   当前仓库没有这一整套实体板资产。

## 已有实体板命令

以下命令是仓库当前发现的单 Linux 入口，必须在具备上述远程板卡服务的环境中执行。
它们不能启动两个 Linux 和一个 RTOS：

```bash
# 通过 U-Boot 启动单 Linux guest
cargo xtask axvisor test uboot --board orangepi-5-plus --guest linux
cargo xtask axvisor test uboot --board phytiumpi --guest linux

# 运行已有远程板卡 smoke 测试
cargo xtask axvisor test board --board orangepi-5-plus-linux
cargo xtask axvisor test board --board phytiumpi-linux
```

在没有默认测试服务时，先确认仓库实际发现到的名称：

```bash
cargo xtask axvisor config ls
cargo xtask axvisor test board --list
cargo xtask axvisor test uboot --help
```

不能把 `cargo xtask axvisor test uboot --board evm3588 ...` 当作可运行命令：当前
没有该 board case。也不能直接使用 `configs/vms/rk3588/linux-smp8.toml` 冒充
EVM3588 配置，因为它的 guest DTB 明确标注为 Firefly ITX-3588J，且镜像路径是
占位路径。

## DTB、内存和设备所有权限制

Axvisor 的 DTB 规则决定了这几份配置的实际含义：VM TOML 指定 `dtb_path` 时使用
预定义 guest DTB；没有 `dtb_path` 时动态生成 DTB。动态生成时
`passthrough_devices` 和 `excluded_devices` 才参与设备筛选；若写
`passthrough_devices = [["/"]]`，根节点及其依赖设备会被直通。

### Orange Pi 5 Plus

现有 Linux VM（`orangepi-5-plus/linux-smp1.toml`）的关键地址是：

```text
DTB       0x240000000
kernel    0x240080000
ramdisk   0xc0000000
RAM       0x240000000 + 0x80000000，MAP_IDENTICAL
保留区    0xb0000000 + 0x10000000，以及 0xc0000000 + 0x30000000
```

其参考 guest DTS 包含 `/ethernet@fe1b0000` 和 `/ethernet@fe1c0000`，但 VM TOML
没有 `virtio-mmio`/`virtio-net` 设备，且使用 `passthrough_devices = [["/"]]`。
这表示 Linux 可以尝试独占物理 GMAC；它不表示 Axvisor 创建了可供多个 guest
共享的虚拟网卡。

现有 `zephyr.toml`/`freertos-smp1.toml` 使用 `0x40000000 + 0x30000000` 的
RTOS 内存区和占位/内存加载镜像，配置中同样没有 virtio-net。现有 guest id 也
都是 `1`，并且部分 physical CPU id 与 Linux 重复；它们不能直接作为三个 guest
配置同时启动。三 guest 方案必须重新分配唯一 VM id、非重叠 RAM、非重复 vCPU
绑定和独占设备/IRQ。

### Phytium Pi

现有 Linux VM（`phytiumpi/linux-smp1.toml`）的关键地址是：

```text
DTB       0x2040000000
kernel    0x2040080000
RAM       0x2040000000 + 0x40000000，MAP_IDENTICAL（1 GiB）
```

Linux 参考 DTS 描述 `/soc/ethernet@3200c000`、`@3200e000`、`@32010000` 和
`@32012000`。但 Linux VM 仍是根设备树直通；同一个物理 MAC、IRQ、DMA 缓冲区
不能同时交给两个 guest。`zephyr-smp1.dts` 只有 UART/GIC/timer/SRAM，没有
以太网或 virtio-net 节点；`zephyr-smp1.toml` 的镜像路径为
`/path/to/zephyr-phytiumpi.bin`。

### RK3588 generic 与 EVM3588

`rk3588/linux-smp8.toml` 使用 `0x09400000 + 0xd5500000` 的 3 GiB 级物理 RAM
窗口、8 个 vCPU 和一组物理地址直通，kernel/DTB 分别是 `/path/to/kernel` 和
`/path/to/dtb`。其 DTS 的 `model` 是 Firefly ITX-3588J HDMI，不是 EVM3588。
它没有三 guest 所需的 virtio-net 拓扑，也没有 EVM3588 的启动链路可供核对。

## 为什么当前实体板不能完成三 guest 网络 workload

QEMU 实验可以由 host 创建三块 `virtio-net-device`，再用同一个 `hubport` 转发
二层帧；实体板当前的 Axvisor 配置没有等价的 host 虚拟交换机或 virtio-net 后端。
把物理 GMAC 整棵设备树直通给多个 guest 会造成设备、IRQ 和 DMA 所有权冲突，不能
作为网络隔离方案。即使 Orange Pi 有两个 GMAC，或 Phytium DTS 描述四个 GMAC，
也仍需为每个 guest 准备独占的硬件、物理交换机/线缆和匹配 guest DTS/驱动；当前
RTOS DTS 和 VM 配置没有做到这一点。

要形成可执行的实体板方案，至少还缺：

- 已确认型号和端口映射的实体板 DTB，以及三 guest 的不重叠内存和 vCPU/IRQ 分配；
- Axvisor 支持的三份网络设备 ownership 配置，或板级 virtio-net/虚拟交换机后端；
- 两个 Linux guest 的网络 DTB/驱动配置；
- 一个实际构建的 RTOS 网络镜像、入口点、内存布局和网络 DTB/驱动；
- 若采用物理 GMAC，足够的独立 MAC 控制器、PHY、交换机端口和可验证的线缆拓扑。

这些缺失项涉及配置源码、设备直通/虚拟设备实现和外部硬件镜像；本次文档任务
不修改它们，因此不能给出伪装成实体板可运行的三 guest 命令。

## Same-board bare-metal acceptance preflight

记录日期为 `2026-08-05`，目标为 `board=orangepi-5-plus`。在当前没有设置任何
`AXVISOR_RT_*` 变量的环境中，从仓库根目录执行的精确命令是：

```bash
bash docs/docs/build/axvisor/check_real_arm_board_docs.sh   --realtime-preflight orangepi-5-plus   >/tmp/axvisor-orangepi-5-plus-realtime-preflight-after.log 2>&1
```

checker 退出码为 `1`。`/tmp/axvisor-orangepi-5-plus-realtime-preflight-after.log`
的精确输出为：

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

这 16 个缺失 input 是当前 Orange Pi 5 Plus same-board acceptance 的外部硬件和
资产阻塞清单。仓库中已 checked-in 的 Orange Pi 5 Plus 资产只有单 Linux 链路及
不能组合成该 workload 的 RTOS 配置，不能运行要求的两个 Linux 加 Zephyr 网络
负载。preflight 不会发现或回退到 QEMU artifact，也不允许以虚拟板代替实体板。
iteration 146 是 x86_64 host 上的 AArch64 QEMU TCG 筛选，不是 same-board 或
bare-metal-level 证据。

批准阈值保持不变：每次 Axvisor run 都必须完成 full callback/network，且
`>1 ms` miss 为 `0`；p99.9 和 p99.99 相对 bare metal 的差值都必须在
`max(25%, 10 us)` 以内，maximum 必须不超过
`max(2 x bare-metal maximum, 50 us)`。Axvisor 与 bare-metal 配对运行必须使用
相同 RTOS binary options、tick、counter、governor 和 traffic，并完成三次配对
重复。通过资产 preflight 只允许开始测量，不等于通过这些批准阈值。

本次没有真实测量，因此没有修改 CSV/PNG。当前结论是外部硬件/资产 `BLOCKED`，
不是实时性优化完成。

## QEMU 对照命令（不是实体板命令）

仓库已有的三 guest 网络拓扑可用于验证 workload 本身：

```bash
cargo xtask axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64.toml \
  --qemu-config os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml \
  --rootfs tmp/rootfs.img \
  --vmconfigs tmp/vmconfigs/three-guest-net/linux-net-1.toml \
  --vmconfigs tmp/vmconfigs/three-guest-net/linux-net-2.toml \
  --vmconfigs tmp/vmconfigs/three-guest-net/zephyr-net.toml
```

该命令依赖文档 [三客户机网络实验](./three-guest-network)，并且 QEMU TOML 明确
创建 `virtio-mmio-bus.0/.1/.2` 三块网卡。它证明的是 QEMU 虚拟网络拓扑，不证明
任何实体 ARM 板的 GMAC 直通或实时性。

## 静态检查

从仓库根目录执行：

```bash
docs/docs/build/axvisor/check_real_arm_board_docs.sh
bash docs/docs/build/axvisor/check_real_arm_board_docs.sh --realtime-preflight orangepi-5-plus
git diff --check
```

无参数模式只读取配置和文档，验证板型文件、单 Linux 测试组、DTB/内存/直通事实、
QEMU 三网卡对照以及 EVM3588 缺失结论。`--realtime-preflight` 还会核对显式外部
文件、可执行控制程序、网络设备/IRQ/traffic peer，要求三份 VM 配置路径、网络
设备和 IRQ 分别唯一，并使用 Python `tomllib` 验证 VM id 唯一、每份
`base.phys_cpu_ids` 显式非空且三份互不重叠。两种模式都不会启动板卡、下载镜像
或修改工作树。
