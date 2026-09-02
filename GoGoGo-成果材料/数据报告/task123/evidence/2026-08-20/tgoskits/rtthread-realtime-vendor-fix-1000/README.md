# RT-Thread virtio-net vendor compatibility fix

Date: 2026-08-20

This evidence records the first real-QEMU regression run after fixing the
virtio-mmio vendor ID mismatch between AxVisor and RT-Thread.

- QEMU: `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64` 11.0.2
- RT-Thread: 5.2.2, 1000 samples per suite metric
- Linux guest: 2 vCPUs, `online=0-1`
- RT-Thread guest: 1 vCPU, pinned to host CPU 2 by AxVisor
- QEMU vCPU affinity: `0=3,1=4,2=2,3=5`
- Result: native suite `PASS`, AxVisor-only suite `PASS`, full Linux + RT-Thread suite `PASS`

The previous failure was caused by RT-Thread accepting QEMU's virtio-mmio
vendor ID `0x554d4551`, while AxVisor's virtual net device returned
`0x1af4`. The AxVisor virtio-net instance now uses `0x554d4551`; the generic
constructor still defaults to `0x1af4` for compatibility with other devices.

Functional evidence from the full scenario:

- `RTIPC_SERVER_READY ip=192.168.77.30 port=9876`
- Task 2: all payload tests returned `sent=10 recv=10 loss=0%`, including one forced disconnect and recovery
- Task 3: 6/6 control requests succeeded, classification accuracy 3/3
- `RTBENCH_END status=PASS`
- `status.tsv`: all three scenarios are `PASS`

The single early `virtio-net ... NotReady` warning occurs before the RT-Thread
guest finishes initializing its RX queues. There are no later `no_network_device`
or persistent `NotReady` failures in this run.

See `realtime-suite.md`, `realtime-suite.json`, and `realtime-suite.csv` for
the complete real-time comparison. `SHA256SUMS` covers every file in this
directory.
