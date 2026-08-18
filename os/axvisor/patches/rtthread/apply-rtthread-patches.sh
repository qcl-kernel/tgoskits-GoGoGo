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
DRVDIR="$RTDIR/components/drivers/virtio"
GTIMER="$RTDIR/libcpu/aarch64/common/gtimer.c"
GTIMER_HEADER="$RTDIR/libcpu/aarch64/common/include/gtimer.h"
CPU_ASM="$RTDIR/libcpu/aarch64/common/cpu_gcc.S"
PATCHDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BASE_PORT_PATCH="$PATCHDIR/0000-axvisor-aarch64-port.patch"
RTCONFIG="$BSPDIR/rtconfig.h"
RTBENCH="$(cd "$PATCHDIR/../../guests/rt-benchmark/rtthread" && pwd)"
BENCHMARK_APPDIR="$BSPDIR/applications"

echo "Applying RT-Thread patches for axvisor..."

# Start from the complete AArch64 guest port. This patch contains the BSP,
# MMU, toolchain, GIC, and virtio foundations that the focused fixes below
# build on. Verify the reverse form as well so repeated builds are idempotent.
if git -C "$RTDIR" apply --check "$BASE_PORT_PATCH"; then
  git -C "$RTDIR" apply "$BASE_PORT_PATCH"
  echo "Applied the AxVisor AArch64 base port"
elif git -C "$RTDIR" apply --check --reverse "$BASE_PORT_PATCH"; then
  echo "AxVisor AArch64 base port is already applied"
else
  echo "RT-Thread source does not match the pinned base port" >&2
  exit 1
fi

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

NO_POLL_PATCH="$PATCHDIR/0001-virtio-net-remove-rx-polling.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$NO_POLL_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$NO_POLL_PATCH"
elif rg -q 'g_virtio_net_poll_timer|virtio_net_poll_timer_cb' "$DRVDIR/virtio_net.c"; then
    echo "RT-Thread virtio-net source is not in the interrupt-only state" >&2
    exit 1
fi

# 4b. lwIP RX notification must remain recoverable when the Ethernet RX
# mailbox is momentarily full. Keep interrupt-only RX, but do not leave
# rx_notice set after a failed nonblocking mailbox send.
RX_MAILBOX_PATCH="$PATCHDIR/0002-lwip-rx-mailbox-recover-notice.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$RX_MAILBOX_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$RX_MAILBOX_PATCH"
elif ! rg -q 'Clear the coalescing flag' "$RTDIR/components/net/lwip/port/ethernetif.c"; then
    echo "Failed to verify RT-Thread lwIP RX mailbox fix" >&2
    exit 1
fi

# Do not unconditionally wake the RX thread from every virtio-net interrupt.
# That change was tested with the mailbox fix and regressed to a first-request
# deadlock. Keep the upstream conditional wake; correctness is provided by the
# recoverable rx_notice coalescing fix above.

TX_USED_RECLAIM_PATCH="$PATCHDIR/0003-virtio-net-reclaim-tx-used-ring.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$TX_USED_RECLAIM_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$TX_USED_RECLAIM_PATCH"
elif ! rg -q 'Reclaim completed TX chains' "$DRVDIR/virtio_net.c"; then
    echo "Failed to verify RT-Thread virtio-net TX used-ring reclaim fix" >&2
    exit 1
fi

# 3b. Virtio-net RX completions must use the exact chain head published in the
# used ring.  Deriving the data descriptor as used_id + 1 reads the wrong
# descriptor after any non-zero head and corrupts packet reassembly.  Initial
# RX descriptors must also reference info[i].hdr, not info[i].tx_buffer.
RX_USED_HEAD_PATCH="$PATCHDIR/0004-virtio-net-use-rx-used-ring-head.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$RX_USED_HEAD_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$RX_USED_HEAD_PATCH"
elif ! rg -q 'id = used_id' "$DRVDIR/virtio_net.c"; then
    echo "Failed to verify RT-Thread virtio-net RX used-ring head fix" >&2
    exit 1
fi

UDP_RECV_MBOX_PATCH="$PATCHDIR/0005-lwip-configurable-udp-recv-mailbox.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$UDP_RECV_MBOX_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$UDP_RECV_MBOX_PATCH"
elif ! rg -q 'DEFAULT_UDP_RECVMBOX_SIZE[[:space:]]+RT_LWIP_UDP_RECVMBOX_SIZE' \
    "$RTDIR/components/net/lwip/port/lwipopts.h"; then
    echo "Failed to verify RT-Thread lwIP UDP receive mailbox configuration" >&2
    exit 1
fi

# RT-Thread 5.2.2 uses the removed GICv2 SPENDSGIR/CPENDSGIR registers for
# local SGI pending operations even when the BSP selects GICv3.  Use the
# current CPU's redistributor pending registers for SGIs and PPIs instead.
GICV3_PENDING_PATCH="$PATCHDIR/0006-gicv3-use-redistributor-pending-registers.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$GICV3_PENDING_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$GICV3_PENDING_PATCH"
elif ! rg -q 'arm_gic_get_pending_irq' \
        "$RTDIR/libcpu/aarch64/common/gicv3.c" || \
    ! rg -q 'GIC_RDISTSGI_ISPENDR0.*redist_hw_base\[cpu_id\]' \
        "$RTDIR/libcpu/aarch64/common/gicv3.c" || \
    ! rg -q 'GIC_RDISTSGI_ICPENDR0.*redist_hw_base\[cpu_id\].*= mask' \
        "$RTDIR/libcpu/aarch64/common/gicv3.c"; then
    echo "Failed to verify RT-Thread GICv3 pending-register fix" >&2
    exit 1
fi

# The SGI latency benchmark temporarily owns INTID 7. Query the pre-existing
# enable bit so cleanup can restore both enabled and disabled callers exactly.
GIC_ENABLE_QUERY_PATCH="$PATCHDIR/0007-gicv3-query-interrupt-enable-state.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$GIC_ENABLE_QUERY_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$GIC_ENABLE_QUERY_PATCH"
elif ! rg -q 'rt_hw_interrupt_get_enable' \
        "$RTDIR/libcpu/aarch64/common/interrupt.c" || \
    ! rg -q 'arm_gic_get_enable_irq' \
        "$RTDIR/libcpu/aarch64/common/gic.c" || \
    ! rg -q 'arm_gic_get_enable_irq' \
        "$RTDIR/libcpu/aarch64/common/gicv3.c"; then
    echo "Failed to verify RT-Thread interrupt enable-state query" >&2
    exit 1
fi

# The upstream AArch64 BSP rearms its periodic timer with a relative TVAL from
# inside the ISR. Every interrupt-delivery delay therefore lengthens the next
# period and accumulates phase error. Keep an absolute CNTV_CVAL deadline and
# account for every elapsed tick instead. The BSP must also consistently use
# the virtual timer for enable, disable, value access, and PPI 27 delivery.
GTIMER_DEADLINE_PATCH="$PATCHDIR/0008-aarch64-gtimer-use-absolute-deadlines.patch"
if patch --dry-run --forward --silent -d "$RTDIR" -p1 < "$GTIMER_DEADLINE_PATCH"; then
    patch --silent -d "$RTDIR" -p1 < "$GTIMER_DEADLINE_PATCH"
elif ! rg -q 'timer_deadline \+= timer_step' "$GTIMER" || \
    ! rg -q 'while \(timer_deadline <= now\)' "$GTIMER" || \
    ! rg -q 'rt_hw_sysreg_write\(CNTV_CVAL_EL0, timer_deadline\)' "$GTIMER" || \
    ! rg -q 'msr[[:space:]]+CNTV_CTL_EL0, xzr' "$GTIMER_HEADER" || \
    ! rg -q 'msr[[:space:]]+CNTV_CTL_EL0, x0' "$CPU_ASM" || \
    ! rg -q 'msr[[:space:]]+CNTV_TVAL_EL0, x0' "$CPU_ASM"; then
    echo "Failed to verify RT-Thread absolute virtual-timer deadline fix" >&2
    exit 1
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
echo "  - lwIP: 16-slot UDP receive mailbox and matching netbuf pool"
echo "  - GICv3: local SGI/PPI pending state uses redistributor registers"
echo "  - AArch64 GIC: interrupt enable state is queryable for benchmark cleanup"
echo "  - AArch64 timer: absolute CNTV deadlines with elapsed-tick compensation"
echo "  - applications/rt-ipc-test/: RT-IPC UDP server installed"
echo "  - applications/rt_benchmark.c: canonical real-time benchmark installed"
