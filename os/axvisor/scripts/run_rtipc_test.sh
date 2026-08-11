#!/bin/bash
# RT-IPC End-to-End QEMU Integration Test
# Builds RT-Thread (with SAL/RT-IPC server), Linux initramfs (with rtipc-client),
# Axvisor, then launches QEMU and collects results.
set -e

ROOT="/home/yfblock/Code/hyper-rtos/.worktrees/rtthread-guest"
cd "$ROOT"

QEMU="/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64"
AXVISOR_BIN="target/aarch64-unknown-none-softfloat/release/axvisor.bin"
RTTHREAD_SRC="tmp/rt-thread-5.2.2"
INITRAMFS="tmp/vmconfigs/two-guest-net/current/linux-1-initramfs.cpio"
LOG="tmp/rtipc-test.log"

echo "=== RT-IPC Integration Test ==="

# 1. Apply RT-Thread patches and build
echo "[1/5] Building RT-Thread with SAL/socket and RT-IPC server..."
bash os/axvisor/patches/rtthread/apply-rtthread-patches.sh "$RTTHREAD_SRC"
uv run --with scons scons -C "$RTTHREAD_SRC/bsp/qemu-virt64-aarch64" -j4

# 2. Cross-compile Linux client
echo "[2/5] Building rtipc-client..."
make -C os/axvisor/guests/rt-ipc/linux

# 3. Rebuild initramfs with client binary
echo "[3/5] Rebuilding Linux initramfs..."
STAGING=$(mktemp -d)
cd "$ROOT/tmp/vmconfigs/two-guest-net/current"
gzip -dc linux-1-initramfs.cpio 2>/dev/null | (cd "$STAGING" && cpio --quiet -id) 2>/dev/null || true
# If not gzipped, try plain cpio
if [ ! -f "$STAGING/init" ]; then
  (cd "$STAGING" && cpio --quiet -id < linux-1-initramfs.cpio) 2>/dev/null || true
fi
cd "$ROOT"
cp os/axvisor/guests/rt-ipc/linux/target/rtipic-client "$STAGING/bin/rtipic-client"
chmod +x "$STAGING/bin/rtipic-client"
# Update init script
cp os/axvisor/guests/linux-net/init-linux-1 "$STAGING/init"
chmod +x "$STAGING/init"
(cd "$STAGING" && find . -print0 | cpio --null -o --format=newc > "$ROOT/$INITRAMFS")
rm -rf "$STAGING"
echo "  initramfs rebuilt: $(ls -la "$INITRAMFS")"

# 4. Build Axvisor
echo "[4/5] Building Axvisor..."
AX_CONFIG_PATH=os/axvisor/qemu-aarch64-two-guest-net \
AXVISOR_VM_CONFIGS="$ROOT/os/axvisor/configs/vms/qemu/aarch64/linux-net.toml:$ROOT/os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml" \
cargo build --release --features qemu-aarch64-two-guest-net -p axvisor
aarch64-linux-gnu-objcopy -O binary target/aarch64-unknown-none-softfloat/release/axvisor "$AXVISOR_BIN"

# 5. Launch QEMU
echo "[5/5] Launching QEMU..."
pkill -9 -f qemu-system-aarch64 2>/dev/null || true
sleep 1

timeout 120 "$QEMU" \
  -nographic \
  -cpu cortex-a72 \
  -machine virt,virtualization=on,gic-version=3 \
  -global virtio-mmio.force-legacy=false \
  -smp 4 \
  -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 \
  -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img \
  -append "root=/dev/nvme0n1 rw init=/bin/sh" \
  -m 8g \
  -netdev hubport,id=net0,hubid=77 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 \
  -netdev hubport,id=net2,hubid=77 \
  -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 \
  -kernel "$AXVISOR_BIN" < /dev/null > "$LOG" 2>&1
echo "QEMU exited with code $?"

# Check results
echo ""
echo "=== Results ==="
if grep -q "ALL TESTS COMPLETE" "$LOG"; then
  echo "SUCCESS: All tests completed"
else
  echo "WARNING: ALL TESTS COMPLETE not found in log"
fi

echo ""
echo "--- RT-IPC Statistics ---"
grep -E "RT-IPC|Payload|RTT|throughput|loss|sent=|recv=|ALL TESTS|connected|reconnect" "$LOG" || echo "No RT-IPC output found"

echo ""
echo "Full log: $LOG"
