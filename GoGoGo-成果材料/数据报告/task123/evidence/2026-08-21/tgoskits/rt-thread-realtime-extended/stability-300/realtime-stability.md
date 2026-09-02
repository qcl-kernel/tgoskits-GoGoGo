# RT-Thread realtime comparison

Metrics: `stability_jitter, callback_exec`

## Assessment

| Scenario | Data complete | Strict tail pass | Tail degradation (ns) |
|---|---:|---:|---:|
| A_native | True | True | 176432 |
| B_axvisor_rtthread | True | True | 421280 |
| C_axvisor_linux_rtthread | True | True | 827280 |

## Percentiles

| Metric | Scenario | P50 (ns) | P95 (ns) | P99 (ns) | P99.9 (ns) | Max (ns) | >100us | >500us | >1ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| stability_jitter | A_native | 624 | 3200 | 10608 | 37280 | 176432 | 15 | 0 | 0 |
| stability_jitter | B_axvisor_rtthread | 3472 | 14464 | 23056 | 148912 | 421280 | 722 | 0 | 0 |
| stability_jitter | C_axvisor_linux_rtthread | 66960 | 370080 | 422208 | 443392 | 827280 | 123235 | 19 | 0 |
| callback_exec | A_native | 112 | 176 | 448 | 8336 | 36672 | 0 | 0 | 0 |
| callback_exec | B_axvisor_rtthread | 464 | 720 | 2144 | 6656 | 150464 | 6 | 0 | 0 |
| callback_exec | C_axvisor_linux_rtthread | 528 | 720 | 3088 | 10288 | 172048 | 62 | 0 | 0 |
