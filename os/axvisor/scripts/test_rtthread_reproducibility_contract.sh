#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RUNNER="$ROOT/os/axvisor/scripts/run_rtipc_test.sh"
VMCONFIG_GENERATOR="$ROOT/os/axvisor/scripts/generate_rtthread_vmconfig.sh"
PREPARE_REL="os/axvisor/patches/rtthread/prepare_rtthread_source.sh"
APPLY_REL="os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
VERIFY_REL="os/axvisor/patches/rtthread/test-rtthread-patches.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

grep -Fq 'RTTHREAD_SRC="${RTTHREAD_SRC:-tmp/rt-thread-5.2.2-final}"' "$RUNNER" || \
    fail "runner must allow an isolated RTTHREAD_SRC override"

grep -Fq 'RTTHREAD_KERNEL="$(realpath "$RTTHREAD_SRC/bsp/qemu-virt64-aarch64/rtthread.bin")"' \
    "$RUNNER" || \
    fail "runner must resolve the kernel from the selected RTTHREAD_SRC"

grep -Fq -- '--vmconfigs "$RTTHREAD_VMCONFIG"' "$RUNNER" || \
    fail "AxVisor build must consume the runtime RT-Thread VM config"

test_tmp="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp"' EXIT
test_root="$test_tmp/root with spaces and a \"quote\""
runtime_dir="$test_root/tmp/rtthread-runtime.ABC123"
kernel_dir="$test_tmp/kernel with spaces and a \"quote\""
mkdir -p "$runtime_dir" "$kernel_dir"
kernel="$kernel_dir/rtthread.bin"
: > "$kernel"
template="$test_tmp/template.toml"
cat > "$template" <<'EOF'
[base]
id = 3
host_vcpu_idle_policy = "busy"
[kernel]
kernel_path = "/stale/hard-coded/rtthread.bin"
entry_point = 0xa000_0000
EOF

generated="$($VMCONFIG_GENERATOR "$test_root" "$template" "$kernel" "$runtime_dir")"
[[ "$generated" == "$runtime_dir/rtthread-net.toml" ]] || \
    fail "generator must return the generated VM config path"
[[ "$(readlink "$runtime_dir/rtthread.bin")" == "$(realpath "$kernel")" ]] || \
    fail "runtime kernel symlink must target the selected RTTHREAD_SRC image"
grep -Fxq 'kernel_path = "rtthread.bin"' "$generated" || \
    fail "generated VM config must use a TOML-safe config-relative kernel path"
generated_kernel="$(sed -n 's/^kernel_path = "\([^"]*\)"$/\1/p' "$generated")"
[[ -f "$(dirname -- "$generated")/$generated_kernel" ]] || \
    fail "kernel_path must resolve relative to the generated VM config directory"
grep -Fxq 'entry_point = 0xa000_0000' "$generated" || \
    fail "generator must preserve non-kernel VM configuration"
[[ "$(grep -c '^kernel_path = ' "$generated")" -eq 1 ]] || \
    fail "generator must emit exactly one kernel_path"

halt_runtime="$test_root/tmp/rtthread-runtime.HALT01"
mkdir -p "$halt_runtime"
halt_generated="$($VMCONFIG_GENERATOR "$test_root" "$template" "$kernel" "$halt_runtime" "task3.fault=normal" halt)"
grep -Fxq 'host_vcpu_idle_policy = "halt"' "$halt_generated" || \
    fail "generator must support a runtime halt idle policy override"

if "$VMCONFIG_GENERATOR" "$test_root" "$template" "$kernel" "$test_root/tmp/rtthread-runtime.BAD01" \
    "task3.fault=normal" invalid >/dev/null 2>&1; then
    fail "generator must reject an invalid runtime idle policy"
fi

outside="$test_tmp/outside-runtime"
mkdir -p "$outside"
if "$VMCONFIG_GENERATOR" "$test_root" "$template" "$kernel" "$outside" \
    >/dev/null 2>&1; then
    fail "generator must reject runtime directories outside ROOT/tmp"
fi

if grep -F 'cargo xtask axvisor build' -A4 "$RUNNER" | \
    grep -Fq 'rtthread-net.toml'; then
    fail "AxVisor build must not bypass RTTHREAD_SRC with the static RT-Thread VM config"
fi

prepare_line="$(grep -nF "$PREPARE_REL \"\$RTTHREAD_SRC\"" "$RUNNER" | head -1 | cut -d: -f1 || true)"
apply_line="$(grep -nF "$APPLY_REL \"\$RTTHREAD_SRC\"" "$RUNNER" | head -1 | cut -d: -f1 || true)"
if [[ -z "$prepare_line" || -z "$apply_line" || "$prepare_line" -ge "$apply_line" ]]; then
    fail "runner must prepare pinned RT-Thread source before applying patches"
fi

verify_line="$(grep -nF "$VERIFY_REL \"\$RTTHREAD_SRC\"" "$RUNNER" | head -1 | cut -d: -f1 || true)"
if [[ -z "$verify_line" || "$apply_line" -ge "$verify_line" ]]; then
    fail "runner must verify the selected patched source before building it"
fi

cleanup_root="$test_tmp/cleanup"
STAGING="$cleanup_root/staging"
RTTHREAD_RUNTIME_DIR="$cleanup_root/rtthread-runtime"
LINUX_RUNTIME_DIR="$cleanup_root/linux-runtime"
mkdir -p "$STAGING" "$RTTHREAD_RUNTIME_DIR" "$LINUX_RUNTIME_DIR"
# shellcheck source=/dev/null
source "$RUNNER"
STAGING="$cleanup_root/staging"
RTTHREAD_RUNTIME_DIR="$cleanup_root/rtthread-runtime"
LINUX_RUNTIME_DIR="$cleanup_root/linux-runtime"
cleanup_build_artifacts
for cleaned_dir in "$STAGING" "$RTTHREAD_RUNTIME_DIR" "$LINUX_RUNTIME_DIR"; do
    [[ ! -e "$cleaned_dir" ]] || \
        fail "runner cleanup left runtime directory behind: $cleaned_dir"
done

rtbench_gate_line="$(grep -nF 'verify_rtbench_suite.sh' "$RUNNER" | tail -1 | cut -d: -f1 || true)"
final_success_line="$(grep -nF 'SUCCESS: all requested RT-IPC and benchmark gates passed' \
    "$RUNNER" | tail -1 | cut -d: -f1 || true)"
if [[ -z "$rtbench_gate_line" || -z "$final_success_line" || \
      "$rtbench_gate_line" -ge "$final_success_line" ]]; then
    fail "runner must report overall success only after every requested gate"
fi

if find "$ROOT/os/axvisor/patches/rtthread" "$ROOT/os/axvisor/scripts" \
    -type f -name '*.sh' ! -perm -u+x -print -quit | grep -q .; then
    fail "all RT-Thread and AxVisor shell entry points must be executable"
fi

echo "RT-Thread reproducibility contract: PASS"
