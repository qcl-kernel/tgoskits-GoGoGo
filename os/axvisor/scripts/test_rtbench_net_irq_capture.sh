#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
BENCH="$ROOT/os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c"
PATCH="$ROOT/os/axvisor/patches/rtthread/0010-virtio-net-benchmark-packet-hook.patch"

grep -Fq 'void rt_virtio_net_rx_irq_hook(rt_uint16_t used_idx,' "$BENCH" || {
    echo "RT benchmark hook must receive RX packet context" >&2
    exit 1
}
grep -Fq 'volatile uint32_t irq_dropped;' "$BENCH" || {
    echo "RT benchmark must report dropped RX samples" >&2
    exit 1
}
grep -Fq 'uint64_t *irq_ticks;' "$BENCH" || {
    echo "RT benchmark must keep IRQ timestamps keyed by probe sequence" >&2
    exit 1
}
grep -Fq 'volatile uint8_t *irq_valid;' "$BENCH" || {
    echo "RT benchmark must track validity for sequence-keyed IRQ timestamps" >&2
    exit 1
}
grep -Fq 'trigger_socket_failures' "$BENCH" || {
    echo "RT benchmark must report trigger socket failures" >&2
    exit 1
}
grep -Fq 'trigger_send_failures' "$BENCH" || {
    echo "RT benchmark must report trigger send failures" >&2
    exit 1
}
grep -Fq 'trigger_attempts' "$BENCH" || {
    echo "RT benchmark must report trigger attempts" >&2
    exit 1
}
grep -Fq 'rtbench_net_event_take_irq(sequence, &irq_ticks)' "$BENCH" || {
    echo "RT benchmark must pair socket packets with IRQ timestamps by sequence" >&2
    exit 1
}
if grep -Fq 'RTBENCH_NET_IRQ_RING_CAPACITY' "$BENCH"; then
    echo "RT benchmark must not use a fixed FIFO for network IRQ samples" >&2
    exit 1
fi
grep -Fq 'rx_irq_used_idx' "$PATCH" || {
    echo "RT-Thread virtio-net patch must keep an independent IRQ scan cursor" >&2
    exit 1
}
grep -Fq 'scan_idx = virtio_net_dev->rx_irq_used_idx' "$PATCH" || {
    echo "RT-Thread virtio-net ISR must not rescan from the RX consumer cursor" >&2
    exit 1
}
grep -Fq 'virtio_net_dev->rx_irq_used_idx = scan_idx' "$PATCH" || {
    echo "RT-Thread virtio-net ISR must advance the independent IRQ scan cursor" >&2
    exit 1
}
grep -Fq 'rt_virtio_net_rx_irq_hook(' "$PATCH" || {
    echo "RT-Thread virtio-net patch must pass RX packet context to the hook" >&2
    exit 1
}
grep -Fq 'virtio_net_dev->info[used_id / 2].rx_buffer' "$PATCH" || {
    echo "RT-Thread virtio-net patch must expose the matching RX buffer" >&2
    exit 1
}

echo "RT benchmark RX IRQ packet-capture contract: PASS"
