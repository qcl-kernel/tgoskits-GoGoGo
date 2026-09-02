# Axvisor RT-Thread Real-Time Test Report (v3) - Network Communication Fixed

Test date: 2026-08-11
Branch: rtthread-guest
Platform: QEMU TCG, cortex-a72 x 4, 8GB RAM

## 1. Summary

virtio-net communication between Linux VM and RT-Thread RTOS guest is now
fully functional. Root cause was a macro definition bug in RT-Thread's
LWIP configuration.

## 2. Root Cause: RT_LWIP_DHCP Macro Bug

RT-Thread's Kconfig generates '#define RT_LWIP_DHCP 0' when DHCP is
disabled. However, lwipopts.h checks '#ifdef RT_LWIP_DHCP' (not '#if'),
which evaluates to true even when the value is 0.

This caused:
- LWIP_DHCP=1 (should be 0)
- RT-Thread starting with IP 0.0.0.0
- DHCP Discover/Request packets sent (instead of using static IP)
- ARP requests for 192.168.77.30 ignored (no matching IP)

Fix: Remove '#define RT_LWIP_DHCP 0' from rtconfig.h entirely.
Also: Add quotes around IP address literals (inet_addr requires strings).

## 3. Benchmark Results

### 3.1 Timer Jitter (1ms period, 999 samples/round, 3 rounds)

| Metric       | Round 1 | Round 2 | Round 3 |
|--------------|---------|---------|---------|
| Min (us)     | 997     | 997     | 996     |
| Max (us)     | 1237    | 1039    | 1031    |
| Avg (us)     | 1006    | 1005    | 1005    |
| P-P Jitter   | 240     | 42      | 35      |
| P99 (us)     | 1021    | 1021    | 1017    |
| miss >100us  | 1       | 0       | 0       |
| miss >1ms    | 0       | 0       | 0       |
| CB max (ns)  | 17232   | 10048   | 8240    |

### 3.2 Interrupt Latency (1-tick one-shot, 200 samples)

| Metric  | Value |
|---------|-------|
| Min (us)| 821   |
| Max (us)| 1010  |
| Avg (us)| 1000  |
| P99 (us)| 1009  |

### 3.3 Network RTT (Linux -> RT-Thread, 20 pings)

| Metric       | Value    |
|--------------|----------|
| Min RTT (ms) | 0.326    |
| Avg RTT (ms) | 0.511    |
| Max RTT (ms) | 0.842    |
| Loss         | 0%       |

### 3.4 Preemption Latency

Startup race condition in benchmark code. 0 samples collected.
Pending fix in next iteration.

## 4. All Fixes Applied

1. rtconfig.h: Remove RT_LWIP_DHCP, quote IP addresses
2. virtio.h: VA2PA safe fallback for AT instruction failure at EL2
3. virtio.c: 64-bit queue address registers with 44-bit mask
4. virtio_net.c: Vololatile feature negotiation with DSB barriers
5. virtio_net.c: 1ms RX polling timer (SPI not delivered in QEMU TCG passthrough)
6. FDT: Preserve dma-coherent on passthrough devices
7. Config: passthrough_irqs for virtio-net SPIs on both VMs

## 5. Assessment

Timer jitter: Stable at +-20us in steady state, zero deadline misses.
Interrupt latency: Constrained by 1ms tick granularity.
Network RTT: 0.3-0.8ms is excellent for QEMU TCG virtio-net.
Overall: Reasonable but not hard real-time. QEMU TCG limits determinism.
