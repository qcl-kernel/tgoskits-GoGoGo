# RT-Thread realtime comparison

Metrics: `timer_jitter, callback_exec, preemption, irq, irq_to_task, irq_disabled_duration, mutex_inversion, wake_under_load, net_event_latency`

## Assessment

| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |
|---|---:|---:|---:|
| A_native | True | False | 1051600 |
| B_axvisor_rtthread | True | True | 384352 |
| C_axvisor_linux_rtthread | True | False | 6788768 |

## Percentiles

| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| timer_jitter | A_native | 672 | 7168 | 57552 | 295280 | 1051600 | 7 | 1 | 1 |
| timer_jitter | B_axvisor_rtthread | 3120 | 12928 | 34432 | 163088 | 165200 | 2 | 0 | 0 |
| timer_jitter | C_axvisor_linux_rtthread | 3680 | 15808 | 85936 | 647504 | 673440 | 7 | 2 | 0 |
| callback_exec | A_native | 96 | 128 | 224 | 3376 | 35024 | 0 | 0 | 0 |
| callback_exec | B_axvisor_rtthread | 464 | 528 | 640 | 768 | 47200 | 0 | 0 | 0 |
| callback_exec | C_axvisor_linux_rtthread | 464 | 624 | 1904 | 3840 | 41856 | 0 | 0 | 0 |
| preemption | A_native | 1888 | 2192 | 3568 | 12400 | 15616 | 0 | 0 | 0 |
| preemption | B_axvisor_rtthread | 4736 | 5744 | 6144 | 15168 | 17616 | 0 | 0 | 0 |
| preemption | C_axvisor_linux_rtthread | 4944 | 5440 | 5728 | 8688 | 11632 | 0 | 0 | 0 |
| irq | A_native | 1600 | 1760 | 4384 | 5408 | 56256 | 0 | 0 | 0 |
| irq | B_axvisor_rtthread | 79216 | 82240 | 83376 | 211648 | 265472 | 2 | 0 | 0 |
| irq | C_axvisor_linux_rtthread | 74944 | 77200 | 80960 | 92960 | 260784 | 1 | 0 | 0 |
| irq_to_task | A_native | 2896 | 2928 | 3536 | 18368 | 29440 | 0 | 0 | 0 |
| irq_to_task | B_axvisor_rtthread | 82432 | 296336 | 304160 | 353328 | 384352 | 105 | 0 | 0 |
| irq_to_task | C_axvisor_linux_rtthread | 78784 | 279456 | 287200 | 434928 | 509168 | 93 | 1 | 0 |
| irq_disabled_duration | A_native | 288 | 288 | 304 | 512 | 23216 | 0 | 0 | 0 |
| irq_disabled_duration | B_axvisor_rtthread | 224 | 240 | 320 | 784 | 252512 | 1 | 0 | 0 |
| irq_disabled_duration | C_axvisor_linux_rtthread | 240 | 336 | 384 | 21120 | 219136 | 1 | 0 | 0 |
| mutex_inversion | A_native | 2416 | 13168 | 14688 | 26336 | 45504 | 0 | 0 | 0 |
| mutex_inversion | B_axvisor_rtthread | 10960 | 11392 | 16528 | 248368 | 248448 | 8 | 0 | 0 |
| mutex_inversion | C_axvisor_linux_rtthread | 7040 | 12848 | 220368 | 262176 | 263056 | 11 | 0 | 0 |
| wake_under_load | A_native | 1648 | 1680 | 1824 | 4320 | 9552 | 0 | 0 | 0 |
| wake_under_load | B_axvisor_rtthread | 1392 | 1568 | 2864 | 216800 | 220608 | 2 | 0 | 0 |
| wake_under_load | C_axvisor_linux_rtthread | 1600 | 2032 | 2416 | 8272 | 206832 | 1 | 0 | 0 |
| net_event_latency | A_native | 38080 | 48608 | 52752 | 80496 | 99792 | 0 | 0 | 0 |
| net_event_latency | B_axvisor_rtthread | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| net_event_latency | C_axvisor_linux_rtthread | 771504 | 816224 | 1227760 | 5787184 | 6788768 | 1000 | 752 | 15 |

Network metric status for B: `not_applicable_for_B`.

AxVisor-only has one guest and no peer endpoint for the cross-guest UDP probe
