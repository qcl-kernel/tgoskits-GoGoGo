#!/bin/bash
# Apply RT-Thread virtio-net patches for axvisor guest support
# Usage: bash apply-rtthread-patches.sh <rt-thread-source-dir>

set -e
RTDIR="$1"
if [ -z "$RTDIR" ]; then
  echo "Usage: $0 <rt-thread-source-dir>"
  exit 1
fi

BSPDIR="$RTDIR/bsp/qemu-virt64-aarch64"
PATCHDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BASE_PORT_PATCH="$PATCHDIR/0000-axvisor-aarch64-port.patch"
RTCONFIG="$BSPDIR/rtconfig.h"
RTBENCH="$(cd "$PATCHDIR/../../guests/rt-benchmark/rtthread" && pwd)"
TASK3DIR="$(cd "$PATCHDIR/../../guests/task3" && pwd)"
BENCHMARK_APPDIR="$BSPDIR/applications"

# shellcheck source=patch_helpers.sh
source "$PATCHDIR/patch_helpers.sh"

echo "Applying RT-Thread patches for axvisor..."

PATCH_STATE="$RTDIR/.axvisor-rtthread-patch-state"
PATCH_SET_DIGEST="$({
    sha256sum \
    "$PATCHDIR/0000-axvisor-aarch64-port.patch" \
    "$PATCHDIR/0009-native-qemu-memory-layout.patch" \
    "$PATCHDIR/0002-lwip-rx-mailbox-recover-notice.patch" \
    "$PATCHDIR/0003-virtio-net-reclaim-tx-used-ring.patch" \
    "$PATCHDIR/0004-virtio-net-use-rx-used-ring-head.patch" \
    "$PATCHDIR/0005-lwip-configurable-udp-recv-mailbox.patch" \
    "$PATCHDIR/0006-gicv3-use-redistributor-pending-registers.patch" \
    "$PATCHDIR/0007-gicv3-query-interrupt-enable-state.patch" \
    "$PATCHDIR/0008-aarch64-gtimer-use-absolute-deadlines.patch" \
    "$PATCHDIR/0010-virtio-net-benchmark-packet-hook.patch"
} | sha256sum | awk '{print $1}')"
if [[ -f "$PATCH_STATE" ]]; then
    if [[ "$(<"$PATCH_STATE")" != "$PATCH_SET_DIGEST" ]]; then
        echo "RT-Thread source patch state is stale; prepare a fresh source tree" >&2
        exit 1
    fi
    export TGOSKITS_SKIP_PATCH_APPLICATION=1
    echo "Validated existing RT-Thread patch-set state"
else
    export TGOSKITS_SKIP_PATCH_APPLICATION=0
fi

# Start from the complete AArch64 guest port. This patch contains the BSP,
# MMU, toolchain, GIC, and virtio foundations that the focused fixes below
# build on. Verify the reverse form as well so repeated builds are idempotent.
apply_patch_exactly "$RTDIR" "$BASE_PORT_PATCH" "the AxVisor AArch64 base port"

# The guest image is loaded from the 0x40000000 RAM region, while AxVisor
# reserves its low guest address space for firmware and runtime mappings. Keep
# the image's linked entry at the configured 2 MiB offset so the raw binary
# and the VM configuration describe the same address.
GUEST_MEMORY_LAYOUT_PATCH="$PATCHDIR/0009-native-qemu-memory-layout.patch"
apply_patch_exactly "$RTDIR" "$GUEST_MEMORY_LAYOUT_PATCH" \
    "the RT-Thread guest memory layout"

# 0. Remove RT_USING_VIRTIO_MMIO_ALIGN: with this macro enabled, the compiler
#    may emit sub-32-bit volatile loads/stores for virtio_mmio_config fields,
#    which some hypervisor transports reject. We use the natural (non-packed)
#    layout instead, since all fields are uint32_t and already aligned.
sed -i '/RT_USING_VIRTIO_MMIO_ALIGN/d' "$RTCONFIG"
echo "Removed RT_USING_VIRTIO_MMIO_ALIGN from rtconfig.h"

# 1. The base port supplies the static-IP, virtio-net, and AArch64 BSP config.

# 1b. Enable SAL/socket support for RT-IPC UDP server
if ! grep -q "RT_USING_SAL" "$RTCONFIG"; then
  echo "" >> "$RTCONFIG"
  echo "/* SAL/socket support for RT-IPC */" >> "$RTCONFIG"
  echo "#define RT_USING_SAL 1" >> "$RTCONFIG"
  echo "#define SAL_USING_POSIX 1" >> "$RTCONFIG"
  echo "#define SAL_SOCKET_NUM 16" >> "$RTCONFIG"
  echo "Enabled SAL/socket support in rtconfig.h"
fi

# RT-IPC sends an ACK followed immediately by the next request.  The upstream
# UDP recv mailbox has one slot, so the tcpip thread can enqueue the ACK and
# then drop the request before the socket thread runs.  Keep the mailbox and
# netbuf pool large enough for a bounded receive burst.
if ! grep -q '^#define RT_LWIP_UDP_RECVMBOX_SIZE' "$RTCONFIG"; then
  echo "#define RT_LWIP_UDP_RECVMBOX_SIZE 16" >> "$RTCONFIG"
fi
if ! grep -q '^#define MEMP_NUM_NETBUF' "$RTCONFIG"; then
  echo "#define MEMP_NUM_NETBUF 16" >> "$RTCONFIG"
fi

# 2. virtio.h: VA2PA safe fallback
# 3. virtio.c: 64-bit queue address setup
# 4. virtio_net.c: Volatile feature negotiation and interrupt-only RX

# 4b. lwIP RX notification must remain recoverable when the Ethernet RX
# mailbox is momentarily full. Keep interrupt-only RX, but do not leave
# rx_notice set after a failed nonblocking mailbox send.
RX_MAILBOX_PATCH="$PATCHDIR/0002-lwip-rx-mailbox-recover-notice.patch"
apply_patch_exactly "$RTDIR" "$RX_MAILBOX_PATCH" "the lwIP RX mailbox fix"

# Do not unconditionally wake the RX thread from every virtio-net interrupt.
# That change was tested with the mailbox fix and regressed to a first-request
# deadlock. Keep the upstream conditional wake; correctness is provided by the
# recoverable rx_notice coalescing fix above.

TX_USED_RECLAIM_PATCH="$PATCHDIR/0003-virtio-net-reclaim-tx-used-ring.patch"
apply_patch_exactly "$RTDIR" "$TX_USED_RECLAIM_PATCH" \
    "the virtio-net TX used-ring reclaim fix"

# 3b. Virtio-net RX completions must use the exact chain head published in the
# used ring.  Deriving the data descriptor as used_id + 1 reads the wrong
# descriptor after any non-zero head and corrupts packet reassembly.  Initial
# RX descriptors must also reference info[i].hdr, not info[i].tx_buffer.
RX_USED_HEAD_PATCH="$PATCHDIR/0004-virtio-net-use-rx-used-ring-head.patch"
apply_patch_exactly "$RTDIR" "$RX_USED_HEAD_PATCH" \
    "the virtio-net RX used-ring head fix"

UDP_RECV_MBOX_PATCH="$PATCHDIR/0005-lwip-configurable-udp-recv-mailbox.patch"
apply_patch_exactly "$RTDIR" "$UDP_RECV_MBOX_PATCH" \
    "the lwIP UDP receive mailbox configuration"

# RT-Thread 5.2.2 uses the removed GICv2 SPENDSGIR/CPENDSGIR registers for
# local SGI pending operations even when the BSP selects GICv3.  Use the
# current CPU's redistributor pending registers for SGIs and PPIs instead.
GICV3_PENDING_PATCH="$PATCHDIR/0006-gicv3-use-redistributor-pending-registers.patch"
apply_patch_exactly "$RTDIR" "$GICV3_PENDING_PATCH" \
    "the GICv3 pending-register fix"

# The SGI latency benchmark temporarily owns INTID 7. Query the pre-existing
# enable bit so cleanup can restore both enabled and disabled callers exactly.
GIC_ENABLE_QUERY_PATCH="$PATCHDIR/0007-gicv3-query-interrupt-enable-state.patch"
apply_patch_exactly "$RTDIR" "$GIC_ENABLE_QUERY_PATCH" \
    "the GICv3 interrupt enable-state query"

# The upstream AArch64 BSP rearms its periodic timer with a relative TVAL from
# inside the ISR. Every interrupt-delivery delay therefore lengthens the next
# period and accumulates phase error. Keep an absolute CNTV_CVAL deadline and
# account for every elapsed tick instead. The BSP must also consistently use
# the virtual timer for enable, disable, value access, and PPI 27 delivery.
GTIMER_DEADLINE_PATCH="$PATCHDIR/0008-aarch64-gtimer-use-absolute-deadlines.patch"
apply_patch_exactly "$RTDIR" "$GTIMER_DEADLINE_PATCH" \
    "the absolute virtual-timer deadline fix"

# Expose the RX packet bytes alongside the used-ring position to the
# benchmark-only hook. This lets the benchmark select its UDP probe packets
# without counting concurrent Task 2/3 traffic as IRQ samples.
NET_BENCH_HOOK_PATCH="$PATCHDIR/0010-virtio-net-benchmark-packet-hook.patch"
apply_patch_exactly "$RTDIR" "$NET_BENCH_HOOK_PATCH" \
    "the virtio-net benchmark packet hook"

if [[ "$TGOSKITS_SKIP_PATCH_APPLICATION" == 0 ]]; then
    printf '%s\n' "$PATCH_SET_DIGEST" >"$PATCH_STATE"
    echo "Recorded RT-Thread patch-set state"
fi

# 5. Install RT-IPC server into BSP applications
GUESTDIR="$(cd "$PATCHDIR/../../guests/rt-ipc" && pwd)"
APPDIR="$BSPDIR/applications/rt-ipc-test"
mkdir -p "$APPDIR"
cp "$GUESTDIR/rtthread/rtipc_server.c" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_echo_responder.c" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_echo_responder.h" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_peer.c" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_peer.h" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_server_status.c" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_server_status.h" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_time.c" "$APPDIR/"
cp "$GUESTDIR/rtthread/rtipc_time.h" "$APPDIR/"
cp "$GUESTDIR/common/rt_ipc.c" "$APPDIR/"
cp "$GUESTDIR/common/rt_ipc.h" "$APPDIR/"
cp "$GUESTDIR/rtthread/SConscript" "$APPDIR/"
echo "Installed RT-IPC server into $APPDIR"

# Task 3 reuses the RT-IPC implementation compiled by rt-ipc-test. Install
# only its application sources and the shared v2 header to avoid duplicate
# protocol symbols in the final image.
TASK3_APPDIR="$BSPDIR/applications/task3"
mkdir -p "$TASK3_APPDIR"
cp "$TASK3DIR/src/rtthread/task3_server.c" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/rtthread/SConscript" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/controller.c" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/controller.h" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/task3_protocol.c" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/task3_protocol.h" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/session.c" "$TASK3_APPDIR/"
cp "$TASK3DIR/src/common/session.h" "$TASK3_APPDIR/"
cp "$GUESTDIR/common/rt_ipc.h" "$TASK3_APPDIR/"
rm -f -- "$TASK3_APPDIR/rt_ipc.c"
echo "Installed Task 3 server into $TASK3_APPDIR"

# 6. Install the canonical benchmark source.  Keeping this in tgoskits makes
# benchmark fixes reviewable and prevents a previously generated RT-Thread
# source tree from silently supplying stale measurement code.
cp "$RTBENCH/rt_benchmark.c" "$BENCHMARK_APPDIR/rt_benchmark.c"
echo "Installed RT benchmark into $BENCHMARK_APPDIR"

echo "Patches are applied in-place in the RT-Thread source tree."
echo "Key changes:"
echo "  - rtconfig.h: RT_LWIP_DHCP removed, IP addresses quoted, virtio-net enabled"
echo "  - rtconfig.h: SAL/socket support enabled for RT-IPC"
echo "  - virtio.h: _virtio_va2pa_safe() with identity mapping fallback"  
echo "  - virtio.c: 64-bit queue registers with 44-bit PA mask"
echo "  - virtio_net.c: volatile feature negotiation, interrupt-only RX"
echo "  - virtio_net.c: separate TX and RX descriptor buffers"
echo "  - lwIP: 16-slot UDP receive mailbox and matching netbuf pool"
echo "  - GICv3: local SGI/PPI pending state uses redistributor registers"
echo "  - AArch64 GIC: interrupt enable state is queryable for benchmark cleanup"
echo "  - AArch64 timer: absolute CNTV deadlines with elapsed-tick compensation"
echo "  - applications/rt-ipc-test/: RT-IPC UDP server installed"
echo "  - applications/task3/: Task 3 UDP/9877 control server installed"
echo "  - applications/rt_benchmark.c: canonical real-time benchmark installed"
