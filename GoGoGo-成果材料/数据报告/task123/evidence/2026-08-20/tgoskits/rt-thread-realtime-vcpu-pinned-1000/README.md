# RT-Thread vCPU 线程亲和性复测证据

日期：2026-08-20

本目录保存真实 QEMU 11.0.2、1000 样本的 RT-Thread A/B/C 对照结果。A 是 native
RT-Thread，B 是 AxVisor + RT-Thread only，C 是 AxVisor + 2-vCPU Linux + RT-Thread。
QEMU 外层线程固定到宿主 CPU `2-5`，QEMU vCPU 线程映射为 `0=3,1=4,2=2,3=5`；
RT-Thread 对应 AxVisor pCPU 2，Linux 使用非 RT CPU 集合。

所有适用指标均为 `expected=1000 collected=1000 missing=0`。B/C 的 QEMU 运行均使用
真实 QEMU，B 的修复后日志明确记录四个 vCPU 线程绑定成功。B 不采集
`net_event_latency`，因为 AxVisor-only 没有 Linux peer。

## 运行方式

```bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
QEMU=/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 \
QEMU_CPU_AFFINITY=2-5 \
QEMU_VCPU_AFFINITY=0=3,1=4,2=2,3=5 \
os/axvisor/scripts/run_rtthread_axvisor_only.sh \
  --image "$PWD/tmp/rt-thread-5.2.2-native-current/bsp/qemu-virt64-aarch64/rtthread.bin" \
  --suite-samples 1000 --core-suite \
  --output "$PWD/tmp/realtime-b-vcpu-1000.J1z01B"
```

C 的原始日志来自同一批 1000 样本共存测试；比较结果由
`os/axvisor/scripts/summarize_rtthread_realtime.py` 生成，详见 `comparison/`。

## 运行器修复

AxVisor-only runner 原先把 FIFO 的阻塞打开操作放进后台 QEMU 命令，`$!` 实际指向等待
FIFO 的 shell，导致实时控制脚本找不到 QEMU vCPU 线程且 `console.log` 为空。现在 runner
先执行 `exec 3<> "$fifo"`，再以 `<&3` 启动真实 QEMU；同时 vCPU 线程发现窗口默认为
30 秒，可由 `QEMU_VCPU_AFFINITY_WAIT_S` 调整。

串口中 RT-IPC 状态消息可能插入 RTBENCH 指标。汇总器现在会清除 ANSI/NUL 和有限的
RT-IPC 状态消息，并恢复被交错成 `mute...inversion` 的固定指标名；原始日志保持不变。
