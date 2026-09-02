# RT-Thread realtime comparison

Metrics: `timer_jitter, callback_exec, preemption, irq, irq_to_task, irq_disabled_duration, mutex_inversion, wake_under_load, net_event_latency`

## Assessment

| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |
|---|---:|---:|---:|
| A_native | True | True | 122592 |
| B_axvisor_rtthread | True | True | 397248 |
| C_axvisor_linux_rtthread | True | False | 3980448 |

## Percentiles

| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| timer_jitter | A_native | 672 | 10320 | 24704 | 46816 | 55808 | 0 | 0 | 0 |
| timer_jitter | B_axvisor_rtthread | 2064 | 7696 | 11904 | 148400 | 155008 | 2 | 0 | 0 |
| timer_jitter | C_axvisor_linux_rtthread | 3344 | 17632 | 202704 | 326432 | 510704 | 17 | 1 | 0 |
| callback_exec | A_native | 96 | 464 | 2784 | 9456 | 38480 | 0 | 0 | 0 |
| callback_exec | B_axvisor_rtthread | 432 | 480 | 608 | 736 | 41264 | 0 | 0 | 0 |
| callback_exec | C_axvisor_linux_rtthread | 448 | 640 | 976 | 5280 | 44592 | 0 | 0 | 0 |
| preemption | A_native | 2080 | 2304 | 6064 | 11808 | 16016 | 0 | 0 | 0 |
| preemption | B_axvisor_rtthread | 4608 | 4752 | 5216 | 5520 | 16432 | 0 | 0 | 0 |
| preemption | C_axvisor_linux_rtthread | 4736 | 5264 | 6640 | 14416 | 49296 | 0 | 0 | 0 |
| irq | A_native | 1664 | 4944 | 10800 | 12192 | 55744 | 0 | 0 | 0 |
| irq | B_axvisor_rtthread | 78176 | 80096 | 82416 | 87904 | 397248 | 1 | 0 | 0 |
| irq | C_axvisor_linux_rtthread | 74176 | 76992 | 82368 | 122176 | 472528 | 5 | 0 | 0 |
| irq_to_task | A_native | 3360 | 3392 | 4272 | 11312 | 31168 | 0 | 0 | 0 |
| irq_to_task | B_axvisor_rtthread | 82176 | 288128 | 295008 | 307296 | 319296 | 96 | 0 | 0 |
| irq_to_task | C_axvisor_linux_rtthread | 76624 | 279152 | 288320 | 373776 | 606336 | 94 | 1 | 0 |
| irq_disabled_duration | A_native | 272 | 288 | 304 | 448 | 21824 | 0 | 0 | 0 |
| irq_disabled_duration | B_axvisor_rtthread | 224 | 240 | 320 | 2912 | 19952 | 0 | 0 | 0 |
| irq_disabled_duration | C_axvisor_linux_rtthread | 240 | 304 | 368 | 416 | 21904 | 0 | 0 | 0 |
| mutex_inversion | A_native | 8224 | 14304 | 16592 | 28464 | 47728 | 0 | 0 | 0 |
| mutex_inversion | B_axvisor_rtthread | 3408 | 13184 | 22752 | 248160 | 253600 | 9 | 0 | 0 |
| mutex_inversion | C_axvisor_linux_rtthread | 7120 | 12560 | 22368 | 234928 | 261408 | 9 | 0 | 0 |
| wake_under_load | A_native | 1872 | 1904 | 1968 | 9760 | 10560 | 0 | 0 | 0 |
| wake_under_load | B_axvisor_rtthread | 1712 | 1984 | 4032 | 11600 | 215632 | 1 | 0 | 0 |
| wake_under_load | C_axvisor_linux_rtthread | 1472 | 2912 | 6352 | 904560 | 1608896 | 8 | 5 | 1 |
| net_event_latency | A_native | 39968 | 59344 | 108048 | 120944 | 122592 | 13 | 0 | 0 |
| net_event_latency | B_axvisor_rtthread | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| net_event_latency | C_axvisor_linux_rtthread | 1550080 | 2267280 | 2414560 | 3018608 | 3980448 | 1000 | 913 | 757 |

Network metric status for B: `not_applicable_for_B`.

AxVisor-only has one guest and no peer endpoint for the cross-guest UDP probe
