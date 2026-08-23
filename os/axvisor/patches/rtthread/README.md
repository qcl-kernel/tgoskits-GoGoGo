# RT-Thread AArch64 guest 移植与修复记录

本目录是 RT-Thread 作为 Axvisor 虚拟机 guest 时，对上游 RT-Thread 的**全部改动的权威记录**。
RT-Thread 上游源码不在此仓库内，这里以「patch 文件集 + apply 脚本」的方式固化改动，保证从
干净的上游 checkout 可以可复现地重建出可用的 guest 镜像。

## 上游基线

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/RT-Thread/rt-thread.git` |
| 版本 | v5.2.2 |
| 固定 commit | `ddf52e2cdd977f14fc04035c88672ac204aec713` |
| BSP | `bsp/qemu-virt64-aarch64` |

`prepare_rtthread_source.sh` 会 clone 到上述固定 commit 并应用全部 patch（默认输出到
`tmp/rt-thread-5.2.2-full`）；`apply-rtthread-patches.sh` 则对一份已存在的干净源码树原地 apply，
并通过 `.axvisor-rtthread-patch-state` 记录 patch 集的 digest，避免对脏树/漂移树重复打补丁。

## Patch 清单

按应用顺序排列（编号不连续，`0001` 历史上被移除）。规模为 diff 的 +/− 行数。

| Patch | 修复内容 | 文件 | +/− |
|---|---|---|---|
| `0000-axvisor-aarch64-port.patch` | AArch64 基础移植：关 SMP、开 virtio-net、裁掉无用驱动（gpio/rtc/pin/console/graphic/mnt）、MMU/GIC/virtio 基础、`.config`/`rtconfig.h` 精简 | 38 | +747 / −1427 |
| `0002-lwip-rx-mailbox-recover-notice.patch` | lwIP RX mailbox 满时清除 `rx_notice`，避免非阻塞发送失败后通知丢失 | 1 | +9 / −1 |
| `0003-virtio-net-reclaim-tx-used-ring.patch` | virtio-net TX used-ring 回收，TX/RX 描述符 buffer 分离 | 1 | +32 / −4 |
| `0004-virtio-net-use-rx-used-ring-head.patch` | RX 完成用 used ring 精确的 chain head，而非 `used_id + 1` | 1 | +4 / −4 |
| `0005-lwip-configurable-udp-recv-mailbox.patch` | lwIP UDP 接收 mailbox 槽位可配置 | 1 | +4 / −0 |
| `0006-gicv3-use-redistributor-pending-registers.patch` | GICv3 本地 SGI/PPI pending 用当前 CPU redistributor 寄存器，而非已移除的 GICv2 SPENDSGIR/CPENDSGIR | 1 | +19 / −23 |
| `0007-gicv3-query-interrupt-enable-state.patch` | 中断使能状态可查询（benchmark 清理时精确还原 caller 状态） | 6 | +53 / −0 |
| `0008-aarch64-gtimer-use-absolute-deadlines.patch` | AArch64 定时器用绝对 CNTV_CVAL 截止 + 累加补偿，消除相对 TVAL 的相位误差累积 | 3 | +45 / −13 |
| `0009-native-qemu-memory-layout.patch` | guest 镜像链接到 2 MiB 偏移，与 VM 配置地址一致 | 2 | +3 / −3 |
| `0010-virtio-net-benchmark-packet-hook.patch` | benchmark 专用 RX packet hook，暴露报文字节供 UDP 探针包选择 | 2 | +29 / −2 |

合计约 **+947 / −1479 行**，覆盖 RT-Thread 的 BSP、libcpu/aarch64、virtio-net、lwIP、GICv3 等子系统。

## 配套的 guest 源码（在 tgoskits 仓库内，非 patch）

这些源码由 `apply-rtthread-patches.sh` 在 apply 后拷入 BSP，而非以 patch 形式管理：

- `os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c` —— 实时性/稳定性基准（canonical source）
- `os/axvisor/guests/rt-ipc/` —— RT-IPC UDP server（`applications/rt-ipc-test/`）
- `os/axvisor/guests/task3/` —— Task 3 UDP/9877 控制 server（`applications/task3/`）

## 提交历史

以下提交在 tgoskits 仓库中引入/演进这份 patch 集（`git log -- os/axvisor/patches/rtthread/`，
新 → 旧）：

```
b46ca8642 feat(task123): integrate RT-Thread realtime and network validation
9b7a85d92 build(task123): add persistent caches and guest diagnostics
2c7c43b01 fix(task123): keep rtbench summary from starving network
afce91d6b fix(rtthread): isolate virtio-net TX buffers
3d1c53bfe fix(axvisor): emit delayed server fault evidence
f8d8cf528 feat(axvisor): combine realtime and network RT-Thread services
c3c8ec88c fix(axvisor): bound delayed RT-Thread tick accounting
a61bc4112 fix(axvisor): verify RT-Thread patches exactly
210961964 fix(axvisor): reject dirty RT-Thread source trees
3fb2cd2ed fix(axvisor): normalize migrated RT-Thread patches
f55982547 feat(axvisor): migrate realtime and RT-IPC integration
9b643778e fix: virtio-mmio FDT address mismatch and accept sub-32-bit accesses
d7d273c2f feat: AArch64 interrupt injection, debug cleanup, and RT-IPC integration
e63459c2f build(rt-ipc): enable SAL/socket and install server into RT-Thread BSP
d84b533be docs: add RT-Thread patch documentation for reproducibility
```

## 持续使用的注意点

1. **权威记录是 patch 文件 + `rt_benchmark.c`/`rt-ipc`/`task3` guest 源码**，不是任何 `/tmp` 下的
   手动 checkout。历史上 `/tmp/rtthread-fix/source` 这类探索树工作区里混有已废弃的调试探针
   （如 `context_gcc.S` 里的 `hvc #0` 探针、`0x2ad40000` UART 标记、`BOARD PROBE`），那些**从未进入
   patch 集**，不要基于它们提交或继续开发。
2. 修改 RT-Thread 行为时，改**这里的 patch 或 guest 源码**，然后重新走
   `prepare_rtthread_source.sh`（全新）或 `apply-rtthread-patches.sh`（原地）重建，保证可复现。
3. `apply-rtthread-patches.sh` 通过 `PATCH_SET_DIGEST` 校验 patch 集一致性；任何 patch 改动都会使
   旧的 `.axvisor-rtthread-patch-state` 失效，需要从干净树重来。
