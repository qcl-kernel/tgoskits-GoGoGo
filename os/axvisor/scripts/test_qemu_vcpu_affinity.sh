#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/run_qemu_vcpu_affinity.sh"
HELPER_SOURCE="${SCRIPT_DIR}/validate_qemu_artifact.sh"
TEST_ROOT=""

fail() {
  echo "[qemu-vcpu-affinity-test] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT INT TERM

[ -f "$SOURCE" ] || fail "missing affinity runner: ${SOURCE}"
[ -f "$HELPER_SOURCE" ] || fail "missing artifact helper: ${HELPER_SOURCE}"
command -v cc >/dev/null 2>&1 || fail "cc is required"
command -v rust-objcopy >/dev/null 2>&1 || fail "rust-objcopy is required"
REAL_PYTHON="$(command -v python3)" || fail "python3 is required"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/axvisor-qemu-artifact-test.XXXXXX")"
FIXTURE_ROOT="${TEST_ROOT}/repo"
FIXTURE_SCRIPTS="${FIXTURE_ROOT}/os/axvisor/scripts"
FIXTURE_TARGET="${FIXTURE_ROOT}/target/aarch64-unknown-linux-musl/release"
FIXTURE_CONFIGS="${FIXTURE_ROOT}/tmp/vmconfigs/three-guest-net"
RUNNER="${FIXTURE_SCRIPTS}/run_qemu_vcpu_affinity.sh"
HELPER="${FIXTURE_SCRIPTS}/validate_qemu_artifact.sh"
DEFAULT_ELF="${FIXTURE_TARGET}/axvisor"
DEFAULT_RAW="${FIXTURE_TARGET}/axvisor.bin"
EMBED_C="${TEST_ROOT}/embed-configs.c"
EMBED_ASM="${TEST_ROOT}/embed-configs.S"
COMMAND_OUTPUT="${TEST_ROOT}/command.out"

mkdir -p "$FIXTURE_SCRIPTS" "$FIXTURE_TARGET" "$FIXTURE_CONFIGS"
cp "$SOURCE" "$RUNNER"
cp "$HELPER_SOURCE" "$HELPER"
chmod +x "$RUNNER" "$HELPER"

write_default_artifacts() {
  local include_host_policy_diagnostic="${1:-true}"
  printf 'name = "linux-net-1"\n' >"${FIXTURE_CONFIGS}/linux-net-1.toml"
  printf 'name = "linux-net-2"\n' >"${FIXTURE_CONFIGS}/linux-net-2.toml"
  printf 'name = "zephyr-net"\n' >"${FIXTURE_CONFIGS}/zephyr-net.toml"
  cat >"$EMBED_C" <<'EOF'
extern const unsigned char vm_config_1[];
extern const unsigned char vm_config_2[];
extern const unsigned char vm_config_3[];
EOF
  if [ "$include_host_policy_diagnostic" = true ]; then
    cat >>"$EMBED_C" <<'EOF'
__attribute__((used)) static const char host_policy_diagnostic[] =
    "configured host policy: timer={:?}, vcpu_yield={}, vcpu_idle={:?}";
EOF
  fi
  cat >>"$EMBED_C" <<'EOF'

__attribute__((used)) static const void *const embedded_vm_configs[] = {
    vm_config_1,
    vm_config_2,
    vm_config_3,
};

int main(void) {
    return embedded_vm_configs[0] == 0;
}
EOF
  cat >"$EMBED_ASM" <<EOF
.section .rodata.vm_config_1,"a",@progbits
.global vm_config_1
.type vm_config_1, @object
vm_config_1:
.incbin "${FIXTURE_CONFIGS}/linux-net-1.toml"
.size vm_config_1, . - vm_config_1

.section .rodata.vm_config_2,"a",@progbits
.global vm_config_2
.type vm_config_2, @object
vm_config_2:
.incbin "${FIXTURE_CONFIGS}/linux-net-2.toml"
.size vm_config_2, . - vm_config_2

.section .rodata.vm_config_3,"a",@progbits
.global vm_config_3
.type vm_config_3, @object
vm_config_3:
.incbin "${FIXTURE_CONFIGS}/zephyr-net.toml"
.size vm_config_3, . - vm_config_3

.section .note.GNU-stack,"",@progbits
EOF
  cc -o "$DEFAULT_ELF" "$EMBED_C" "$EMBED_ASM"
  rust-objcopy -O binary "$DEFAULT_ELF" "$DEFAULT_RAW"
}

run_validate() {
  local log_file="$1"
  shift
  env \
    -u AXVISOR_QEMU_ELF \
    -u AXVISOR_QEMU_KERNEL \
    -u AXVISOR_VM_CONFIGS \
    AXVISOR_QEMU_VALIDATE_ONLY=1 \
    "$@" \
    "$RUNNER" "$log_file" 1
}

expect_success() {
  local name="$1"
  shift
  if ! "$@" >"$COMMAND_OUTPUT" 2>&1; then
    cat "$COMMAND_OUTPUT" >&2
    fail "${name}: expected success"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  if "$@" >"$COMMAND_OUTPUT" 2>&1; then
    fail "${name}: expected failure"
  fi
  rg -q --fixed-strings "$expected" "$COMMAND_OUTPUT" || {
    cat "$COMMAND_OUTPUT" >&2
    fail "${name}: missing failure text: ${expected}"
  }
}

assert_manifest() {
  local manifest="$1"
  local expected="${TEST_ROOT}/expected-manifest.tsv"
  {
    printf 'version\t1\n'
    printf 'elf\t%s\t%s\n' "$(realpath "$DEFAULT_ELF")" "$(sha256sum "$DEFAULT_ELF" | awk '{print $1}')"
    printf 'raw\t%s\t%s\n' "$(realpath "$DEFAULT_RAW")" "$(sha256sum "$DEFAULT_RAW" | awk '{print $1}')"
    for config in \
      "${FIXTURE_CONFIGS}/linux-net-1.toml" \
      "${FIXTURE_CONFIGS}/linux-net-2.toml" \
      "${FIXTURE_CONFIGS}/zephyr-net.toml"; do
      printf 'vm-config\t%s\t%s\n' "$(realpath "$config")" "$(sha256sum "$config" | awk '{print $1}')"
    done
  } >"$expected"
  cmp -s "$expected" "$manifest" || {
    diff -u "$expected" "$manifest" >&2 || true
    fail "manifest rows, paths, hashes, or VM config order are incorrect"
  }
}

write_default_artifacts
DEFAULT_LOG="${TEST_ROOT}/logs/default.log"
expect_success "valid default artifacts" run_validate "$DEFAULT_LOG"
assert_manifest "${DEFAULT_LOG}.build-manifest.tsv"

write_default_artifacts false
expect_failure "missing host policy diagnostic" "required host policy diagnostic is absent" \
  run_validate "${TEST_ROOT}/logs/missing-host-policy-diagnostic.log"

write_default_artifacts
printf 'stale-raw\n' >>"$DEFAULT_RAW"
touch -t 202001010000 "$DEFAULT_ELF"
touch -t 202101010000 "$DEFAULT_RAW"
[ "$DEFAULT_RAW" -nt "$DEFAULT_ELF" ] || fail "stale raw fixture must have the newer mtime"
expect_failure "corrupt newer raw" "regenerated raw binary does not match" \
  run_validate "${TEST_ROOT}/logs/corrupt-newer.log"

write_default_artifacts
touch -t 202001010000 "$DEFAULT_ELF" "$DEFAULT_RAW"
expect_success "equal mtime valid artifacts" run_validate "${TEST_ROOT}/logs/equal-mtime.log"

write_default_artifacts
printf '# changed after build\n' >>"${FIXTURE_CONFIGS}/linux-net-1.toml"
expect_failure "TOML changed after build" "VM config bytes are not embedded" \
  run_validate "${TEST_ROOT}/logs/changed-config.log"

write_default_artifacts
MUTATOR_BIN="${TEST_ROOT}/mutator-bin"
mkdir -p "$MUTATOR_BIN"
cat >"${MUTATOR_BIN}/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$AXVISOR_TEST_REAL_PYTHON" "$@"
printf '# changed during validation\n' >>"$AXVISOR_TEST_MUTATE_CONFIG"
EOF
chmod +x "${MUTATOR_BIN}/python3"
TOCTOU_LOG="${TEST_ROOT}/logs/toctou.log"
expect_failure "input changed during validation" \
  "input changed during validation: vm-config: ${FIXTURE_CONFIGS}/linux-net-2.toml" \
  run_validate "$TOCTOU_LOG" \
  PATH="${MUTATOR_BIN}:${PATH}" \
  AXVISOR_TEST_REAL_PYTHON="$REAL_PYTHON" \
  AXVISOR_TEST_MUTATE_CONFIG="${FIXTURE_CONFIGS}/linux-net-2.toml"
[ ! -e "${TOCTOU_LOG}.build-manifest.tsv" ] \
  || fail "manifest was written after an input changed during validation"

write_default_artifacts
: >"${FIXTURE_CONFIGS}/zephyr-net.toml"
expect_failure "empty VM config" "VM config is empty: ${FIXTURE_CONFIGS}/zephyr-net.toml" \
  run_validate "${TEST_ROOT}/logs/empty-config.log"

write_default_artifacts
TAB_CONFIG="${FIXTURE_CONFIGS}/linux-net-2"$'\t'"copy.toml"
cp "${FIXTURE_CONFIGS}/linux-net-2.toml" "$TAB_CONFIG"
TAB_PATH_LOG="${TEST_ROOT}/logs/tab-path.log"
expect_failure "TAB in canonical config path" "canonical path contains TAB or newline" \
  run_validate "$TAB_PATH_LOG" \
  AXVISOR_VM_CONFIGS="${FIXTURE_CONFIGS}/linux-net-1.toml:${TAB_CONFIG}:${FIXTURE_CONFIGS}/zephyr-net.toml"
[ ! -e "${TAB_PATH_LOG}.build-manifest.tsv" ] \
  || fail "manifest was written for a TSV-unsafe canonical path"

write_default_artifacts
rm "$DEFAULT_ELF"
expect_failure "missing default ELF" "required ELF does not exist" \
  run_validate "${TEST_ROOT}/logs/missing-elf.log"

write_default_artifacts
expect_success "empty kernel override uses default" run_validate \
  "${TEST_ROOT}/logs/empty-kernel.log" AXVISOR_QEMU_KERNEL=

write_default_artifacts
expect_success "empty ELF override uses default" run_validate \
  "${TEST_ROOT}/logs/empty-elf.log" AXVISOR_QEMU_ELF=

write_default_artifacts
printf 'stale-raw\n' >>"$DEFAULT_RAW"
expect_failure "explicit default path cannot bypass validation" "regenerated raw binary does not match" \
  run_validate "${TEST_ROOT}/logs/explicit-default.log" AXVISOR_QEMU_KERNEL="$DEFAULT_RAW"

write_default_artifacts
CUSTOM_ELF="${TEST_ROOT}/custom/axvisor-custom"
CUSTOM_RAW="${TEST_ROOT}/custom/axvisor-custom.bin"
mkdir -p "$(dirname "$CUSTOM_ELF")"
cp "$DEFAULT_ELF" "$CUSTOM_ELF"
rust-objcopy -O binary "$CUSTOM_ELF" "$CUSTOM_RAW"
CUSTOM_LOG="${TEST_ROOT}/logs/custom.log"
expect_success "valid custom kernel and ELF" run_validate "$CUSTOM_LOG" \
  AXVISOR_QEMU_ELF="$CUSTOM_ELF" AXVISOR_QEMU_KERNEL="$CUSTOM_RAW"
DEFAULT_ELF_SAVED="$DEFAULT_ELF"
DEFAULT_RAW_SAVED="$DEFAULT_RAW"
DEFAULT_ELF="$CUSTOM_ELF"
DEFAULT_RAW="$CUSTOM_RAW"
assert_manifest "${CUSTOM_LOG}.build-manifest.tsv"
DEFAULT_ELF="$DEFAULT_ELF_SAVED"
DEFAULT_RAW="$DEFAULT_RAW_SAVED"

write_default_artifacts
expect_failure "custom kernel requires ELF override" "requires a corresponding AXVISOR_QEMU_ELF" \
  run_validate "${TEST_ROOT}/logs/custom-without-elf.log" AXVISOR_QEMU_KERNEL="$CUSTOM_RAW"

write_default_artifacts
expect_failure "missing custom kernel" "required raw binary does not exist" \
  run_validate "${TEST_ROOT}/logs/missing-custom.log" \
  AXVISOR_QEMU_ELF="$DEFAULT_ELF" AXVISOR_QEMU_KERNEL="${TEST_ROOT}/missing/axvisor.bin"

write_default_artifacts
ROOTFS="${TEST_ROOT}/rootfs.img"
QEMU_ENV="${TEST_ROOT}/qemu.env"
QEMU_ARGV="${TEST_ROOT}/qemu.argv"
QEMU_KERNEL_PATH="${TEST_ROOT}/qemu-kernel-path.txt"
QEMU_KERNEL_HASH="${TEST_ROOT}/qemu-kernel-hash.txt"
QEMU_STUB_DIR="${TEST_ROOT}/qemu-bin"
QEMU_STUB="${QEMU_STUB_DIR}/qemu-system-aarch64"
QEMU_LOG="${TEST_ROOT}/logs/qemu-env.log"
THREAD_MAP="${QEMU_LOG}.affinity.tsv"
THREAD_MAP_RAW="${QEMU_LOG}.affinity.tsv.raw"
: >"$ROOTFS"
mkdir -p "$QEMU_STUB_DIR"
cat >"$QEMU_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >"$AXVISOR_TEST_QEMU_ARGV"
env >"$AXVISOR_TEST_QEMU_ENV"
kernel_path=""
qmp_socket=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -kernel)
      shift
      kernel_path="$1"
      ;;
    -qmp)
      shift
      qmp_socket="${1#unix:}"
      qmp_socket="${qmp_socket%%,*}"
      ;;
  esac
  shift || true
done
[ -n "$kernel_path" ] && [ -n "$qmp_socket" ]
printf '%s\n' "$kernel_path" >"$AXVISOR_TEST_QEMU_KERNEL_PATH"
hash_output="$(sha256sum -- "$kernel_path")"
printf '%s\n' "${hash_output%% *}" >"$AXVISOR_TEST_QEMU_KERNEL_HASH"
printf '%s\n' "$$" >"$AXVISOR_TEST_QEMU_PID_FILE"
python3 - "$qmp_socket" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen()
time.sleep(30)
PY
socket_pid=$!
stop_socket() {
  kill "$socket_pid" 2>/dev/null || true
  wait "$socket_pid" 2>/dev/null || true
  exit 0
}
trap stop_socket TERM INT
wait "$socket_pid"
EOF
cat >"${QEMU_STUB_DIR}/socat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
qemu_pid="$(<"$AXVISOR_TEST_QEMU_PID_FILE")"
printf '%s\n' '{"QMP":{"version":{}}}'
printf '%s\n' '{"return":{}}'
printf '{"return":['
printf '{"cpu-index":0,"thread-id":%s,"name":"CPU 0/TCG"},' "$qemu_pid"
printf '{"cpu-index":1,"thread-id":%s,"name":"CPU 1/TCG"},' "$qemu_pid"
printf '{"cpu-index":2,"thread-id":%s,"name":"CPU 2/TCG"}' "$qemu_pid"
printf ']}\n'
EOF
cat >"${QEMU_STUB_DIR}/taskset" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$QEMU_STUB" "${QEMU_STUB_DIR}/socat" "${QEMU_STUB_DIR}/taskset"
printf 'stale intermediate\n' >"$THREAD_MAP_RAW"
expect_success "QEMU child environment and SMP3 QMP probe" \
  env \
  -u AXVISOR_QEMU_VALIDATE_ONLY \
  -u AXVISOR_QEMU_ELF \
  -u AXVISOR_QEMU_KERNEL \
  -u AXVISOR_QEMU_OTHER_CPUS \
  -u AXVISOR_QEMU_IDLE_VCPUS \
  PATH="${QEMU_STUB_DIR}:${PATH}" \
  AXVISOR_QEMU_AARCH64= \
  AXVISOR_QEMU_ROOTFS="$ROOTFS" \
  AXVISOR_TEST_QEMU_ARGV="$QEMU_ARGV" \
  AXVISOR_TEST_QEMU_ENV="$QEMU_ENV" \
  AXVISOR_TEST_QEMU_KERNEL_PATH="$QEMU_KERNEL_PATH" \
  AXVISOR_TEST_QEMU_KERNEL_HASH="$QEMU_KERNEL_HASH" \
  AXVISOR_TEST_QEMU_PID_FILE="${TEST_ROOT}/qemu.pid" \
  AXVISOR_QEMU_SMP=3 \
  AXVISOR_QEMU_VCPU_CPUS=4,5,6 \
  AXVISOR_VM_CONFIGS="${FIXTURE_CONFIGS}/linux-net-1.toml:${FIXTURE_CONFIGS}/linux-net-2.toml:${FIXTURE_CONFIGS}/zephyr-net.toml" \
  "$RUNNER" "$QEMU_LOG" 1
[ -f "$QEMU_ENV" ] || fail "QEMU environment probe did not run"
[ -f "$QEMU_ARGV" ] || fail "QEMU argv probe did not run"
if rg -q '^AXVISOR_VM_CONFIGS=' "$QEMU_ENV"; then
  fail "runtime QEMU environment still contains AXVISOR_VM_CONFIGS"
fi

KERNEL_PATH_USED="$(<"$QEMU_KERNEL_PATH")"
[ "$KERNEL_PATH_USED" != "$(realpath "$DEFAULT_RAW")" ] \
  || fail "QEMU -kernel still points to the source raw binary"
case "$KERNEL_PATH_USED" in
  /tmp/axvisor-qemu-affinity.*/axvisor.bin) ;;
  *) fail "QEMU -kernel is not a private RUN_DIR snapshot: ${KERNEL_PATH_USED}" ;;
esac

MANIFEST_RAW_HASH=""
while IFS=$'\t' read -r row_type _ row_hash; do
  if [ "$row_type" = "raw" ]; then
    MANIFEST_RAW_HASH="$row_hash"
  fi
done <"${QEMU_LOG}.build-manifest.tsv"
[ -n "$MANIFEST_RAW_HASH" ] || fail "manifest has no raw hash row"
[ "$(<"$QEMU_KERNEL_HASH")" = "$MANIFEST_RAW_HASH" ] \
  || fail "QEMU kernel snapshot hash differs from manifest raw hash"
[ ! -e "$KERNEL_PATH_USED" ] || fail "validated kernel snapshot was not cleaned up"
[ ! -e "$THREAD_MAP_RAW" ] || fail "temporary thread map was not cleaned up"
[ -f "$THREAD_MAP" ] || fail "QMP success path did not create an affinity map"
awk -F '\t' '
  NR == 1 { next }
  $1 != NR - 2 || $4 != NR + 2 { bad = 1 }
  END { exit NR == 4 && !bad ? 0 : 1 }
' "$THREAD_MAP" || fail "SMP3 QMP affinity map does not contain 0:4,1:5,2:6"

mapfile -d '' -t QEMU_ARGS <"$QEMU_ARGV"
assert_qemu_arg() {
  local expected="$1"
  local arg
  for arg in "${QEMU_ARGS[@]}"; do
    [ "$arg" != "$expected" ] || return 0
  done
  fail "missing QEMU argument: ${expected}"
}
assert_qemu_arg_pair() {
  local option="$1"
  local value="$2"
  local index
  for index in "${!QEMU_ARGS[@]}"; do
    if [ "${QEMU_ARGS[$index]}" = "$option" ] \
      && [ "${QEMU_ARGS[$((index + 1))]-}" = "$value" ]; then
      return 0
    fi
  done
  fail "missing QEMU argument pair: ${option} ${value}"
}
assert_qemu_arg "filter-dump,id=dump0,netdev=net0,file=${QEMU_LOG}.net0.pcap"
assert_qemu_arg "filter-dump,id=dump1,netdev=net1,file=${QEMU_LOG}.net1.pcap"
assert_qemu_arg "filter-dump,id=dump2,netdev=net2,file=${QEMU_LOG}.net2.pcap"
assert_qemu_arg_pair "-smp" "3"

for pattern in \
  'tcg,thread=multi' \
  'query-cpus-fast' \
  'thread-id' \
  'taskset -pc "$OTHER_CPUS"' \
  'taskset -pc "$host_cpu" "$tid"' \
  'AXVISOR_QEMU_VCPU_CPUS' \
  'AXVISOR_QEMU_SMP' \
  'AXVISOR_QEMU_IDLE_VCPUS' \
  'AXVISOR_QEMU_PIN_VCPUS' \
  'AXVISOR_QEMU_TRACE_DIR' \
  'collect_qemu_sched_trace.sh' \
  'chrt --idle --pid 0 "$tid"' \
  'sched_policy'; do
  rg -q --fixed-strings "$pattern" "$SOURCE" || fail "missing affinity/QMP contract: ${pattern}"
done

rg -q --fixed-strings 'command -v qemu-system-aarch64' "$SOURCE" \
  || fail "QEMU fallback must use command -v"
if rg -q '/home/yfblock/' "$SOURCE"; then
  fail "QEMU runner must not contain a personal-directory default"
fi

echo "[qemu-vcpu-affinity-test] executable artifact contract passed"
