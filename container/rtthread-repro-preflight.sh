#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf '[rtthread-repro] ERROR: %s\n' "$*" >&2
    exit 1
}

check_tools() {
    local tool

    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || fail "missing command: $tool"
    done
}

contract_tools=(
    qemu-system-aarch64
    uv
    uclampset
    pidstat
    socat
    aarch64-linux-gnu-strip
)

if [[ "${1:-}" == "--check-tools" ]]; then
    check_tools "${contract_tools[@]}"
    exit 0
fi
[[ $# -eq 0 ]] || fail "unsupported argument: $1"

runtime_tools=(
    cargo
    rustc
    git
    make
    aarch64-linux-gnu-objcopy
    aarch64-linux-musl-gcc
)
check_tools "${contract_tools[@]}" "${runtime_tools[@]}"

[[ "$(uname -m)" == x86_64 ]] || fail "container must run on x86_64"

visible_cpus="$(nproc)"
[[ "$visible_cpus" =~ ^[0-9]+$ ]] || fail "could not determine visible CPU count"
((visible_cpus >= 4)) || fail "at least four CPUs must be visible"

qemu_version="$(qemu-system-aarch64 --version)"
qemu_version="${qemu_version%%$'\n'*}"
[[ "$qemu_version" == *"version 11.0.2"* ]] ||
    fail "unexpected QEMU version: $qemu_version"

uv_version="$(uv --version)"
[[ "$uv_version" == "uv 0.11.16" ]] || fail "unexpected uv version: $uv_version"

directories=(
    "${HOME:-}"
    "${CARGO_HOME:-}"
    "${UV_CACHE_DIR:-}"
    /workspace/docs/docs/build/axvisor/docker-repro
)
directory_names=(HOME CARGO_HOME UV_CACHE_DIR output)
for index in "${!directories[@]}"; do
    directory="${directories[$index]}"
    [[ -n "$directory" ]] || fail "${directory_names[$index]} is required"
    mkdir -p -- "$directory" || fail "could not create directory: $directory"
    [[ -w "$directory" ]] || fail "directory is not writable: $directory"
done

allowed_cpus="$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)"
[[ -n "$allowed_cpus" ]] || fail "could not read Cpus_allowed_list"
printf '[rtthread-repro] cpus_allowed=%s visible_cpus=%s\n' \
    "$allowed_cpus" "$visible_cpus"
printf '[rtthread-repro] loadavg=%s\n' "$(< /proc/loadavg)"

sleep 30 &
probe_pid=$!
cleanup() {
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
uclampset -m 1 -p "$probe_pid" >/dev/null || fail "uclampset probe failed"
cleanup
trap - EXIT INT TERM

printf '[rtthread-repro] qemu=%s\n' "$qemu_version"
printf '[rtthread-repro] uv=%s\n' "$uv_version"
printf '%s\n' '[rtthread-repro] PASS'
