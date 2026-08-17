#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
doctor="$root/scripts/doctor.sh"

fail() {
    printf 'test_doctor: FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s\n' "$1" | grep -F "$2" >/dev/null \
        || fail "expected output to contain: $2"
}

make_fake_path() {
    target=$1
    include_scons=$2
    mkdir -p "$target"
    for tool in dirname sed grep basename sha256sum awk; do
        ln -s "$(command -v "$tool")" "$target/$tool"
    done

    cat >"$target/qemu-system-aarch64" <<'EOF'
#!/bin/sh
case "$*" in
    --version)
        printf 'QEMU emulator version %s\n' "${FAKE_QEMU_VERSION:-8.2.0}"
        ;;
    *'-netdev help'*)
        printf 'Available netdev backend types:\n%s\n' "${FAKE_QEMU_BACKENDS:-socket}"
        ;;
    *)
        exit 2
        ;;
esac
EOF
    cat >"$target/python3" <<'EOF'
#!/bin/sh
[ "${FAKE_NUMPY_MISSING:-0}" -eq 0 ] || exit 1
case "$*" in
    *numpy.__version__*) printf '%s\n' '1.26.4' ;;
esac
EOF
    cat >"$target/host-tool" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$target/qemu-system-aarch64" "$target/python3" "$target/host-tool"
    for tool in git make curl tar xz; do
        ln -s "$target/host-tool" "$target/$tool"
    done
    if [ "$include_scons" = yes ]; then
        ln -s "$target/host-tool" "$target/scons"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fake_path="$tmp/tools"
missing_tool_path="$tmp/missing-tool"
make_fake_path "$fake_path" yes
make_fake_path "$missing_tool_path" no

output=$(TASK3_ROOT="$root" "$root/scripts/doctor.sh" --print-only)
printf '%s\n' "$output" | grep -F 'qemu-system-aarch64='
printf '%s\n' "$output" | grep -F 'aarch64-none-elf-gcc='
printf '%s\n' "$output" | grep -F 'numpy='
printf '%s\n' "$output" | grep -F 'rt_ipc.h=verified'
printf '%s\n' "$output" | grep -F 'rt_ipc.c=verified'

set +e
output=$(PATH="$fake_path" FAKE_NUMPY_MISSING=1 TASK3_ROOT="$root" \
    "$doctor" --print-only 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '--print-only accepted a missing NumPy installation'
assert_contains "$output" 'numpy=missing'

set +e
output=$(PATH="$fake_path" FAKE_QEMU_VERSION=8.1.9 TASK3_ROOT="$root" \
    "$doctor" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'QEMU 8.1 was accepted'
assert_contains "$output" 'QEMU >= 8.2 is required'

output=$(PATH="$fake_path" FAKE_QEMU_VERSION=8.2.0 TASK3_ROOT="$root" \
    "$doctor" 2>&1) || fail 'QEMU 8.2 was rejected'
assert_contains "$output" 'doctor=ok'

set +e
output=$(PATH="$fake_path" FAKE_QEMU_BACKENDS=user TASK3_ROOT="$root" \
    "$doctor" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'QEMU without the socket backend was accepted'
assert_contains "$output" 'socket multicast backend is unavailable'

set +e
output=$(PATH="$missing_tool_path" TASK3_ROOT="$root" "$doctor" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'missing scons was accepted'
assert_contains "$output" 'required host command not found: scons'

bad_rtipc="$tmp/bad-rtipc"
mkdir -p "$bad_rtipc"
printf '%s\n' 'modified header' >"$bad_rtipc/rt_ipc.h"
cp "$root/../rt-ipc/common/rt_ipc.c" "$bad_rtipc/rt_ipc.c"
set +e
output=$(PATH="$fake_path" TASK3_ROOT="$root" RTIPC_DIR="$bad_rtipc" \
    "$doctor" --print-only 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'an incorrect RT-IPC checksum was accepted'
assert_contains "$output" 'sha256 mismatch'

output=$(TASK3_ROOT="$root" sh -c '
    . "$1/scripts/common.sh"
    printf "%s\n%s\n%s\n" "$TASK3_ROOT" "$BUILD_DIR" "$RTIPC_DIR"
' /path/that/does/not/exist/caller "$root" 2>&1) \
    || fail 'common.sh derived paths from the sourcing shell $0'
expected_paths=$(printf '%s\n%s\n%s\n' \
    "$root" "$root/build" "$root/../rt-ipc/common")
[ "$output" = "$expected_paths" ] || fail 'common.sh exported unexpected paths'

no_sha_path="$tmp/no-sha256sum"
mkdir -p "$no_sha_path"
for tool in dirname awk basename; do
    ln -s "$(command -v "$tool")" "$no_sha_path/$tool"
done
set +e
output=$(PATH="$no_sha_path" TASK3_ROOT="$root" /bin/sh -c '
    . "$1/scripts/common.sh"
    verify_sha256 "$1/configs/dependencies.lock" deadbeef
' test "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'verify_sha256 accepted a missing sha256sum command'
assert_contains "$output" 'required command not found: sha256sum'

no_awk_path="$tmp/no-awk"
mkdir -p "$no_awk_path"
for tool in dirname sha256sum basename; do
    ln -s "$(command -v "$tool")" "$no_awk_path/$tool"
done
set +e
output=$(PATH="$no_awk_path" TASK3_ROOT="$root" /bin/sh -c '
    . "$1/scripts/common.sh"
    verify_sha256 "$1/configs/dependencies.lock" deadbeef
' test "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'verify_sha256 accepted a missing awk command'
assert_contains "$output" 'required command not found: awk'

broken_sha_path="$tmp/broken-sha256sum"
mkdir -p "$broken_sha_path"
for tool in dirname awk basename; do
    ln -s "$(command -v "$tool")" "$broken_sha_path/$tool"
done
cat >"$broken_sha_path/sha256sum" <<'EOF'
#!/bin/sh
printf '%s\n' 'sha256sum: simulated read error' >&2
exit 3
EOF
chmod +x "$broken_sha_path/sha256sum"
set +e
output=$(PATH="$broken_sha_path" TASK3_ROOT="$root" /bin/sh -c '
    . "$1/scripts/common.sh"
    verify_sha256 "$1/configs/dependencies.lock" deadbeef
' test "$root" 2>&1)
status=$?
set -e
[ "$status" -eq 3 ] || fail "verify_sha256 replaced sha256sum exit 3 with exit $status"
assert_contains "$output" 'sha256sum: simulated read error'
if printf '%s\n' "$output" | grep -F 'sha256 mismatch' >/dev/null; then
    fail 'verify_sha256 misreported a sha256sum read failure as a mismatch'
fi

printf '%s\n' 'test_doctor: PASS'
