# Axvisor RT-Thread Real-Time Benchmark Report

> Date: 2026-08-10
> Branch: rtthread-guest
> RTOS: RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor: Axvisor (release, qemu-aarch64-two-guest-net)
> Platform: QEMU TCG, cortex-a72 × 4, 8GB RAM

## 1. Environment

| Item | Configuration |
|------|---------------|
| QEMU | TCG mode (no KVM), cortex-a72 |
| CPU | 4 cores, RT-Thread vCPU pinned to physical core 2 |
| GIC | GICv3 (GICD/GICR trap-and-emulate) |
| RT-Thread | 5.2.2, tick=1000Hz, CNTVCT=62.5MHz |
| Host Timer Policy | Periodic |
| Host VCPU Idle | Halt |

## 2. Porting Fixes

1. **Link address**: _text_offset 0x80000 to 0
2. **MMU pv_off==0**: Added TTBR0-only mapping branch
3. **Device memory**: Added UART/GIC/virtio DEVICE_MEM entries
4. **GIC IPRIORITYR compiler optimization**: Added memory barrier
5. **GICR SGI frame**: Skipped IPRIORITYR batch init (Axvisor emulation gap)
6. **Console output**: Direct PL011 UART writes replacing ofw console
7. **Components init**: Enabled RT_USING_COMPONENTS_INIT
8. **Main thread stack**: 2048 to 16384 bytes

## 3. Benchmark Results

### 3.1 Timer Jitter (1ms period, 999 samples/round, 3 rounds)

| Metric | Round 1 | Round 2 | Round 3 |
|--------|---------|---------|---------|
| Min interval (us) | 995 | 1001 | 999 |
| Max interval (us) | 1060 | 1026 | 1030 |
| Avg interval (us) | 1006 | 1006 | 1006 |
| Peak-to-peak jitter (us) | 65 | 25 | 30 |
| P99 (us) | 1016 | 1014 | 1013 |
| Miss >100us | 0 | 0 | 0 |
| Miss >1ms | 0 | 0 | 0 |
| Callback max (ns) | 35728 | 6384 | 3552 |

### 3.2 Key Findings

- Zero deadline misses across all 3 rounds
- Maximum deviation of 60us in Round 1 (cache cold start)
- Rounds 2/3 stabilized at ±15us jitter range
- Callback execution time negligible (<36us)

## 4. Performance Assessment

Current results are **reasonable but not excellent**. Typical jitter of ±30us at 1ms period is acceptable under QEMU TCG, but falls short of hard real-time guarantees. QEMU TCG software translation, host scheduling preemption, and other factors limit determinism.

## 5. Untested Metrics

- Preemption Latency
- Interrupt Latency
- Network RTT (via virtio-net)
- WCET (Worst-Case Execution Time)

## 6. Next Steps

1. Clean up debug UART writes
2. Enable virtio-net, implement Linux to RT-Thread network communication
3. Add more real-time metric tests
4. Validate on real hardware (Orange Pi 5 Plus)
