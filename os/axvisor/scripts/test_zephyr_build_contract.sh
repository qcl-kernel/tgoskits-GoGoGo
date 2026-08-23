#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
SCRIPT_DIR="$ROOT/os/axvisor/scripts"
PREPARE="$ROOT/os/axvisor/scripts/prepare_zephyr_source.sh"
BUILD="$ROOT/os/axvisor/scripts/build_zephyr_task123.sh"
RUNNER="$ROOT/os/axvisor/scripts/run_task123.sh"
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
grep -Fq -- '--input-digest' "$BUILD" ||
    { echo "FAIL: Zephyr builder does not expose input digest mode" >&2; exit 1; }
grep -Fq 'zephyr.bin.inputs.sha256' "$BUILD" ||
    { echo "FAIL: Zephyr builder does not publish input digest metadata" >&2; exit 1; }
grep -Fq 'flock' "$BUILD" ||
    { echo "FAIL: Zephyr image cache publication is not serialized" >&2; exit 1; }
grep -Fq 'zephyr_image_metadata.py" check' "$BUILD" ||
    { echo "FAIL: Zephyr builder does not authenticate a generation before publication" >&2; exit 1; }
grep -Fq -- '--input-digest' "$RUNNER" ||
    { echo "FAIL: Task123 runner does not calculate the Zephyr input digest" >&2; exit 1; }
grep -Fq 'zephyr.bin.inputs.sha256' "$RUNNER" ||
    { echo "FAIL: Task123 runner does not validate the Zephyr input digest" >&2; exit 1; }
grep -Fq 'ZEPHYR_IMAGE_METADATA_TOOL" check' "$RUNNER" ||
    { echo "FAIL: Task123 runner does not authenticate cached Zephyr image bytes" >&2; exit 1; }
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

digest_fixture="$vmconfig_fixture/zephyr-app"
cp -a -- "$APP" "$digest_fixture"
digest_before="$(ZEPHYR_TASK123_APP="$digest_fixture" "$BUILD" --input-digest)"
printf '\n/* cache invalidation contract */\n' >> "$digest_fixture/src/main.c"
digest_after="$(ZEPHYR_TASK123_APP="$digest_fixture" "$BUILD" --input-digest)"
[[ "$digest_before" =~ ^[0-9a-f]{64}$ && "$digest_after" =~ ^[0-9a-f]{64}$ ]] ||
    { echo "FAIL: Zephyr input digest is not a SHA-256 value" >&2; exit 1; }
[[ "$digest_before" != "$digest_after" ]] ||
    { echo "FAIL: Zephyr application changes do not invalidate the image digest" >&2; exit 1; }

publication_root="$vmconfig_fixture/publication-cache"
publication_output="$publication_root/current-image"
mkdir -p -- "$publication_root"

make_generation_fixture() {
    local name=$1
    local payload=$2
    local fixture="$vmconfig_fixture/$name"
    mkdir -p -- "$fixture"
    printf '%s\n' "$payload" > "$fixture/zephyr.bin"
    printf '%s\n' \
        '{"entry_point":1073746180,"zephyr_version":"fixture","zephyr_commit":"fixture","zephyr_sdk_version":"fixture","board":"qemu_cortex_a53"}' \
        > "$fixture/build-meta.json"
    "$ZEPHYR_METADATA" write \
        --image "$fixture/zephyr.bin" \
        --source "$fixture/build-meta.json" \
        --output "$fixture/zephyr.bin.meta.json" >/dev/null
}

publish_fixture() {
    local fixture=$1
    local digest=$2
    ZEPHYR_TASK123_BUILD_LIB_ONLY=1 bash -c '
        set -euo pipefail
        source "$1"
        publish_zephyr_generation "$2" "$3" "$4" "$5"
    ' bash "$BUILD" "$fixture/zephyr.bin" "$fixture/zephyr.bin.meta.json" \
        "$digest" "$publication_output"
}

cache_is_current() {
    local digest=$1
    ZEPHYR_TASK123_BUILD_LIB_ONLY=1 bash -c '
        set -euo pipefail
        source "$1"
        zephyr_generation_is_current "$2" "$3"
    ' bash "$BUILD" "$publication_output" "$digest"
}

make_generation_fixture generation-a 'generation A'
make_generation_fixture generation-b 'generation B'
make_generation_fixture generation-c 'generation C'
digest_a=$(printf 'a%.0s' {1..64})
digest_b=$(printf 'b%.0s' {1..64})
digest_c=$(printf 'c%.0s' {1..64})

publish_fixture "$vmconfig_fixture/generation-a" "$digest_a"
cache_is_current "$digest_a" ||
    { echo "FAIL: published Zephyr generation is not reusable" >&2; exit 1; }
"$ZEPHYR_METADATA" check \
    --image "$publication_output/current/zephyr.bin" \
    --metadata "$publication_output/current/zephyr.bin.meta.json" >/dev/null
current_before_failure=$(readlink -- "$publication_output/current")

if publish_zephyr_generation_error=$(
    ZEPHYR_TASK123_BUILD_LIB_ONLY=1 bash -c '
        set -euo pipefail
        source "$1"
        publish_zephyr_generation "$2" "$3" "$4" "$5"
    ' bash "$BUILD" "$vmconfig_fixture/generation-b/zephyr.bin" \
        "$vmconfig_fixture/generation-a/zephyr.bin.meta.json" "$digest_b" \
        "$publication_output" 2>&1
); then
    echo "FAIL: mismatched Zephyr image metadata was published" >&2
    exit 1
fi
[[ -n "$publish_zephyr_generation_error" ]] ||
    { echo "FAIL: rejected Zephyr publication did not explain the failure" >&2; exit 1; }
[[ "$(readlink -- "$publication_output/current")" == "$current_before_failure" ]] ||
    { echo "FAIL: failed Zephyr publication changed the current generation" >&2; exit 1; }
cache_is_current "$digest_a" ||
    { echo "FAIL: failed publication corrupted the reusable Zephyr cache" >&2; exit 1; }

publish_fixture "$vmconfig_fixture/generation-b" "$digest_b" &
publish_b_pid=$!
publish_fixture "$vmconfig_fixture/generation-c" "$digest_c" &
publish_c_pid=$!
wait "$publish_b_pid"
wait "$publish_c_pid"
current_digest=$(sed -n '1p' "$publication_output/current/zephyr.bin.inputs.sha256")
case "$current_digest" in
    "$digest_b"|"$digest_c") ;;
    *) echo "FAIL: concurrent Zephyr publication exposed an unknown digest" >&2; exit 1 ;;
esac
cache_is_current "$current_digest" ||
    { echo "FAIL: concurrent Zephyr publication exposed a mixed generation" >&2; exit 1; }
"$ZEPHYR_METADATA" check \
    --image "$publication_output/current/zephyr.bin" \
    --metadata "$publication_output/current/zephyr.bin.meta.json" >/dev/null

echo "PASS: Zephyr pinned source and real-interrupt build contract"
