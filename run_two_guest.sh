#!/bin/bash
cd /home/yfblock/Code/hyper-rtos/tgoskits
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 1

# Build using xtask
cargo axvisor build --config qemu-aarch64-two-guest-net +  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/linux-net.toml +  --vmconfigs os/axvisor/configs/vms/qemu/aarch64/rtthread-net.toml 2>&1 | tail -10

if [ $? -ne 0 ]; then
  echo "BUILD FAILED"
  exit 1
fi

aarch64-linux-gnu-objcopy -O binary target/aarch64-unknown-linux-musl/release/axvisor target/aarch64-unknown-linux-musl/release/axvisor.bin

timeout 60 /home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64 -nographic -cpu cortex-a72 -machine virt,virtualization=on,gic-version=3 -global virtio-mmio.force-legacy=false -smp 4 -device nvme,drive=disk0,serial=tgoskits,max_ioqpairs=64,msix_qsize=65 -drive id=disk0,if=none,format=raw,file=tmp/rootfs.img -append "root=/dev/nvme0n1 rw init=/bin/sh" -m 8g -netdev hubport,id=net0,hubid=77 -object filter-dump,id=dump0,netdev=net0,file=/tmp/axvisor-net0.pcap -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.0,mac=52:54:00:77:00:01 -netdev hubport,id=net2,hubid=77 -object filter-dump,id=dump2,netdev=net2,file=/tmp/axvisor-net2.pcap -device virtio-net-device,netdev=net2,bus=virtio-mmio-bus.2,mac=52:54:00:77:00:03 -kernel target/aarch64-unknown-linux-musl/release/axvisor.bin < /dev/null > tmp/qemu-result.log 2>&1
echo "EXIT:$?"
