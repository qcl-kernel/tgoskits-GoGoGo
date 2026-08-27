# Protocol Benchmark Analysis: RT-IPC (UDP) vs HRPC (TCP)

## Environment
- Host: x86_64 Linux (local loopback)
- Rust: 1.95.0, release profile (opt-level=3, lto=thin)
- Test: 1000 iterations for latency, 3s duration for bandwidth

## 1. Latency (Round-Trip Time)

RT-IPC (UDP) consistently outperforms HRPC (TCP) in latency:

| Payload | RT-IPC mean | HRPC mean | RT-IPC p99 | HRPC p99 |
|---------|-------------|-----------|-------------|----------|
| 0 B     | 6.1 us      | 10.9 us   | 12.4 us     | 17.5 us  |
| 64 B    | 7.0 us      | 11.8 us   | 9.6 us      | 21.7 us  |
| 256 B   | 8.3 us      | 12.4 us   | 13.8 us     | 15.5 us  |
| 1024 B  | 13.3 us     | 19.1 us   | 20.1 us     | 35.0 us  |
| 4096 B  | N/A (1400B max) | 35.3 us | N/A       | 42.8 us  |
| 8192 B  | N/A         | 60.3 us   | N/A         | 102.6 us |

**Key finding:** RT-IPC has ~40% lower median latency than HRPC across all
comparable payload sizes. This is expected: UDP avoids TCP's connection state
tracking, sequence validation, and ack piggybacking overhead.

RT-IPC cannot handle payloads > 1400 bytes (by design, to avoid IP fragmentation).
HRPC handles up to 64KB per frame via TCP stream.

## 2. Bandwidth (Throughput)

| Payload | RT-IPC Mbps | HRPC Mbps | RT-IPC pkt/s | HRPC pkt/s |
|---------|-------------|-----------|---------------|------------|
| 64 B    | 443         | 465       | 729K          | 631K       |
| 256 B   | 1236        | 1100      | 576K          | 484K       |
| 1024 B  | 2587        | 2439      | 312K          | 290K       |
| 1400 B  | 2972        | 3012      | 263K          | 264K       |
| 4096 B  | N/A         | 4130      | N/A           | 125K       |
| 16384 B | N/A         | 4998      | N/A           | 38K        |
| 65536 B | N/A         | 5230      | N/A           | 10K        |

**Key finding:** At comparable payload sizes (<=1400B), throughput is nearly
identical (~3 Gbps). RT-IPC has slightly higher packet rate at small sizes due
to lower per-packet overhead (12B vs 28B header+trailer). HRPC pulls ahead at
larger payloads thanks to TCP's batching and fewer syscalls per byte.

## 3. Memory Footprint

| Component          | RT-IPC/UDP | HRPC/TCP |
|--------------------|------------|----------|
| Per-packet header  | 12 B       | 24 B     |
| Reliability state  | 25 KB      | 8.5 KB   |
| Total RSS          | 2.79 MB    | 2.79 MB  |

RT-IPC uses more memory for its reorder buffer (64 entries x ~324B) and send
window (16 pending packets). HRPC's memory is dominated by the FrameReader
buffer (8KB) and is lighter overall.

## 4. Reconnect (HRPC only)

HRPC successfully reconnects after server kill in ~100ms (first attempt).
Post-reconnect data flow verified. RT-IPC has no connection concept (stateless
UDP) so reconnect is N/A.

## Recommendations

- **For latency-critical control commands** (small payloads, < 1400B): RT-IPC/UDP
  provides the lowest latency with ~6us median RTT.
- **For bulk data transfer or payloads > 1400B**: HRPC/TCP is the better choice,
  with 5+ Gbps throughput and no payload size limitation.
- **For simplicity**: HRPC/TCP requires less application-layer reliability code
  (TCP handles ACK/retransmission/reorder natively).
- **For deterministic timing**: RT-IPC/UDP avoids TCP's congestion control pauses,
  making latency more predictable (though at the cost of manual reliability).

