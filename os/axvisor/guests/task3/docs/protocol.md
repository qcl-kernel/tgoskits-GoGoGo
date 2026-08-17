# Task 3 RT-IPC/UDP 应用协议

## 传输边界

主通道是 virtio-net 上的 IPv4/UDP：Linux `192.168.77.11` 向 RT-Thread `192.168.77.30:9877` 发起 RT-IPC v2 会话。RT-IPC datagram 由固定 20 字节头和 0..1400 字节载荷组成；本应用只使用 24 字节 CTRL_CMD、24 字节 STATUS_REP 和 12 字节 ERROR_NOTIFY。不使用 vsock，也不使用共享内存、HyperCall 或 MMIO 传送应用数据。Task 2 使用独立的 UDP/9876 服务。

所有多字节整数使用网络字节序 `big-endian`。有符号 16 位量按二进制补码编码。

## RT-IPC header

| offset | 大小 | 字段 | 约束 |
|---:|---:|---|---|
| offset 0 | 1 | version | 固定 `0x02` |
| offset 1 | 1 | msg_type | 下表消息类型 |
| offset 2 | 2 | payload_len | 0..1400，必须与 UDP datagram 实际长度一致 |
| offset 4 | 4 | seq_num | 发送方向独立的 32 位序号，按模 2^32 比较 |
| offset 8 | 8 | session_id | 每次连接唯一，重连递增；拒绝已退休会话的数据包 |
| offset 16 | 2 | error_code | 正常为 0；RT-IPC 错误码保留在传输层 |
| offset 18 | 2 | checksum | header checksum 置零后连同载荷计算 `CRC16-CCITT` |

消息类型：

| 值 | 名称 | 用途 |
|---:|---|---|
| `0x01` | CTRL_CMD | Linux 控制请求 |
| `0x02` | STATUS_REP | RT-Thread 状态回传 |
| `0x03` | ERROR_NOTIFY | 应用协议错误通知 |
| `0x04` | ACK | 确认累计接收序号 |
| `0x05` | SYN | 建立会话 |
| `0x06` | SYNACK | 接受会话 |
| `0x07` | HEARTBEAT | 会话保活 |
| `0x08` | HEARTBEAT_ACK | 保活确认 |
| `0x09` | FIN | 关闭会话 |

CRC 不匹配、版本错误、长度超过上限的包不会交给任务 3 控制器。应用层错误使用 ERROR_NOTIFY，而不是复用 RT-IPC header 的 error_code。

## CTRL_CMD 载荷

固定 24 字节，schema 版本为 1。

| offset | 大小 | 字段 | 值 |
|---:|---:|---|---|
| offset 0 | 1 | schema_version | `1` |
| offset 1 | 1 | command | RESET=`1`，STEP=`2`，STOP=`3` |
| offset 2 | 1 | mode | FIXED=`0`，AI=`1` |
| offset 3 | 1 | class | UNKNOWN=`0`，LEFT=`1`，CENTER=`2`，RIGHT=`3` |
| offset 4 | 2 | confidence_q15 | 0..32767 |
| offset 6 | 2 | reserved | 必须为 0 |
| offset 8 | 4 | frame_id | 模式内从 0 递增；控制器幂等键 |
| offset 12 | 8 | tx_monotonic_ns | Linux `CLOCK_MONOTONIC_RAW` 发送时间 |
| offset 20 | 4 | reserved | 必须为 0 |

RESET 将执行器位置、PWM 和最近 frame 状态清零。STEP 在 FIXED 模式强制采用 CENTER，在 AI 模式采用模型 class；置信度随请求记录但不绕过 class 校验。STOP 回传 STOPPED 后终止 RT-Thread 应用服务。

## STATUS_REP 载荷

固定 24 字节。

| offset | 大小 | 字段 | 值 |
|---:|---:|---|---|
| offset 0 | 1 | schema_version | `1` |
| offset 1 | 1 | status | OK=`0`，STOPPED=`1` |
| offset 2 | 1 | applied_class | 实际应用的 LEFT/CENTER/RIGHT |
| offset 3 | 1 | flags | bit 0 为 DUPLICATE，其余位必须为 0 |
| offset 4 | 4 | frame_id | 对应请求 frame_id |
| offset 8 | 2 | pwm | 有符号虚拟 PWM |
| offset 10 | 2 | actuator_q15 | 有符号虚拟转向位置 |
| offset 12 | 4 | processing_us | RT-Thread 控制处理微秒数 |
| offset 16 | 8 | echoed_tx_monotonic_ns | 原样回显本次 CTRL_CMD 时间戳 |

Linux 仅在 frame_id 和 echoed_tx_monotonic_ns 都匹配当前事务时接受回复。重复 frame 返回缓存的执行器、PWM 和处理结果，设置 DUPLICATE，同时更新时间戳回显为本次重发请求；因此不会再次更新控制器，仍能通过本次事务关联校验。

## ERROR_NOTIFY 载荷

固定 12 字节。

| offset | 大小 | 字段 | 值 |
|---:|---:|---|---|
| offset 0 | 1 | schema_version | `1` |
| offset 1 | 1 | category | PROTOCOL=`1`，APPLICATION=`2` |
| offset 2 | 2 | code | OK=`0`，INVALID_COMMAND=`1`，INVALID_MODE=`2`，INVALID_CLASS=`3`，INVALID_STATE=`4` |
| offset 4 | 4 | frame_id | 可解析时回显请求 frame_id |
| offset 8 | 4 | detail | codec 或控制器错误绝对值 |

错误 schema、错误载荷长度、非零 reserved 或非法枚举会产生 ERROR_NOTIFY，且不改变 PWM 或执行器。CRC 错误在 RT-IPC 层丢弃，所以不会增加应用错误计数。

## 可靠性状态机

- 每个可靠数据包的 RTO 为 `50 ms`，最多重传 `5 次`。
- 建连尝试超时为 `500 ms`，启用指数退避自动重连；Linux 初次连接总期限为 60 s。
- 正常心跳间隔 `1 s`，连续 `5 s` 未收到对端活动即判定断连。
- 单个控制事务应用回复期限为 `500 ms`；越界后强制断连、重连并重发未完成 CTRL_CMD。
- 恢复阶段总期限额外为 `30 s`。恰好落在期限边界的回复按超时处理，避免边界结果不确定。
- ACK 为累计确认；发送窗口保存未确认 datagram 并执行超时重传。
- 接收端用 expected_seq 处理乱序：超前序号直接丢弃并等待发送窗口按 RTO 重传，已接收的旧序号只重新 ACK、不再次交付。这样不会批量释放共享 reorder 缓冲区，也不会改变应用消息类型。
- 应用控制器再以 frame_id 做第二层重复包幂等保护，避免会话重连或合法重复事务造成二次动作。

Linux UDP socket 为非阻塞，单次 poll 最多 10 ms，且会裁剪到剩余事务期限。只接收配置的 RT-Thread IP/端口。RT-Thread socket 接收超时为 10 ms，每轮同时驱动 RT-IPC tick，因此重传、心跳和断连检测不依赖新入包。

## 测量与数据

Linux 在编码 CTRL_CMD 前记录 `tx_monotonic_ns`，收到匹配 STATUS_REP 后用同一 `CLOCK_MONOTONIC_RAW` 计算请求-响应 RTT。RT-Thread 用 AArch64 `cntpct_el0/cntfrq_el0` 计算 `processing_us`。客户机时钟不做同步，协议不声称单向跨客户机延迟；报告采用同侧 RTT、Linux 推理耗时和 RTOS 内部处理耗时。

每帧 CSV 包含模式、frame_id、目标、真值/预测 class、Q15 置信度、推理时间、Linux 侧重传、状态、PWM、执行器、RTOS 处理时间、RTT、错误码、重复和恢复标志。最终摘要再从 RT-Thread FINAL 标记读取发送侧重传，分别报告 Linux 与 RT-Thread 计数。
