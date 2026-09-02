# RT-Thread realtime comparison

Metrics: `timer_jitter, callback_exec, preemption, irq, irq_to_task, irq_disabled_duration, mutex_inversion, wake_under_load, net_event_latency`

## Assessment

| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |
|---|---:|---:|---:|
| A_native | True | True | 109968 |
| B_axvisor_rtthread | True | True | 357168 |
| C_axvisor_linux_rtthread | True | False | 4692128 |

## Percentiles

| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| timer_jitter | A_native | 656 | 5376 | 26320 | 47152 | 50080 | 0 | 0 | 0 |
| timer_jitter | B_axvisor_rtthread | 3856 | 18976 | 153232 | 232688 | 276752 | 22 | 0 | 0 |
| timer_jitter | C_axvisor_linux_rtthread | 3520 | 13008 | 24304 | 564864 | 605136 | 4 | 2 | 0 |
| callback_exec | A_native | 96 | 432 | 768 | 8576 | 89744 | 0 | 0 | 0 |
| callback_exec | B_axvisor_rtthread | 496 | 4912 | 10640 | 12240 | 46352 | 0 | 0 | 0 |
| callback_exec | C_axvisor_linux_rtthread | 448 | 624 | 784 | 3872 | 46432 | 0 | 0 | 0 |
| preemption | A_native | 2160 | 2448 | 6304 | 9824 | 13152 | 0 | 0 | 0 |
| preemption | B_axvisor_rtthread | 4544 | 4752 | 4960 | 15728 | 135712 | 1 | 0 | 0 |
| preemption | C_axvisor_linux_rtthread | 4736 | 5216 | 5472 | 6416 | 12384 | 0 | 0 | 0 |
| irq | A_native | 1664 | 2496 | 11008 | 11808 | 55600 | 0 | 0 | 0 |
| irq | B_axvisor_rtthread | 77872 | 80176 | 81840 | 101136 | 270144 | 2 | 0 | 0 |
| irq | C_axvisor_linux_rtthread | 74928 | 77824 | 82752 | 110800 | 246144 | 5 | 0 | 0 |
| irq_to_task | A_native | 3344 | 3392 | 4176 | 11136 | 31168 | 0 | 0 | 0 |
| irq_to_task | B_axvisor_rtthread | 80800 | 294144 | 304256 | 325584 | 357168 | 95 | 0 | 0 |
| irq_to_task | C_axvisor_linux_rtthread | 77168 | 275040 | 282736 | 292592 | 296864 | 91 | 0 | 0 |
| irq_disabled_duration | A_native | 288 | 304 | 320 | 2272 | 22000 | 0 | 0 | 0 |
| irq_disabled_duration | B_axvisor_rtthread | 224 | 240 | 368 | 20880 | 227920 | 1 | 0 | 0 |
| irq_disabled_duration | C_axvisor_linux_rtthread | 240 | 304 | 352 | 416 | 20144 | 0 | 0 | 0 |
| mutex_inversion | A_native | 12224 | 14304 | 19776 | 30784 | 39392 | 0 | 0 | 0 |
| mutex_inversion | B_axvisor_rtthread | 1776 | 11568 | 18144 | 271920 | 272704 | 7 | 0 | 0 |
| mutex_inversion | C_axvisor_linux_rtthread | 7216 | 13184 | 224320 | 239712 | 262880 | 13 | 0 | 0 |
| wake_under_load | A_native | 1888 | 1920 | 2976 | 8112 | 9152 | 0 | 0 | 0 |
| wake_under_load | B_axvisor_rtthread | 1472 | 1728 | 3072 | 234656 | 250432 | 4 | 0 | 0 |
| wake_under_load | C_axvisor_linux_rtthread | 1472 | 2240 | 4976 | 1442992 | 1652368 | 4 | 3 | 2 |
| net_event_latency | A_native | 39152 | 49120 | 57760 | 94384 | 109968 | 1 | 0 | 0 |
| net_event_latency | B_axvisor_rtthread | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| net_event_latency | C_axvisor_linux_rtthread | 1369424 | 2322976 | 2461776 | 2919920 | 4692128 | 1000 | 884 | 660 |

Network metric status for B: `not_applicable_for_B`.

AxVisor-only has one guest and no peer endpoint for the cross-guest UDP probe
