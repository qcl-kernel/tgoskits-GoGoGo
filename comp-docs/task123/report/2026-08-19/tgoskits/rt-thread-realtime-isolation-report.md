# RT-Thread A/B/C 实时性隔离对照报告

日期：2026-08-19

分支：tgoskits dev

提交：9b7a85d928c5f99985a0aac0036876418796f1c3

## 1. 测试目的

此前 AxVisor + Linux 共存场景中 RT-Thread 出现毫秒级周期唤醒长尾。本报告通过三组
隔离实验判断长尾来自 QEMU TCG、AxVisor 基础虚拟化，还是 Linux 共存负载。

三组场景定义：

- A：native RT-Thread，直接运行在 QEMU virt 上，无 AxVisor。
- B：AxVisor + RT-Thread only，只启动一个 RT-Thread VM。
- C：AxVisor + 2-vCPU Linux + RT-Thread，与当前 Task 1/2/3 集成场景一致。

## 2. 测试条件

| 项目 | 配置 |
|---|---|
| 宿主 | x86_64，QEMU 11.0.2 |
| 外层平台 | AArch64 virt，GICv3，Cortex-A72，TCG |
| A 组 vCPU | 1 |
| B/C 组外层 vCPU | 4 |
| RT-Thread | 5.2.2，固定 pCPU 2，host_vcpu_idle_policy=busy |
| C 组 Linux | 2 vCPU，可在 pCPU 0/1/3 调度 |
| 测试 | rtbench_stability 300 |
| 样本 | 每组 299999/299999，missing=0 |
| QEMU 实时控制 | uclamp.min=1024，timerslack_ns=1 |

B 组复用 C 组相同 SHA256 的 RT-Thread 镜像，避免把不同 guest 二进制混入对比。

## 3. 结果

### 3.1 周期任务抖动

| 指标 | A native | B AxVisor+RT-Thread | C AxVisor+Linux |
|---|---:|---:|---:|
| P50 | 0.384 us | 2.736 us | 19.792 us |
| P95 | 2.928 us | 12.800 us | 292.560 us |
| P99 | 10.912 us | 18.048 us | 396.848 us |
| P99.9 | 37.344 us | 139.280 us | 456.400 us |
| 最大值 | 145.696 us | 488.032 us | 2.803 ms |
| >100 us | 2 | 592 | 84751 |
| >500 us | 0 | 0 | 66 |
| >1 ms | 0 | 0 | 2 |
| 平均值 | 0.939 us | 4.398 us | 75.607 us |

### 3.2 回调执行时间

| 指标 | A native | B AxVisor+RT-Thread | C AxVisor+Linux |
|---|---:|---:|---:|
| P50 | 112 ns | 448 ns | 528 ns |
| P95 | 256 ns | 592 ns | 672 ns |
| P99 | 6.032 us | 816 ns | 960 ns |
| P99.9 | 9.856 us | 4.512 us | 7.888 us |
| 最大值 | 37.424 us | 130.000 us | 163.056 us |
| >1 ms | 0 | 0 | 0 |

## 4. 结论

1. QEMU TCG 本身不是毫秒级长尾的主要来源。A 组同样运行在 x86_64 宿主和 AArch64 TCG
   下，最大抖动只有 145.696us，且没有 >1ms 事件。

2. AxVisor 基础虚拟化引入明显但可控的开销。B 组 P50 从 0.384us 增至 2.736us，P99
   从 10.912us 增至 18.048us，最大值从 145.696us 增至 488.032us。B 组仍无 >1ms 事件。

3. 主要长尾来自 Linux 共存场景，而不是 RT-Thread 回调执行。C 组 callback 执行最大值
   仍低于 1ms；但周期唤醒出现 2 次 >1ms，最大抖动 2.803ms。这说明瓶颈位于唤醒/定时器
   投递/宿主线程调度/设备模拟边界，而不是 RT-Thread 周期函数本身长时间执行。

4. 优先排查方向：
   - 外层 QEMU 多线程与宿主调度干扰，尤其 Linux vCPU、virtio-net、NVMe 模拟线程；
   - 网络流量活跃时的 AxVisor ingress、virtqueue 处理和 VGIC 注入路径；
   - guest virtual timer 到 AxVisor one-shot deadline 的转换与 vCPU 唤醒；
   - 宿主侧 QEMU 线程亲和性和实时优先级。

## 5. 门禁解释

A/B 组严格通过 miss_1ms=0。C 组 299999 个样本全部采集，无缺失，但有 2 个样本超过 1ms，
因此 RTBench 内部输出 status=FAIL。集成流程将其归类为
PASS_WITH_QEMU_TIMER_LIMIT：功能和数据完整性通过，最坏情况实时门禁未通过。

不能将 C 组结果解释为硬件 WCET 结论；但它足以说明：仅用“QEMU TCG 必然有长尾”解释
C 组毫秒级尾部是不充分的，共存干扰路径需要继续优化。

## 6. 原始证据

[summary.csv](../../../evidence/2026-08-19/tgoskits/rt-thread-realtime-isolation/summary.csv)

其余日志按场景归档于：

- task123/evidence/2026-08-19/tgoskits/rt-thread-realtime-isolation/native/
- task123/evidence/2026-08-19/tgoskits/rt-thread-realtime-isolation/axvisor-rtthread-only/
- task123/evidence/2026-08-19/tgoskits/rt-thread-realtime-isolation/axvisor-linux/
