#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
SCRIPT_DIR="$ROOT/os/axvisor/scripts"
PREPARE="$ROOT/os/axvisor/scripts/prepare_zephyr_source.sh"
BUILD="$ROOT/os/axvisor/scripts/build_zephyr_task123.sh"
ZEPHYR_METADATA="$ROOT/os/axvisor/scripts/zephyr_image_metadata.py"
NETWORK_ENV="$ROOT/os/axvisor/scripts/network_env.sh"
APP="$ROOT/os/axvisor/guests/zephyr-task123"
RTIPC_COMMON="$ROOT/os/axvisor/guests/rt-ipc/common"
TASK3_COMMON="$ROOT/os/axvisor/guests/task3/src/common"

[[ -x "$PREPARE" ]] || { echo "FAIL: Zephyr source preparer is missing" >&2; exit 1; }
[[ -x "$BUILD" ]] || { echo "FAIL: Zephyr builder is missing" >&2; exit 1; }
[[ -x "$ZEPHYR_METADATA" ]] ||
    { echo "FAIL: Zephyr image metadata validator is missing" >&2; exit 1; }
[[ -f "$NETWORK_ENV" ]] ||
    { echo "FAIL: shared download proxy environment is missing" >&2; exit 1; }
[[ -f "$APP/prj.conf" ]] || { echo "FAIL: Zephyr Task123 app is missing" >&2; exit 1; }
[[ -f "$RTIPC_COMMON/rtipc_echo_responder.c" ]] ||
    { echo "FAIL: RT-IPC action pump must be platform independent" >&2; exit 1; }
[[ -f "$RTIPC_COMMON/rtipc_peer.c" ]] ||
    { echo "FAIL: RT-IPC peer guard must be platform independent" >&2; exit 1; }
[[ -f "$RTIPC_COMMON/rtipc_time.c" ]] ||
    { echo "FAIL: RT-IPC clock extender must be platform independent" >&2; exit 1; }
[[ -f "$TASK3_COMMON/task3_server_core.c" ]] ||
    { echo "FAIL: Task 3 server application layer must be platform independent" >&2; exit 1; }
grep -Fq 'rtipc_echo_process_actions' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr must reuse the common RT-IPC action pump" >&2; exit 1; }
grep -Fq 'task3_server_handle_message' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr must reuse the Task 3 server application layer" >&2; exit 1; }
grep -Fq 'RTIPC_SERVER_READY' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr RT-IPC readiness marker is missing" >&2; exit 1; }
grep -Fq 'TASK3_RTOS_READY' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr Task3 readiness marker is missing" >&2; exit 1; }
grep -Fq 'RTBENCH metric=' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr realtime marker grammar is missing" >&2; exit 1; }
grep -Fq 'SHELL_CMD_REGISTER(rtbench_stability' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr must accept the runner rtbench_stability command" >&2; exit 1; }
grep -Fq 'residual_ticks < 0' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr jitter must handle timer callbacks firing early" >&2; exit 1; }
grep -Fq 'rtbench_fit_phase_ticks' "$APP/src/main.c" ||
    { echo 'FAIL: Zephyr jitter phase must use windowed linear regression' >&2; exit 1; }
grep -Fq 'RTBENCH_PERIOD_NS' "$APP/src/main.c" ||
    { echo 'FAIL: Zephyr jitter reference period must be explicit' >&2; exit 1; }
if grep -Fq 'qsort(values, rtbench_collected - 1U' "$APP/src/main.c"; then
    { echo 'FAIL: adjacent-interval phase estimation is invalid under burst catch-up' >&2; exit 1; }
fi
grep -Fq 'rtbench_phase_ticks' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr jitter origin must be captured before timer start" >&2; exit 1; }
grep -Fq 'RTBENCH_MAX_SAMPLES 299999U' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr stability storage must support the 300s contract" >&2; exit 1; }
grep -Fq 'SHELL_CMD_REGISTER(benchmark' "$APP/src/main.c" ||
    { echo "FAIL: Zephyr must accept the runner benchmark command" >&2; exit 1; }
grep -Fqx 'CONFIG_NET_SOCKETS=y' "$APP/prj.conf" ||
    { echo "FAIL: Zephyr guest needs native UDP sockets" >&2; exit 1; }
grep -Fqx 'CONFIG_NET_QEMU_ETHERNET=y' "$APP/prj.conf" ||
    { echo "FAIL: Zephyr guest must explicitly choose Ethernet over QEMU SLIP" >&2; exit 1; }
heap_size=$(sed -n 's/^CONFIG_HEAP_MEM_POOL_SIZE=\([0-9][0-9]*\)$/\1/p' "$APP/prj.conf")
[[ -n "$heap_size" && "$heap_size" -ge 131072 ]] ||
    { echo "FAIL: Zephyr virtio queues need at least a 131072-byte persistent heap" >&2; exit 1; }
grep -Fq 'AXVISOR_DISABLE_VIRTIO_IRQ_POLL' "$APP/CMakeLists.txt" ||
    { echo "FAIL: Zephyr guest must default to the real virtio SPI path" >&2; exit 1; }
grep -Fq 'ZEPHYR_VERSION=v4.4.2' "$PREPARE" ||
    { echo "FAIL: Zephyr source is not pinned to v4.4.2" >&2; exit 1; }
grep -Fq 'ZEPHYR_COMMIT=dccb09599635bdff17633fa7e9dab014b91dce90' "$PREPARE" ||
    { echo "FAIL: Zephyr pin uses the annotated tag object instead of its peeled source commit" >&2; exit 1; }
grep -Fq 'TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache' "$PREPARE" ||
    { echo "FAIL: Zephyr source cache is not persistent" >&2; exit 1; }
grep -Fq 'zephyr.bin.meta.json' "$BUILD" ||
    { echo "FAIL: Zephyr builder does not publish image metadata" >&2; exit 1; }
grep -Fq 'network_env.sh' "$BUILD" ||
    { echo "FAIL: Zephyr builder does not load the shared proxy environment" >&2; exit 1; }
grep -Fq 'http://172.16.0.254:7897' "$NETWORK_ENV" ||
    { echo "FAIL: shared proxy environment does not default to the approved proxy" >&2; exit 1; }
grep -Fq 'NO_PROXY' "$NETWORK_ENV" ||
    { echo "FAIL: shared proxy environment must preserve local-address traffic" >&2; exit 1; }
grep -Fq 'Zephyr DTB must stay in RAM' "$SCRIPT_DIR/generate_zephyr_vmconfig.sh" ||
    { echo "FAIL: Zephyr VM generator lacks RAM/overlap validation" >&2; exit 1; }

vmconfig_fixture="$(mktemp -d "$ROOT/tmp/test-zephyr-vmconfig.XXXXXX")"
trap 'rm -rf -- "$vmconfig_fixture"' EXIT
vmconfig_runtime="$vmconfig_fixture/tmp/zephyr-runtime.contract"
mkdir -p -- "$vmconfig_runtime"
printf 'zephyr-image\n' > "$vmconfig_fixture/zephyr.bin"
printf '%s\n' '{"entry_point":1073746180}' > "$vmconfig_fixture/zephyr.bin.meta.json"
"$SCRIPT_DIR/generate_zephyr_vmconfig.sh" \
    "$vmconfig_fixture" "$ROOT/os/axvisor/configs/vms/qemu/aarch64/zephyr-task123.toml" \
    "$vmconfig_fixture/zephyr.bin" "$vmconfig_fixture/zephyr.bin.meta.json" \
    "$vmconfig_runtime" task3.fault=normal >/dev/null
grep -Fq 'dtb_load_addr = 0x47e0_0000' "$vmconfig_runtime/zephyr-task123.toml" ||
    { echo "FAIL: generated Zephyr DTB is not at the in-RAM reference address" >&2; exit 1; }
sed 's/dtb_load_addr = 0x47e0_0000/dtb_load_addr = 0xaf00_0000/' \
    "$ROOT/os/axvisor/configs/vms/qemu/aarch64/zephyr-task123.toml" \
    > "$vmconfig_fixture/out-of-ram.toml"
if "$SCRIPT_DIR/generate_zephyr_vmconfig.sh" \
        "$vmconfig_fixture" "$vmconfig_fixture/out-of-ram.toml" \
        "$vmconfig_fixture/zephyr.bin" "$vmconfig_fixture/zephyr.bin.meta.json" \
        "$vmconfig_runtime" task3.fault=normal >/dev/null 2>&1; then
    echo "FAIL: out-of-RAM Zephyr DTB was accepted" >&2
    exit 1
fi

echo "PASS: Zephyr pinned source and real-interrupt build contract"
