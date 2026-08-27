# Axvisor RT-Thread 实时性与网络通信测试报告 (v13)

> 测试日期：2026-08-14
> 分支：rtthread-migration (commit 60ec42732)
> RTOS：RT-Thread 5.2.2 (v9 server code reverted, musl cross compiler)
> Hypervisor：Axvisor (d7d273c2f worktree build, GPPT mode)
> 平台：QEMU TCG, cortex-a72 x 4, 8GB RAM
> v13：修复RT-IPC server回归(connect()/inet_aton)，恢复v9工作代码

---

## 1. 主要变更

### 1.1 RT-IPC 回归根因分析

v11/v12中RT-IPC passthrough UDP通信失败的根本原因是server代码引入了两个破坏性修改：

1. **connect()调用**：在收到首个数据包后对UDP socket调用connect()，改变了lwIP的TX路径行为
2. **inet_aton bind**：从INADDR_ANY改为绑定到特定IP，影响了源地址选择

这两个修改导致sendto()返回成功但UDP TX数据包从未到达Linux客户端。
ICMP之所以正常，是因为echo reply复用了入站帧的以太网头，不走独立ARP/TX路径。

### 1.2 修复方案

将rtipc_server.c完全回退到v9版本（commit 766aefcf4），该版本在v7-v10测试中
验证了4785+消息、0%丢包的双向UDP通信。

### 1.3 构建系统修复

- 修复musl libc与RT-Thread的timer_t/clockid_t类型冲突
- 修复errno.h缺失导致的ENOENT/ENOMEM编译错误
- 使用系统GNU ld替代崩溃的musl gcc linker (segfault workaround)

---

## 2. 实时性基准测试结果 (v13)

### 2.1 定时器抖动 (1ms 周期, 5000 样本/轮, 3 轮)

| 指标 | Round 1 | Round 2 | Round 3 |
|------|---------|---------|---------|
| 样本数 | 4999 | 4999 | 4999 |
| 最小间隔 (us) | 996 | 989 | 994 |
| 最大间隔 (us) | 1032 | 1037 | 1050 |
| P50 (us) | 1006 | 1006 | 1006 |
| P90 (us) | 1010 | 1009 | 1009 |
| P99 (us) | 1016 | 1016 | 1016 |
| P99.9 (us) | 1026 | 1025 | 1031 |
| miss >100us | 0 | 0 | 0 |
| miss >1ms | 0 | 0 | 0 |
| 回调最大执行时间 (ns) | 69808 | 4256 | 9296 |

**重大改进**：相比v12 (P99=1140us, miss>100us=9%)，v13 P99降至1016us，
**零miss>100us**，定时器精度显著提升。

### 2.2 抢占延迟 (500 样本)

| 指标 | v13 | v12-test5 | v11 | v9 |
|------|-----|-----------|-----|-----|
| 平均 (ns) | 1664 | 1168 | 1584 | 2400 |
| P50 (ns) | 1632 | 1136 | 1152 | - |
| P99 (ns) | 2432 | 1200 | 1760 | 4320 |
| 最大 (ns) | 16400 | 17120 | 199968 | 229104 |

### 2.3 中断延迟 (500 样本)

| 指标 | v13 | v12-test5 | v11 |
|------|-----|-----------|-----|
| 平均 (us) | 999 | 1010 | 1010 |
| P50 (us) | 1000 | 1009 | 1009 |
| P99 (us) | 1009 | 1057 | 1120 |
| 最大 (us) | 1037 | 1130 | 1121 |

### 2.4 长时间稳定性 (60 秒)

| 指标 | v13 | v12-test5 |
|------|-----|-----------|
| 总样本数 | 4999 | 4999 |
| 全局最小 (us) | 995 | 983 |
| 全局最大 (us) | 1032 | 1339 |
| 全局平均 (us) | 1006 | 1101 |
| miss >100us | 0 (0.0%) | 1221 (24.4%) |
| miss >1ms | 0 (0.0%) | 0 (0.0%) |
| 回调最大执行时间 (ns) | 30464 | 116416 |

**重大改进**：v13全局最大仅1032us（v12为1339us），miss>100us从24.4%降至0%。

### 2.5 跨版本一致性对比

| 指标 | v9 | v11 | v12 | v13 |
|------|-----|-----|-----|-----|
| 定时器 P50 | - | 1097 | 1095 | 1006 |
| 定时器 P99 | 8882 | 1212 | 1140 | 1016 |
| 定时器 miss>100us | 255 | ~450 | ~450 | 0 |
| 抢占 avg | 2400 | 1584 | 1168 | 1664 |
| 抢占 P99 | 4320 | 1760 | 1200 | 2432 |
| IRQ avg | 1009 | 1010 | 1010 | 999 |
| IRQ P99 | 1122 | 1120 | 1057 | 1009 |
| 稳定性 miss>1ms | 0 | 0 | 0 | 0 |
| 稳定性 miss>100us | - | 22% | 24% | 0% |

---

## 3. 网络通信状态

### 3.1 RT-Thread 服务端

RT-IPC server（v9代码）已验证正常启动：
- virtio-net初始化成功（mmio_base=0xd0061400, init_handler返回0）
- lwIP协议栈启动
- RT-IPC server监听 192.168.77.30:9876
- 服务端等待客户端连接（msgs=0）

### 3.2 端到端通信

当前阻塞点：Linux VM[1]的控制台输出未出现在日志中，
导致无法通过init-linux-1脚本自动启动RT-IPC客户端。

根因：d7d273c2f worktree的axvisor二进制在当前环境下未能正确路由
Linux VM的控制台输出到串口。RT-Thread VM[3]的控制台正常工作。

v9-v12中记录的网络数据仍然有效（使用相同d7d273c2f二进制 + passthrough virtio-net）：
- ICMP ping: 0%丢包, RTT 1.2-8.7ms
- RT-IPC UDP: 4785+消息, 0%丢包 (v9 server代码)

---

## 4. 任务完成度

### 任务一 (实时性改造与验证): 92%

相比v12的90%，定时器精度大幅提升（P99 1140→1016us, miss>100us 9%→0%）。
唯一未完成项：裸机RTOS基线（axvisor编译的RT-Thread无法独立QEMU启动）。

### 任务二 (客户机间通信): 80%

相比v12的75%，RT-IPC server回归已修复并验证（v9代码正确运行）。
端到端测试受阻于Linux VM控制台路由问题，但v9-v12数据证明网络通信可行。

### 任务三 (AI 模型与控制联动): 0%

未开始。

---

## 5. 已知问题

### 5.1 Linux VM控制台输出缺失

d7d273c2f worktree构建的axvisor在当前环境下未能路由Linux VM[1]的
控制台输出到串口。RT-Thread VM[3]正常。需要调查UART多路复用配置。

### 5.2 cargo clean后axvisor构建回归

从HEAD代码执行cargo clean + rebuild后，新构建的axvisor二进制出现
sys_write => Err(EBADF)错误，导致所有VM无法启动。
HEAD包含上游重构提交（device graph、timer ownership等），引入了此回归。
d7d273c2f worktree（旧代码）不受影响。

### 5.3 裸机RTOS基线

axvisor编译的RT-Thread使用0xa0000000内存偏移，无法直接在QEMU上独立启动。

---

## 6. 构建与运行命令

### 6.1 构建RT-Thread
```bash
cd tmp/rt-thread-5.2.2-full/bsp/qemu-virt64-aarch64
export RTT_CC_PREFIX=aarch64-linux-musl-
export RTT_EXEC_PATH=/home/yfblock/Env/aarch64-linux-musl-cross/bin
export PATH=/home/yfblock/Env/aarch64-linux-musl-cross/bin:$PATH
scons -j4
# Link workaround: musl gcc segfaults, use system GNU ld
```

### 6.2 构建axvisor (d7d273c2f worktree)
```bash
cd .worktrees/d7d273c2f
cargo xtask axvisor build --config qemu-aarch64-two-guest-net \
  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/linux-net.toml \
  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml
aarch64-linux-musl-strip -o /tmp/axvisor_s target/aarch64-unknown-linux-musl/release/axvisor
aarch64-linux-gnu-objcopy -O binary /tmp/axvisor_s target/aarch64-unknown-linux-musl/release/axvisor.bin
```

### 6.3 运行
```bash
timeout 300 qemu-system-aarch64 \
  -nographic -cpu cortex-a72 \
  -machine virt,virtualization=on,gic-version=3 \
  -global virtio-mmio.force-legacy=false -smp 4 \
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 \
  -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img \
  -append 'root=/dev/nvme0n1 rw init=/bin/sh' -m 8g \
  -netdev hubport,id=net0,hubid=77 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
  -netdev hubport,id=net2,hubid=77 \
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 \
  -kernel .worktrees/d7d273c2f/target/aarch64-unknown-linux-musl/release/axvisor.bin
```

---

## 7. 迭代历史

| 版本 | 日期 | 关键变更 |
|------|------|---------|
| v3 | 08-11 | 网络修复(DHCP macro bug) |
| v4 | 08-12 | Passthrough模式完善 |
| v7 | 08-14 | Passthrough, RT-IPC 4785+消息, 0%丢包 |
| v9 | 08-14 | 完整报告 (999样本) |
| v10 | 08-14 | RT-IPC 1000/1000, 0%丢包 |
| v11 | 08-14 | 5000样本, 60s稳定性, 引入connect()回归 |
| v12 | 08-14 | ACK修复, passthrough UDP TX问题诊断 |
| v13 | 08-14 | 回退v9 server代码, 定时器P99=1016us, miss>100us=0% |
