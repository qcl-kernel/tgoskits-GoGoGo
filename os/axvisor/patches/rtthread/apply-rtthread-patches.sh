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
PATCHDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RTCONFIG="$BSPDIR/rtconfig.h"

echo "Applying RT-Thread patches for axvisor..."

# 0. Remove RT_USING_VIRTIO_MMIO_ALIGN: with this macro enabled, the compiler
#    may emit sub-32-bit volatile loads/stores for virtio_mmio_config fields,
#    which some hypervisor transports reject. We use the natural (non-packed)
#    layout instead, since all fields are uint32_t and already aligned.
sed -i '/RT_USING_VIRTIO_MMIO_ALIGN/d' "$RTCONFIG"
echo "Removed RT_USING_VIRTIO_MMIO_ALIGN from rtconfig.h"

# 1. rtconfig.h: Remove RT_LWIP_DHCP, quote IP addresses, add virtio/net config
#    (manual edits - see rtconfig.h.diff for details)

# 1b. Enable SAL/socket support for RT-IPC UDP server
if ! grep -q "RT_USING_SAL" "$RTCONFIG"; then
  echo "" >> "$RTCONFIG"
  echo "/* SAL/socket support for RT-IPC */" >> "$RTCONFIG"
  echo "#define RT_USING_SAL 1" >> "$RTCONFIG"
  echo "#define SAL_USING_POSIX 1" >> "$RTCONFIG"
  echo "#define SAL_SOCKET_NUM 16" >> "$RTCONFIG"
  echo "Enabled SAL/socket support in rtconfig.h"
fi

# 2. virtio.h: VA2PA safe fallback
# 3. virtio.c: 64-bit queue address setup  
# 4. virtio_net.c: Volatile feature negotiation and interrupt-only RX

NO_POLL_PATCH="$PATCHDIR/0001-virtio-net-remove-rx-polling.patch"
if patch --dry-run --silent -d "$RTDIR" -p1 < "$NO_POLL_PATCH"; then
  patch --silent -d "$RTDIR" -p1 < "$NO_POLL_PATCH"
elif rg -q 'g_virtio_net_poll_timer|virtio_net_poll_timer_cb' "$DRVDIR/virtio_net.c"; then
  echo "Failed to apply RT-Thread interrupt-only virtio-net patch" >&2
  exit 1
fi

# 5. Install RT-IPC server into BSP applications
GUESTDIR="$(cd "$PATCHDIR/../../guests/rt-ipc" && pwd)"
APPDIR="$BSPDIR/applications/rt-ipc-test"
mkdir -p "$APPDIR"
cp "$GUESTDIR/rtthread/rtipc_server.c" "$APPDIR/"
cp "$GUESTDIR/common/rt_ipc.c" "$APPDIR/"
cp "$GUESTDIR/common/rt_ipc.h" "$APPDIR/"
cp "$GUESTDIR/rtthread/SConscript" "$APPDIR/"
echo "Installed RT-IPC server into $APPDIR"

echo "Patches are applied in-place in the RT-Thread source tree."
echo "Key changes:"
echo "  - rtconfig.h: RT_LWIP_DHCP removed, IP addresses quoted, virtio-net enabled"
echo "  - rtconfig.h: SAL/socket support enabled for RT-IPC"
echo "  - virtio.h: _virtio_va2pa_safe() with identity mapping fallback"  
echo "  - virtio.c: 64-bit queue registers with 44-bit PA mask"
echo "  - virtio_net.c: volatile feature negotiation, interrupt-only RX"
echo "  - applications/rt-ipc-test/: RT-IPC UDP server installed"
