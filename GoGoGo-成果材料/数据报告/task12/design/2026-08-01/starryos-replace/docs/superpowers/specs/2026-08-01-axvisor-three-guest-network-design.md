# Axvisor Three-Guest Network Experiment

## Goal

Provide a reproducible QEMU AArch64 experiment under `tgoskits/` that boots two
Linux guests and one RTOS guest with Axvisor. Linux and the RTOS communicate
over ordinary Ethernet frames carried only by the three `virtio-net-device`
NICs on QEMU hub 77. The design must not use shared-memory channels, IVC,
vsock, or virtio sockets for guest-to-guest communication.

## Chosen Architecture

The outer QEMU instance exposes exactly three independent `virtio-net-device`
MMIO devices. Each device is connected to QEMU `hubport` hub 77, forming one
isolated Layer-2 network:

```text
Linux-1 VM -- virtio-mmio@0x0a000000 --+
Linux-2 VM -- virtio-mmio@0x0a000200 --+-- QEMU hubport (L2)
Zephyr VM -- virtio-mmio@0x0a000400 --+
```

Axvisor passes exactly one MMIO device and its interrupt to each VM. The VM
configs use distinct type-2 `MapReserved` identity RAM ranges so a passthrough
NIC DMA buffer cannot land in another VM's RAM. The dedicated board enables the
bare top-level `qemu-aarch64-three-guest-net` feature, which applies a
workload-scoped early host reservation for `0x80000000..0xb0000000` before the
host allocator starts. The generic QEMU board remains unchanged and does not
reserve this range. The guest RAM ranges are:

| Guest | VM id | Guest RAM | Network device | Guest IP |
| --- | ---: | --- | --- | --- |
| Linux-1 | 1 | `0x80000000..0x90000000` | `/virtio_mmio@a000000` | `192.168.77.11/24` |
| Linux-2 | 2 | `0x90000000..0xa0000000` | `/virtio_mmio@a000200` | `192.168.77.12/24` |
| Zephyr RTOS | 3 | `0xa0000000..0xb0000000` | `/virtio_mmio@a000400` | `192.168.77.13/24` |

The exact device-tree node names are verified from the QEMU-generated FDT by
the validation script before an Axvisor run is attempted.

## Guest Images

The two Linux VM configs may use the same AArch64 Linux image because Axvisor
loads each copy into a different RAM range. The RTOS input is a Zephyr image
with `virtio-net`, IPv4, ARP, and ICMP echo handling enabled. The checked-in
guest does not provide a TCP service. The repository's existing FreeRTOS image
is a benchmark without a network application and is therefore not used as
proof of network communication.

The setup script accepts an explicit RTOS image path. Without one, it builds
the checked-in `guests/zephyr-net` application and requires a configured
`ZEPHYR_BASE` and AArch64 toolchain; it does not fall back to a registry RTOS
image or the benchmark image.

## Files

- `configs/board/qemu-aarch64-three-guest-net.toml`: dedicated build features,
  including the workload-scoped early host RAM reservation.
- `configs/qemu/qemu-aarch64-three-guest-net.toml`: outer QEMU memory, disk,
  and three `hubport`-connected virtio-net devices.
- `configs/vms/qemu/aarch64/linux-net-1.toml` and `linux-net-2.toml`: Linux
  guest configs with isolated RAM and one selected MMIO NIC each.
- `configs/vms/qemu/aarch64/zephyr-net.toml`: RTOS guest config with isolated
  RAM and the third MMIO NIC.
- `scripts/setup_qemu_three_guest_net.sh`: prepares Linux/RTOS images,
  generates memory-mode VM configs, and prints the Axvisor command.
- `scripts/verify_three_guest_net.sh`: validates TOML invariants and QEMU FDT
  topology and optionally validates one QEMU host DTB. It does not accept guest
  logs.
- `docs/docs/build/axvisor/three-guest-network.md`: user-facing setup, guest
  network commands, and limitations.

## Verification

1. Parse all three VM TOML files and check unique IDs, CPU assignments, RAM
   ranges, and one-to-one MMIO device selection. Parse the selected board and
   require the bare reservation feature exactly once while rejecting
   dependency-qualified variants.
2. Run QEMU with the outer configuration and dump its FDT; check that all
   three `virtio_mmio` nodes have distinct MMIO ranges and IRQs.
3. Build Axvisor with all three VM configs and confirm the generated guest FDT
   for each VM contains only its assigned NIC.
4. Boot the three guests and observe the checked-in runtime probes: Linux-1 and
   Linux-2 each reach Zephyr over ICMP, and Linux-1 reaches Linux-2 over
   TCP port 8080.

The first three checks are repository-local and runnable without a working
RTOS image. The final check requires a built or explicitly supplied Zephyr
image and must be judged from the guest console output; the static verifier
does not consume those logs.

## Non-Goals

- Implementing an Axvisor virtio-net device model or a hypervisor software
  switch.
- Sharing guest memory or adding an IVC, vsock, or virtio-socket transport.
- Adding a combined realtime/preempt board before the screening step decides
  whether that combination is justified.
- Treating a FreeRTOS benchmark with no network application as a network test.
- Making the setup script configure an external host bridge or tap device.
