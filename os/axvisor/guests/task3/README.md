# QEMU Linux/RT-Thread 图像识别控制闭环

本仓库在两个 AArch64 QEMU `virt` 客户机中实现任务 3：Linux 读取确定性 Y4M 图像、执行 int8 CNN 推理，并通过 RT-IPC over UDP/IP 向 RT-Thread 发送分类结果；RT-Thread 更新虚拟 PWM 和转向位置并回传状态。主数据通道只使用 virtio-net 和 IPv4/UDP，不使用共享内存、HyperCall、裸 MMIO 或 vsock。

本目录保留的运行结果属于导入前的**双 QEMU 迁移基线**，用于审计模型、协议和控制算法，不属于 AxVisor 最终证据。集成后的最终证据必须从仓库根目录运行 `os/axvisor/scripts/run_task123.sh` 采集，不能由本目录的 standalone 启动器生成。

## 版本与分支

复现分支为 `feat/task3-ai-control`。运行前记录实际提交，报告和日志必须与该提交一起保存：

```sh
git switch feat/task3-ai-control
git rev-parse HEAD
git status --short
```

依赖由 `configs/dependencies.lock` 固定：

- RT-Thread 5.2.2，提交 `ddf52e2cdd977f14fc04035c88672ac204aec713`
- Buildroot 2025.02.1，提交 `3815d578c5759fa824322ea3d95ad51b55ab888e`
- Arm GNU Toolchain `14.2.Rel1`，下载包用 SHA-256 校验
- Kconfiglib 14.1.0
- QEMU >= 8.2，已验证 QEMU 11.0.2
- Python 3、NumPy、Git、Make、SCons、curl、tar 和 xz
- 上级工作区 `protocol/c` 中的 RT-IPC 头文件与源码按锁文件 SHA-256 校验

## 一次性复现

在 `qemu-task3` 目录依次执行：

```sh
make doctor
make model
make test
make images
./scripts/build_rtthread.sh --fault-drop-status-once
make demo
make fault-test
make report
sh tests/test_docs_contract.sh
```

`make model` 用固定种子生成 32x32 灰度图像、训练 TinyCNN，并导出 int8 权重和 32 个 C/Python golden vectors。网络结构是 3x3 Conv(1->4)、ReLU、2x2 max-pool、3x3 Conv(4->8)、ReLU、空间池化和 24->3 全连接，输出 LEFT/CENTER/RIGHT。导出的模型头文件包含内容 SHA-256；测试要求浮点和量化准确率均至少 95%，且 C 推理逐向量等价。

`make images` 生成：

```text
build/images/linux/Image
build/images/linux/rootfs.cpio
build/images/rtthread/rtthread.bin
build/images/rtthread/rtthread.elf
build/images/rtthread/rtthread-drop-status.bin
```

构建脚本使用精确 detached Git 提交、校验后的工具链，并验证 RT-Thread ELF 入口地址、`task3_server_start` 和 `rt_virtio_net_init` 符号。正常镜像与丢 STATUS 故障镜像不会互相覆盖。

## 客户机与网络

启动器使用以下等价命令，实际绝对路径和 multicast 端口写入每次运行的 `commands.txt`：

```sh
qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a53 \
  -smp 1 -m 128M -kernel build/images/rtthread/rtthread.bin \
  -netdev socket,id=net0,mcast=230.77.0.1:10077 \
  -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:30 \
  -nographic -no-reboot

qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a53 \
  -smp 2 -m 256M -kernel build/images/linux/Image \
  -initrd build/images/linux/rootfs.cpio \
  -append "console=ttyAMA0 rdinit=/sbin/init task3.frames=600" \
  -netdev socket,id=net0,mcast=230.77.0.1:10077 \
  -device virtio-net-device,netdev=net0,mac=52:54:00:77:00:11 \
  -nographic -no-reboot
```

| 客户机 | vCPU | 内存 | MAC | IPv4 | 工作 |
|---|---:|---:|---|---|---|
| Linux | 2 | 256 MiB | `52:54:00:77:00:11` | `192.168.77.11/24` | Y4M、CNN、RT-IPC 客户端、采集 |
| RT-Thread | 1 | 128 MiB | `52:54:00:77:00:30` | `192.168.77.30/24` | UDP/9876、协议、PWM/转向控制 |

两端在同一 QEMU multicast socket LAN，使用 `/24` 直连路由，无默认网关。无 NAT、无宿主 tap/bridge、无端口转发；测试网络不配置客户机防火墙或访问控制，隔离边界是仅宿主可加入的 multicast UDP 组。应用服务监听 RT-Thread `0.0.0.0:9876`，Linux 只接受来自 `192.168.77.30:9876` 的回复。

QEMU TCG 的 vCPU 是宿主线程，本方案没有把它们绑定到特定物理 CPU。CPU 负载分工是：Linux 两个 vCPU 承担推理、网络和串口采集，RT-Thread 单 vCPU 承担 virtio 网络中断、lwIP/RT-IPC 和控制更新。宿主调度、TCG、虚拟中断和串口输出都会影响延迟，因此结果用于功能闭环和同平台对比，不等同于物理硬实时上界。

## 正常评测

```sh
./scripts/run_demo.sh --frames 600 --multicast-port 10077
```

输入为 10 FPS。FIXED 与 AI 各运行 600 帧、各 60 秒，总有效运行时长 120 秒。FIXED 始终采用 CENTER 控制，AI 使用 CNN 分类和 Q15 置信度。门禁为请求成功率 >=99.5%、AI 分类准确率 >=95%、AI 平均跟踪误差相对 FIXED 改善 >=30%。

每次结果位于 `build/runs/<UTC>-normal-<pid>/`：

- `frames.csv`：1200 条逐帧原始记录
- `summary.raw.json`：Linux 客户机直接输出
- `summary.json`：宿主严格重算的延迟、准确率、吞吐量和可靠性指标
- `linux.log`、`rtthread.log`：两侧完整串口证据
- `commands.txt`、`versions.txt`：实际命令和工具版本

最终采用的原始证据另存于 `docs/results/evidence/normal/`；故障证据位于 `docs/results/evidence/faults/`。这些目录受 Git 跟踪，包含逐帧 CSV、完整两侧日志、命令、Git 状态、镜像/模型/RT-IPC 哈希及派生 JSON，因此全新检出无需访问作者机器的 `build/` 目录即可审计报告。

Linux 使用 `CLOCK_MONOTONIC_RAW` 做同侧发送到回包 RTT 计时，避免未同步客户机时钟造成单向延迟偏差；RT-Thread 用 AArch64 通用计数器记录控制处理耗时。CSV 时间单位为微秒，源计数器分辨率更高，但报告精度受 TCG 调度和虚拟中断限制。

## 故障与恢复

先生成故障镜像，再运行：

```sh
./scripts/build_rtthread.sh --fault-drop-status-once
./scripts/run_faults.sh --frames 3 --multicast-port-base 10120
```

五个真实双 QEMU case 是 `drop-control`、`drop-status`、`duplicate-frame`、`delayed-server` 和 `malformed`。它们分别验证客户端重传、服务端重传、frame 幂等、断连重连、错误 schema/长度通知以及 CRC 丢弃。每个 case 位于 `build/fault-runs/<UTC>-<pid>/<case>/`，总结果是同目录的 `fault-summary.json` 和 `fault-events.csv`。

`scripts/run_demo.sh` 只记录并终止自己启动的 QEMU 自有 PID，不使用 `pkill` 或 `killall`；正常成功时 Linux 客户机自行关机，宿主 trap 负责异常、信号和残留 RT-Thread QEMU 的清理。不同并发运行必须选择不同 multicast 端口范围。

## 报告与排错

```sh
./scripts/render_report.py \
  build/runs/<normal-run> \
  --fault-summary build/fault-runs/<fault-run>/fault-summary.json \
  --output docs/results/task3-report.md
```

若 `doctor` 失败，先根据缺失命令安装宿主依赖；Arm 裸机工具链由脚本下载并校验。若出现端口串扰，改用未占用的 `--multicast-port` 或 `--multicast-port-base`。若运行中断，保留对应运行目录中的串口日志；摘要生成器会拒绝缺帧、重复帧、列不匹配、缺少最终标记或未通过门禁的数据。

应用协议、消息字段和重试边界见 `docs/protocol.md`，本次实测结果见 `docs/results/task3-report.md`。
