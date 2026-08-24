# RT-Thread realtime comparison

Metrics: `timer_jitter, callback_exec, preemption, irq, irq_to_task, irq_disabled_duration, mutex_inversion, wake_under_load, net_event_latency`

## Assessment

| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |
|---|---:|---:|---:|
| A_native | True | True | 242096 |
| B_axvisor_rtthread | True | True | 883840 |
| C_axvisor_linux_rtthread | True | False | 1786752 |

## Percentiles

| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| timer_jitter | A_native | 576 | 4528 | 12240 | 38096 | 242096 | 4 | 0 | 0 |
| timer_jitter | B_axvisor_rtthread | 3184 | 15536 | 26576 | 150864 | 585232 | 245 | 2 | 0 |
| timer_jitter | C_axvisor_linux_rtthread | 99424 | 403920 | 441824 | 548576 | 905040 | 49920 | 149 | 0 |
| callback_exec | A_native | 112 | 192 | 448 | 9392 | 36976 | 0 | 0 | 0 |
| callback_exec | B_axvisor_rtthread | 432 | 496 | 608 | 2272 | 149904 | 3 | 0 | 0 |
| callback_exec | C_axvisor_linux_rtthread | 528 | 736 | 1920 | 5792 | 173072 | 43 | 0 | 0 |
| preemption | A_native | 1872 | 4352 | 8240 | 11392 | 16640 | 0 | 0 | 0 |
| preemption | B_axvisor_rtthread | 4864 | 5056 | 5280 | 7456 | 147152 | 12 | 0 | 0 |
| preemption | C_axvisor_linux_rtthread | 5104 | 5360 | 5648 | 7872 | 139840 | 13 | 0 | 0 |
| irq | A_native | 1648 | 2016 | 6144 | 11392 | 49552 | 0 | 0 | 0 |
| irq | B_axvisor_rtthread | 77472 | 81392 | 83136 | 116944 | 276176 | 252 | 0 | 0 |
| irq | C_axvisor_linux_rtthread | 75696 | 78976 | 84064 | 113088 | 294528 | 283 | 0 | 0 |
| irq_to_task | A_native | 2304 | 2336 | 2704 | 7088 | 33840 | 0 | 0 | 0 |
| irq_to_task | B_axvisor_rtthread | 79872 | 286608 | 305744 | 332752 | 883840 | 9553 | 21 | 0 |
| irq_to_task | C_axvisor_linux_rtthread | 79920 | 281152 | 289088 | 421424 | 781776 | 9789 | 83 | 0 |
| irq_disabled_duration | A_native | 224 | 240 | 240 | 400 | 20112 | 0 | 0 | 0 |
| irq_disabled_duration | B_axvisor_rtthread | 240 | 256 | 320 | 1360 | 234320 | 8 | 0 | 0 |
| irq_disabled_duration | C_axvisor_linux_rtthread | 224 | 256 | 368 | 1776 | 212240 | 5 | 0 | 0 |
| mutex_inversion | A_native | 5328 | 10512 | 11760 | 18384 | 51040 | 0 | 0 | 0 |
| mutex_inversion | B_axvisor_rtthread | 10912 | 12400 | 18384 | 247152 | 394320 | 806 | 0 | 0 |
| mutex_inversion | C_axvisor_linux_rtthread | 9264 | 13216 | 22752 | 242912 | 1035504 | 872 | 6 | 2 |
| wake_under_load | A_native | 1328 | 1360 | 1392 | 5392 | 41152 | 0 | 0 | 0 |
| wake_under_load | B_axvisor_rtthread | 1520 | 1792 | 3088 | 217792 | 251536 | 193 | 0 | 0 |
| wake_under_load | C_axvisor_linux_rtthread | 1632 | 1984 | 3232 | 215312 | 429984 | 206 | 0 | 0 |
| net_event_latency | A_native | 38544 | 52720 | 99200 | 131376 | 199776 | 974 | 0 | 0 |
| net_event_latency | B_axvisor_rtthread | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| net_event_latency | C_axvisor_linux_rtthread | 809232 | 919360 | 939536 | 1030368 | 1786752 | 100000 | 95032 | 155 |

Network metric status for B: `not_applicable_for_B`.

AxVisor-only has one guest and no peer endpoint for the cross-guest UDP probe
