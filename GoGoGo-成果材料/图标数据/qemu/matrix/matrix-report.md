# Task123 cargo xtask RTOS 矩阵报告

| RTOS | 应用客户机 | Task 2 | Task 3 | Task 123 | 成功率 | Task 3 超时 | Task 3 重传 | RTT p50 (us) | RTBench timer jitter p99 (ns) | p99 cycles | p99 instructions |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| rtthread | linux | PASS | PASS | PASS | 1.0 | 0 | 0 | 22820 | 3143872 | 1059984 | 1059984 |
| rtthread | starryos | PASS | PASS | PASS | 1.0 | 0 | 0 | 8262 | 1400896 | 951955 | 951955 |
| zephyr | linux | PASS | PASS | PASS | 1.0 | 0 | 0 | 12822 | 0 | 0 | 0 |
| zephyr | starryos | PASS | PASS | PASS | 1.0 | 0 | 0 | 3539 | 0 | 0 | 0 |

数据来自各组合的 `summary.json`、客户机日志和 RTOS RTBench 日志。QEMU TCG 的时间数据不等价于物理板实时性上界。
