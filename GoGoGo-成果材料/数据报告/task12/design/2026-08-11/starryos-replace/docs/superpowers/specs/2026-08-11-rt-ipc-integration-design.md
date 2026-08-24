# RT-IPC Protocol Integration Design

> **Status:** Approved
> **Date:** 2026-08-11
> **Branch:** `rtthread-guest`

## Goal

Integrate the RT-IPC reliable UDP protocol from `protocol/` into the current Axvisor two-guest (Linux + RT-Thread) project, enabling Linux and RT-Thread to communicate over virtio-net using a custom application-layer protocol with handshake, CRC, ACK-based retransmission, heartbeat, and auto-reconnect.

## Architecture

Linux (client, 192.168.77.11) sends `RTIPC_MSG_CTRL_CMD` to RT-Thread (server, 192.168.77.30:9876/UDP). RT-Thread echoes back `RTIPC_MSG_STATUS_REP`. Both sides compile the same C protocol core (`rt_ipc.c`), avoiding implementation drift.

## Approach: Shared C Protocol Core

A single C implementation (`rt_ipc.c` + `rt_ipc.h`) is compiled into both Linux and RT-Thread. Thin platform adapters handle socket I/O.

## Protocol Overview

- 12-byte header: version(1) + msg_type(1) + payload_len(2) + seq_num(4) + error_code(2) + checksum(2)
- Big-endian serialization, CRC16-CCITT over header (checksum=0) + payload
- Max payload: 1400 bytes, no dynamic allocation
- Message types: CTRL_CMD, STATUS_REP, ERROR_NOTIFY, ACK, SYN, SYNACK, HEARTBEAT, HEARTBEAT_ACK, FIN
- Connection states: CLOSED -> SYN_SENT -> SYN_RECEIVED -> CONNECTED -> SHUTDOWN / RECONNECTING
- Features: cumulative ACK, sliding window (64), reorder buffer (64), heartbeat, timeout-based retransmission, exponential-backoff auto-reconnect

## File Structure

- `os/axvisor/guests/rt-ipc/common/rt_ipc.h` - Protocol API and wire format
- `os/axvisor/guests/rt-ipc/common/rt_ipc.c` - State machine, CRC, ACK, retransmission
- `os/axvisor/guests/rt-ipc/linux/rtipc_client.c` - Linux UDP client with statistics
- `os/axvisor/guests/rt-ipc/linux/Makefile` - AArch64 static cross-compile
- `os/axvisor/guests/rt-ipc/rtthread/rtipic_server.c` - RT-Thread UDP server thread
- `os/axvisor/guests/rt-ipc/rtthread/SConscript` - RT-Thread build integration
- `os/axvisor/guests/rt-ipc/tests/protocol_test.c` - Unit tests (host-compiled)
- `os/axvisor/guests/rt-ipc/tests/loopback_test.c` - Reliability tests (host-compiled)

## Thread Models

### RT-Thread Server

- One protocol thread `rtipic_server`, priority 15, 64 KB stack
- bind() on 0.0.0.0:9876, blocks on recvfrom() with SO_RCVTIMEO = 100 ms
- virtio-net interrupt -> lwIP wakes thread -> on_recv() -> CRC verify -> deliver -> send STATUS_REP
- Timeout wakeup -> tick() -> heartbeat, retransmission, connection timeout
- No polling timer

### Linux Client

- Single thread, select() with 100 us timeout
- SYN/SYNACK handshake, then 1000 x CTRL_CMD/STATUS_REP round-trips per payload size
- Payload sizes: 64B, 256B, 1024B
- After 500 messages: 3-second simulated disconnect, then reconnect
- Final: FIN, print statistics

## Error Handling

### RT-Thread Server

- recvfrom timeout: normal, run tick()
- sendto failure: log, next tick() retransmits
- CRC mismatch: discard silently
- Connection timeout: enter RECONNECTING, clear window/reorder
- lwIP pbuf exhaustion: covered by retransmission

### Linux Client

- select timeout: run tick(), check retransmission/heartbeat
- Reconnect failure: exponential backoff, max 10 s, max 5 retries
- Total time > 120 s: report partial statistics, exit

## Measured Metrics

Per payload size (64B, 256B, 1024B): RTT min/avg/max/P50/P95/P99, throughput KB/s, packet loss rate, retransmission count, CRC error count, reconnect latency.

## Testing Strategy

### Layer 1: Protocol Core Unit Tests (host-compiled)

Header serialize/parse round-trip, CRC16 correctness, SYN -> SYNACK -> CONNECTED, cumulative ACK, reorder buffer, duplicate filtering, CRC failure discard. Translated from Rust tests.

### Layer 2: Reliability Loopback Tests (host-compiled)

Inject loss, delay, duplication, reordering. Validate retransmission, reorder recovery, auto-reconnect, heartbeat.

### Layer 3: End-to-End QEMU Integration Test

Full build + launch both guests. Verify ALL TESTS COMPLETE, extract statistics.

## Build Integration

### apply-rtthread-patches.sh

1. Enable RT_USING_SAL and SAL_USING_POSIX in rtconfig.h
2. Install rt_ipc.c, rt_ipc.h, rtipic_server.c, SConscript into BSP applications/rt-ipc-test/

### Linux initramfs

Cross-compile rtipc_client statically, add to cpio as /bin/rtipc-client. Update init-linux-1 to run it after network config.

### New: run_rtipc_test.sh

One-command build + launch + result collection.

## Out of Scope

Multiple peers, TLS, version negotiation, bandwidth optimization, Rust on Linux side, TCP/HRPC.
