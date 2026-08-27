# Axvisor 三客户机网络实验

这个实验在 QEMU AArch64 中同时启动两个 Linux guest 和一个 Zephyr RTOS
guest。每个 guest 直通一块独立的 `virtio-mmio` 网卡，QEMU 用同一个
`hubport` hub 77 将三块网卡连接到同一个二层网络。guest 间的应用数据严格
通过这三块 `virtio-net-device` 网卡传输，不使用共享内存、IVC、vsock 或
virtio socket。

## 准备

在仓库根目录执行。默认路径会编译仓库内的最小 Zephyr 网络 guest，因此需要
Zephyr 源码树和 AArch64 交叉工具链：

```bash
export ZEPHYR_BASE=/path/to/zephyr
export CROSS_COMPILE=/path/to/aarch64-zephyr-elf-
os/axvisor/scripts/setup_qemu_three_guest_net.sh
```

脚本会拉取 Linux/rootfs 镜像，并编译
`os/axvisor/guests/zephyr-net`。该 guest 使用 Zephyr `qemu_cortex_a53`
板级定义，把 `virtio_mmio2` 作为 `virtio,net`，静态配置为
`192.168.77.13/24`。旧版 GCC 若不识别 `id_aa64isar2_el1`，脚本默认用其
架构编码替换；可以用 `AXVISOR_THREE_GUEST_ZEPHYR_EXTRA_CFLAGS` 覆盖。

也可以直接提供已经构建的镜像：

```bash
export AXVISOR_THREE_GUEST_RTOS_IMAGE=/path/to/zephyr.bin
export AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT=0xa0001114
os/axvisor/scripts/setup_qemu_three_guest_net.sh
```

也可以通过 `AXVISOR_THREE_GUEST_LINUX_IMAGE`、
`AXVISOR_THREE_GUEST_RTOS_IMAGE` 和 `AXVISOR_THREE_GUEST_ROOTFS` 指定本地
文件。直接提供 RTOS `.bin` 时必须同时提供与 ELF 匹配的
`AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT`；该镜像必须启用 virtio-net 和 IPv4。
现有 `qemu_aarch64_freertos` benchmark 没有 TCP/IP 应用，不能作为网络通信
证明。

依赖 `cargo`、QEMU AArch64 和 `dtc`。只检查配置和 QEMU FDT 时无需下载
guest 镜像：

```bash
os/axvisor/scripts/verify_three_guest_net.sh
```

## 启动

setup 脚本会生成三份临时 VM 配置，并打印完整命令。命令等价于：

```bash
cargo xtask axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64-three-guest-net.toml \
  --qemu-config os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml \
  --rootfs tmp/rootfs.img \
  --vmconfigs tmp/vmconfigs/three-guest-net/current/linux-net-1.toml \
  --vmconfigs tmp/vmconfigs/three-guest-net/current/linux-net-2.toml \
  --vmconfigs tmp/vmconfigs/three-guest-net/current/zephyr-net.toml
```

三个 guest 使用不重叠的 type-2 `MapReserved` identity RAM 区间。专用 board
的顶层 `qemu-aarch64-three-guest-net` feature 会在宿主启动早期为本工作负载
预留 `0x80000000..0xb0000000`，因此宿主分配器不会占用这些直通 DMA 可见的
guest RAM；通用 `qemu-aarch64.toml` 不启用该预留。QEMU 的三块网卡固定到
`virtio-mmio-bus.0/1/2`，分别对应 `a000000/a000200/a000400`；不显式指定 bus
时，QEMU 会从高地址槽位反向分配，guest 将访问到空的 virtio-mmio 槽位。

| Guest | RAM | NIC MMIO | MAC | IP |
| --- | --- | --- | --- | --- |
| Linux-1 | `0x80000000..0x90000000` | `0xa000000` | `52:54:00:77:00:01` | `192.168.77.11/24` |
| Linux-2 | `0x90000000..0xa0000000` | `0xa000200` | `52:54:00:77:00:02` | `192.168.77.12/24` |
| Zephyr | `0xa0000000..0xb0000000` | `0xa000400` | `52:54:00:77:00:03` | `192.168.77.13/24` |

Linux guest 的 initramfs 由 setup 脚本从 QEMU rootfs 中提取静态 AArch64
busybox 生成；它们启动后自动配置静态 IP，并在 TCP `8080` 端口提供一个
最小 HTTP 响应。QEMU rootfs 仍然只是 Axvisor 宿主盘，不是 guest 之间的
共享通信通道。

启动前也可以把 QEMU 生成的 host DTB 传给验证脚本：

```bash
os/axvisor/scripts/verify_three_guest_net.sh /path/to/qemu-host.dtb
```

## 网络验证

在 Linux guest 中执行：

```bash
ip link
ip link set dev eth0 up
ip addr add 192.168.77.11/24 dev eth0  # Linux-1
ip addr add 192.168.77.12/24 dev eth0  # Linux-2
ping -c 3 192.168.77.13
```

Zephyr guest 会在启动时由应用静态配置
`192.168.77.13/24`，不提供 POSIX shell。启动日志中的以下结果是 Linux 到
Zephyr 的 ICMP 验证：

```bash
Linux-1 reached Zephyr at 192.168.77.13
Linux-2 reached Zephyr at 192.168.77.13
```

Linux-1 还会启动 HTTP 服务并自动请求 Linux-2 的 `8080` 端口。也可以在
Linux-1 的 shell 中重复验证：

```sh
wget -O - http://192.168.77.12:8080/
```

预期响应为 `linux-net-2`。只有出现实际 ICMP 或 TCP 结果，才能宣称网络
通信已验证；配置检查本身不等价于运行时通信成功。

Linux-to-Linux 的运行时检查可以直接使用 initramfs 中的 busybox：

```sh
ping -c 3 192.168.77.12
wget -O - http://192.168.77.12:8080/
```

## 中断路径说明

三块网卡仍然是独立的 virtio-net MMIO 设备，QEMU hub 77 的 `hubport` 只转发二层
以太网帧。当前实验已验证 DMA、virtio ring 和 Zephyr 的 passthrough SPI
中断路径可以工作。正式构建通过 `AXVISOR_DISABLE_VIRTIO_IRQ_POLL` 禁用
`VIRTIO_MMIO_INTERRUPT_STATUS` 轮询，网络 RX/TX 由真实 virtio SPI 中断和
Zephyr 公共 `virtio_isr()` 处理；这避免了应用线程每 1 ms 被唤醒一次对 RTOS
定时器的干扰。

源码仍保留轮询作为诊断 fallback。只有未定义该 CMake 宏的诊断镜像才会读取
并 ACK `VIRTIO_MMIO_INTERRUPT_STATUS`，因此诊断轮次不能与正式 no-poll 轮次
直接混合比较。

## 限制

这个实验复用 Axvisor 现有 FDT 设备直通，不在 Axvisor 内实现 virtio-net
模拟器或跨 VM 软件交换机。QEMU 的 `hubport` 只负责转发三块独立网卡的
二层帧；guest 间不提供共享内存、IVC、vsock 或 virtio socket 通道。若 RTOS
镜像没有启用 `virtio-net` 和 TCP/IP sample，三 VM 仍可
完成启动配置验证，但网络运行时验证必须记为未完成。
