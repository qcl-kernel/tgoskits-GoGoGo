#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"
# shellcheck disable=SC1091
. "$TASK3_ROOT/configs/dependencies.lock"

print_only=0
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 1 ] && [ "$1" = "--print-only" ] || die "usage: $0 [--print-only]"
    print_only=1
fi

status_command() {
    name=$1
    if path=$(command -v "$name" 2>/dev/null); then
        printf '%s=%s\n' "$name" "$path"
        return 0
    fi
    printf '%s=missing\n' "$name"
    return 1
}

qemu_path=$(command -v qemu-system-aarch64 2>/dev/null || true)
if [ -n "$qemu_path" ]; then
    qemu_version=$("$qemu_path" --version 2>/dev/null | sed -n '1s/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    [ -n "$qemu_version" ] || qemu_version=unknown
    printf 'qemu-system-aarch64=%s (%s)\n' "$qemu_path" "$qemu_version"
else
    qemu_version=missing
    printf 'qemu-system-aarch64=missing\n'
fi

if gcc_path=$(command -v aarch64-none-elf-gcc 2>/dev/null); then
    printf 'aarch64-none-elf-gcc=%s\n' "$gcc_path"
    gcc_missing=0
else
    printf 'aarch64-none-elf-gcc=managed-download\n'
    gcc_missing=1
fi

python_path=$(command -v python3 2>/dev/null || true)
if [ -n "$python_path" ]; then
    printf 'python3=%s\n' "$python_path"
else
    printf 'python3=missing\n'
fi
for tool in git make scons; do
    status_command "$tool" || true
done
if [ "$gcc_missing" -eq 1 ]; then
    for tool in curl tar xz; do
        status_command "$tool" || true
    done
fi

numpy_status=missing
if [ -n "$python_path" ] && "$python_path" -c 'import numpy' >/dev/null 2>&1; then
    numpy_version=$("$python_path" -c 'import numpy; print(numpy.__version__)' 2>/dev/null)
    numpy_status=$numpy_version
fi
printf 'numpy=%s\n' "$numpy_status"
[ "$numpy_status" != missing ] || die "Python NumPy is required"

verify_sha256 "$RTIPC_DIR/rt_ipc.h" "$RTIPC_HEADER_SHA256"
verify_sha256 "$RTIPC_DIR/rt_ipc.c" "$RTIPC_SOURCE_SHA256"

if [ "$print_only" -eq 1 ]; then
    exit 0
fi

[ -n "$qemu_path" ] || die "qemu-system-aarch64 is required"
case "$qemu_version" in
    unknown|missing) die "unable to determine QEMU version" ;;
    *)
        qemu_major=${qemu_version%%.*}
        qemu_minor=${qemu_version#*.}
        if [ "$qemu_major" -lt 8 ] || { [ "$qemu_major" -eq 8 ] && [ "$qemu_minor" -lt 2 ]; }; then
            die "QEMU >= 8.2 is required (found $qemu_version)"
        fi
        ;;
esac

netdev_help=$("$qemu_path" -machine virt -netdev help 2>&1 || true)
printf '%s\n' "$netdev_help" | grep -Eq '(^|[[:space:]])socket([[:space:]]|$)' \
    || die "QEMU socket multicast backend is unavailable"

for tool in git make scons; do
    command -v "$tool" >/dev/null 2>&1 || die "required host command not found: $tool"
done
if [ "$gcc_missing" -eq 1 ]; then
    for tool in curl tar xz; do
        require_command "$tool"
    done
fi

printf '%s\n' 'doctor=ok'
