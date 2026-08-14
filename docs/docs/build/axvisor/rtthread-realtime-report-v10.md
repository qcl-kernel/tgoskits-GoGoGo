# Axvisor RT-Thread Real-Time & Network Communication Test Report (v10)

> Test Date: 2026-08-10 to 2026-08-14
> Branch: rtthread-migration (commit 42dd2fd71)
> RTOS: RT-Thread 5.2.2 (qemu-virt64-aarch64 BSP)
> Hypervisor: Axvisor (release, qemu-aarch64-two-guest-net)
> Platform: QEMU TCG, cortex-a72 x 4, 8GB RAM
> v10: Independent rebuild + rerun, reproducibility verified

## 1. System Architecture

- Linux VM: 2 vCPUs (CPU0+CPU1), IP 192.168.77.11
- RT-Thread VM: 1 vCPU (CPU2, static partition), IP 192.168.77.30
- Network: passthrough virtio-net + QEMU hub 77 (L2 switch)
- CPU3: axvisor host (idle)

## 2. Real-Time Benchmarks

### Timer Jitter (1ms period, 999 samples/round, 3 rounds)

| Metric | Round 1 | Round 2 | Round 3 |
|--------|---------|---------|---------|
| min (us) | 1082 | 1079 | 907 |
| max (us) | 10131 | 15756 | 9766 |
| avg (us) | 1218 | 1253 | 1258 |
| P99 (us) | 5685 | 7116 | 7955 |
| P99.9 (us) | 9214 | 15315 | 9202 |
| miss>100us | 258 | 240 | 252 |
| miss>1ms | 23 | 26 | 28 |
| callback_max (ns) | 104512 | 3680 | 2832 |

### Interrupt Latency (200 samples, 1-tick one-shot)

| Metric | v10 | v9 |
|--------|-----|-----|
| min (us) | 256 | 784 |
| max (us) | 1119 | 1272 |
| avg (us) | 1001 | 1009 |
| P99 (us) | 1102 | 1122 |

### Preemption Latency (200 samples)

| Metric | v10 | v9 |
|--------|-----|-----|
| min (ns) | 1136 | 1120 |
| max (ns) | 16096 | 229104 |
| avg (ns) | 1456 | 2400 |
| P99 (ns) | 6464 | 4320 |

## 3. Network Communication

### ICMP Ping: 0% loss, RTT 1.853-14.156ms

### RT-IPC UDP (v9 full data)

| Payload | min RTT | avg RTT | max RTT | P50 | P95 | Throughput |
|---------|---------|---------|---------|-----|------|------------|
| 64B | 13ms | 50ms | 231ms | 15ms | 117ms | 20 KB/s |
| 256B | 14ms | 34ms | 217ms | 217ms | 217ms | 41 KB/s |
| 1024B | 15ms | 71ms | 234ms | 234ms | 234ms | 166 KB/s |

v10: 4360+ msgs exchanged, 0% loss, disconnect/reconnect verified.

## 4. Task Completion

- Task 1: 90% (missing: hardware long-duration test)
- Task 2: 95% (complete with disconnect/reconnect)
- Task 3: 0% (not started)
