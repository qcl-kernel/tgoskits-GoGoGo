# QEMU Linux/RT-Thread AI 循迹控制设计

## 1. 目标与范围

本工程在两个独立的 AArch64 QEMU 虚拟机中运行 Linux 和 RT-Thread，完成一条可复现的视觉循迹控制链路：Linux 从 Y4M 视频读取图像，执行神经网络推理，通过 RT-IPC/UDP 向 RT-Thread 发送模型输出；RT-Thread 根据输出调整虚拟转向 PWM 和执行器位置，再将状态返回 Linux。工程同时运行固定居中参数基线与 AI 控制，量化识别准确率、跟踪误差、稳定时间、推理耗时和端到端闭环延迟。

工作区是独立 Git 仓库 `qemu-task3/`，开发分支为 `feat/task3-ai-control`。工程复用相邻 `protocol/c` 中的 RT-IPC C 实现，但不修改 `tgoskits` 当前工作树。

### 1.1 成功条件

- Linux 和 RT-Thread 分别由独立的 `qemu-system-aarch64` 进程启动并通过 IP 网络双向通信。
- Linux 客户机实际执行两层卷积神经网络的定点推理，不使用类别规则替代推理。
- RT-Thread 仅根据收到的模型类别、置信度和自身执行器状态计算控制动作；视频真值不发送给 RT-Thread。
- 600 帧正式运行的请求成功率不低于 99.5%，正常场景应用层错误数为 0。
- 测试视频分类准确率不低于 95%。
- AI 模式的平均跟踪误差比固定参数基线至少低 30%。
- 确定性丢包测试中不重复应用控制动作，并在 RT-IPC 最大重试窗口内恢复。
- 真实运行生成逐帧 CSV、摘要 JSON、两侧串口日志和中文报告；仓库不包含伪造结果。

### 1.2 非目标

- 本工程不在 AxVisor 内运行客户机，不验证 AxVisor 调度或实时性改造。
- 不使用摄像头透传、视频编解码器、GPU/NPU 或通用 AI 运行时。
- 不使用共享内存、HyperCall、裸 MMIO 或 vsock 传递主要数据。
- 虚拟执行器用于可量化演示，不代表真实车辆动力学或功能安全控制器。

## 2. 系统架构

宿主机负责生成模型、视频和客户机镜像，启动两个 QEMU 进程，并从串口日志提取结果。客户机之间不存在宿主应用代理，应用数据直接经过两张 virtio-net 网卡和 QEMU multicast socket 二层网段。

```text
Host
  model/train.py -> int8 weights -> Linux initramfs
  model/generate_video.py -> Y4M + truth CSV -> Linux initramfs
  scripts/run_demo.sh -> QEMU Linux + QEMU RT-Thread -> logs/results

QEMU Linux (2 vCPU, 256 MiB)
  Y4M reader -> int8 CNN -> RT-IPC client -> metrics/report records
                                      | UDP/9876
QEMU RT-Thread (1 vCPU, 128 MiB)       |
  RT-IPC server -> controller -> virtual actuator -> status reply
```

### 2.1 固定资源

| 项目 | Linux | RT-Thread |
| --- | --- | --- |
| QEMU machine | `virt,gic-version=2` | `virt,gic-version=2` |
| CPU | `cortex-a53`, 2 vCPU | `cortex-a53`, 1 vCPU |
| 内存 | 256 MiB | 128 MiB |
| 网卡 | virtio-net-device | virtio-net-device |
| MAC | `52:54:00:77:00:11` | `52:54:00:77:00:30` |
| IPv4 | `192.168.77.11/24` | `192.168.77.30/24` |
| UDP 端口 | 动态客户端端口 | `9876` |

两个 QEMU 进程使用相同的 `-netdev socket,mcast=230.77.0.1:10077`。该网段无默认路由、NAT 或宿主转发；客户机只允许实验子网内的 RT-IPC UDP 流量。multicast 组和端口可通过启动脚本参数修改，以避免并行运行冲突。

### 2.2 版本边界

- RT-Thread 固定为官方 `v5.2.2`。
- Linux 镜像由 Buildroot `2025.02.1` 的固定 defconfig 生成。
- QEMU 最低支持版本为 8.2；实际运行记录完整版本字符串。
- 模型生成仅依赖 Python 3 和 NumPy，固定随机种子与 NumPy 版本记录在结果中。
- `protocol/c/include/rt_ipc.h` 和 `protocol/c/src/rt_ipc.c` 是 RT-IPC C 参考源。构建前对文件计算 SHA-256 并记录；Linux 和 RT-Thread 必须编译同一份源文件。

## 3. 图像与神经网络

### 3.1 输入视频

输入是 `YUV4MPEG2` 灰度视频，尺寸为 32x32、帧率为 10 FPS。生成器用固定种子绘制具有横向偏移、宽度变化、亮度变化、传感噪声和轻微遮挡的循迹线。正式测试视频为 600 帧，训练样本与测试视频使用不同种子。测试视频同时生成真值 CSV，字段为 `frame_id,target_q15,class`；真值仅供 Linux 结果计算，不进入 RT-IPC 载荷。

Y4M 避免引入编解码库，同时保留逐帧视频输入语义。Linux 读取每个 `FRAME` 后的 Y 平面，拒绝错误尺寸、截断帧或不支持的色度格式。

### 3.2 CNN 结构

模型输入为 32x32 的无符号灰度像素，输出为 `LEFT`、`CENTER`、`RIGHT` 三类：

1. `Conv2D(1, 4, 3x3)`、ReLU、`MaxPool(2x2)`；
2. `Conv2D(4, 8, 3x3)`、ReLU；
3. 将特征图按左、中、右三个纵向区域分别平均，得到 24 个保留横向位置的信息；
4. `Dense(24, 3)`，取最大 logit 为类别，并将 logit margin 映射为 Q15 置信度。

不采用覆盖整张特征图的全局平均池化，因为该操作会消除循迹分类所依赖的横向平移信息，使左偏与右偏在卷积特征上不可可靠区分。

训练采用 NumPy 实现的前向与反向传播，固定初始化种子、批次顺序和训练轮数。导出器为每层生成对称 int8 权重、int32 bias 和显式缩放参数。Linux C 推理器使用 int8 激活、int8 权重和 int32 累加，所有饱和与舍入规则在公共模型格式中定义。

模型验证包含三道门禁：Python 浮点测试准确率、Python 定点参考准确率，以及至少 32 个黄金样本上的 Python 定点/C 推理类别和 logit 完全一致。

## 4. 控制闭环

RT-Thread 保存有符号 Q15 执行器位置，范围为 `[-32767, 32767]`。模型类别映射到目标位置：`LEFT=-20000`、`CENTER=0`、`RIGHT=20000`。RT-Thread 的比例控制器根据目标位置与当前位置之差计算 `[-1000, 1000]` 范围内的 PWM，并按固定离散模型推进执行器位置。位置、PWM 和控制周期均输出到状态回传和串口日志。

正式评估使用完全相同的视频按以下顺序运行：

1. `RESET + FIXED`：重置执行器和协议统计，目标位置恒为 0；
2. 固定模式运行 600 帧；
3. `RESET + AI`：再次重置到相同初始状态；
4. AI 模式运行同一 600 帧，目标位置来自 CNN 类别。

Linux 用视频真值位置与 RT-Thread 回传位置计算绝对跟踪误差。方向变化后，执行器连续三个状态落入目标附近的 Q15 误差带即视为稳定。RT-Thread 通过 `frame_id` 维护最近已应用命令和缓存状态回复；收到重传或重复帧时重发原状态，但不得再次推进执行器。

## 5. 应用层协议

底层沿用 RT-IPC v1 的 12 字节网络序报头：协议版本、消息类型、载荷长度、序号、错误码和 CRC16。RT-IPC 提供 SYN/SYNACK、ACK、发送窗口、RTO 重传、重复与乱序处理、心跳和自动重连。任务三只在 `CTRL_CMD`、`STATUS_REP`、`ERROR_NOTIFY` 内定义版本化载荷，所有多字节字段使用网络字节序并由显式编解码函数访问，禁止直接发送 C 结构体内存。

### 5.1 `CTRL_CMD v1`，24 字节

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | schema version，固定 1 |
| 1 | u8 | command：RESET、STEP 或 STOP |
| 2 | u8 | mode：FIXED 或 AI |
| 3 | u8 | class：LEFT、CENTER、RIGHT 或 UNKNOWN |
| 4 | u16 | confidence Q15 |
| 6 | u16 | flags，v1 固定 0 |
| 8 | u32 | frame id |
| 12 | u64 | Linux `CLOCK_MONOTONIC_RAW` 发送时间 ns |
| 20 | u32 | 保留字段，v1 固定 0 |

### 5.2 `STATUS_REP v1`，24 字节

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | schema version，固定 1 |
| 1 | u8 | status code |
| 2 | u8 | applied class |
| 3 | u8 | flags，包含 duplicate 标志 |
| 4 | u32 | frame id |
| 8 | i16 | applied PWM |
| 10 | i16 | actuator position Q15 |
| 12 | u32 | RT-Thread 处理耗时 us |
| 16 | u64 | 原样回显 Linux 发送时间 ns |

### 5.3 `ERROR_NOTIFY v1`，12 字节

| 偏移 | 类型 | 字段 |
| --- | --- | --- |
| 0 | u8 | schema version，固定 1 |
| 1 | u8 | error category |
| 2 | u16 | application error code |
| 4 | u32 | 关联 frame id |
| 8 | u32 | 诊断参数 |

未知 schema、命令、模式或类别产生 `ERROR_NOTIFY`，且不得改变执行器。CRC 错误、短于 RT-IPC 报头的数据报和无法可信解析的长度错误被丢弃并计入协议统计，因为此时不能可靠地回复对端。

## 6. 可靠性与异常恢复

应用配置 RT-IPC RTO 为 50 ms、最大重试 5 次、心跳间隔 1 s、心跳超时 5 s，并启用指数退避重连。Linux 每帧只允许一个未完成的控制事务；500 ms 内未获得对应状态即记录应用超时并触发重连，重连后使用相同 `frame_id` 重发该 STEP。RT-Thread 的应用层帧缓存保证该恢复路径只返回原状态而不再次推进执行器。STOP 尽力发送，不作为数据完整性的前提。

故障测试通过传输适配层按确定序号丢弃数据报，不修改 RT-IPC 核心：

- 丢弃 Linux 的指定首发 CTRL_CMD，确认 RTO 重传后只应用一次；
- 丢弃 RT-Thread 的指定首发 STATUS_REP，确认 RT-IPC 重传状态后事务完成；
- 完成 STEP 后用新的 RT-IPC 序号重发相同 `frame_id`，确认应用层返回缓存状态且不重复推进执行器；
- Linux 先启动、RT-Thread 延迟 3 秒启动，确认握手重试成功；
- 完成一段事务后重启 Linux 应用，确认建立新会话并通过 RESET 恢复；
- 注入错误 schema、长度和 CRC，确认错误处理及控制状态不变。

故障运行单独输出结果，不与正常场景的性能数据混合。

## 7. 测量与结果

Linux 使用 `clock_gettime(CLOCK_MONOTONIC_RAW)` 测量推理和同侧往返闭环延迟。每个 STATUS_REP 回显发送时间戳，Linux 以接收时间减去回显值获得从发送控制命令到收到执行状态的闭环时间。RT-Thread 使用架构高精度计数器测量从完整命令交付到状态构造完成的处理耗时并回传。

由于两侧时钟未同步，报告不提供伪精确的单向延迟。`闭环延迟 - RTOS 处理耗时` 仅作为网络与排队的估计值。报告记录 Linux 时钟分辨率、RT-Thread 计数器频率、QEMU 版本和宿主负载。主要误差来源是 QEMU TCG 调度、串口输出、虚拟时钟推进差异和计数器量化。

逐帧 CSV 至少包含模式、帧号、真值、预测类别、置信度、推理耗时、重试数、RTOS 状态、PWM、执行器位置、RTOS 处理耗时、闭环延迟和错误码。摘要 JSON 包含：

- 分类准确率与混淆矩阵；
- 请求数、成功数、应用错误、超时、重传、重复包、重连和成功率；
- 推理和闭环延迟的 min、mean、p50、p95、p99、max；
- 平均、p95 和最大跟踪误差；
- 方向变化次数、稳定成功次数和平均/最大稳定时间；
- 有效应用吞吐量，按成功 STEP 载荷字节除以有效运行时间计算。

## 8. 工程布局与复现接口

```text
qemu-task3/
├── configs/
├── model/
├── src/common/
├── src/linux/
├── src/rtthread/
├── patches/rtthread/
├── scripts/
├── tests/
├── docs/superpowers/specs/
├── docs/results/
├── Makefile
└── README.md
```

生成物统一放在忽略提交的 `build/`。`make doctor` 检查 QEMU、交叉编译器、Python/NumPy、Git、Make、SCons 及网络端口；`make model` 训练并验证模型、生成视频；`make images` 获取固定源码并生成 Linux initramfs 和 RT-Thread 镜像；`make test` 执行主机单元测试和黄金向量；`make demo` 运行 60 秒固定基线和 60 秒 AI 模式；`make fault-test` 执行独立故障场景；`make report` 只从已有真实日志和 CSV 生成报告，缺少或不完整数据时失败。

启动脚本使用临时运行目录、PID 文件和 shell trap。它先启动 RT-Thread，等待串口出现网络和服务就绪标记，再启动 Linux；总流程有明确超时，成功、失败或信号中断时都终止本次创建的两个 QEMU 进程。脚本不使用宽泛的 `pkill`，也不操作宿主桥接、防火墙或路由。

## 9. 测试策略

### 9.1 主机单元测试

- 三种载荷的编解码、网络序、边界值和非法输入；
- RT-IPC 官方 C 实现的现有协议与 loopback 测试；
- Y4M 头、逐帧读取、截断和错误格式；
- CNN 算子饱和、舍入、黄金向量和分类准确率；
- 控制器限幅、状态推进、RESET、重复帧幂等和错误不改状态；
- CSV/JSON 汇总、分位数、稳定时间和验收门禁。

### 9.2 双 QEMU 集成测试

- ARP/IP 连通和 RT-IPC 握手；
- RESET、STEP、STATUS 和 STOP 正常流程；
- 600 帧固定模式与 600 帧 AI 模式；
- 请求成功率、准确率和控制改善门禁；
- 首发命令丢失、首发回复丢失、延迟启动、应用重启和畸形包。

集成测试保留 Linux 与 RT-Thread 原始串口日志。测试门禁从机器可读摘要判断成败；README 和中文结果报告引用同一摘要，避免人工转录不一致。

## 10. 风险与约束

- QEMU multicast socket 依赖宿主允许本地 UDP multicast；`make doctor` 会在启动前验证并给出 socket 单播后备诊断，但正式拓扑保持 multicast。
- Buildroot 全量首次构建耗时较长；下载目录可缓存，但输出镜像必须由固定配置重建。
- TCG 延迟不代表真实硬件最坏情况，报告只描述该次宿主和 QEMU 环境。
- 合成 Y4M 视频用于可重复控制实验，识别准确率不能外推到真实道路图像。
- RT-IPC C 源是共享依赖；摘要变化会使构建立即失败，必须显式更新锁定摘要和兼容性测试后才能接受新版。
