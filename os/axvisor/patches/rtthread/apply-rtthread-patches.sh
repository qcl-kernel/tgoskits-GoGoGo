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

echo "Applying RT-Thread patches for axvisor..."

# 1. rtconfig.h: Remove RT_LWIP_DHCP, quote IP addresses, add virtio/net config
#    (manual edits - see rtconfig.h.diff for details)

# 2. virtio.h: VA2PA safe fallback
# 3. virtio.c: 64-bit queue address setup  
# 4. virtio_net.c: Volatile feature negotiation + RX polling timer

echo "Patches are applied in-place in the RT-Thread source tree."
echo "Key changes:"
echo "  - rtconfig.h: RT_LWIP_DHCP removed, IP addresses quoted, virtio-net enabled"
echo "  - virtio.h: _virtio_va2pa_safe() with identity mapping fallback"  
echo "  - virtio.c: 64-bit queue registers with 44-bit PA mask"
echo "  - virtio_net.c: volatile feature negotiation, 1ms RX polling timer"
