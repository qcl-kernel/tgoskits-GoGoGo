# Correct-image 180-second stability evidence

Date: 2026-08-20

This is the post-fix AxVisor + 2-vCPU Linux + RT-Thread stability run using
the current persistent-cache RT-Thread image, whose BSP vendor ID is
`0x554d4551`.

- QEMU: `/home/yfblock/.local/qemu-arm/bin/qemu-system-aarch64` 11.0.2
- RT-Thread image SHA-256: `5e7ba27894f2b602bae3245e3b1e97f0696f2dcc7df9b35a3ae194f889584937`
- Linux: 2 vCPUs, `online=0-1`
- RT-Thread: 1 vCPU, AxVisor CPU mask `[2]`
- Stability duration: 180 seconds
- Stability samples: `179999/179999`, `missing=0`
- Stability jitter: `p50=3376 ns`, `p95=21120 ns`, `p99=215536 ns`,
  `p99_9=391776 ns`, `max=905168 ns`, `miss_1ms=0`
- Callback execution: `p99=880 ns`, `max=167232 ns`, `miss_1ms=0`
- Task 2: `1000/1000` for each payload size, one disconnect/recovery, `loss=0%`
- Task 3: `6/6`, classification accuracy `3/3`
- Result: `PASS`

The run uses the current image at
`tgoskits/tmp/rt-thread-5.2.2-native-current/bsp/qemu-virt64-aarch64/rtthread.bin`.
An older manually supplied `tmp/rtthread-net-fixed-entry.bin` was also tested
and correctly failed device discovery because it still contained vendor ID
`0x1AF4`; that failure is retained as a stale-artifact diagnostic and is not
part of this passing result.

`SHA256SUMS` covers the evidence files in this directory.
