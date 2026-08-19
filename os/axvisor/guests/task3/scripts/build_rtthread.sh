#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/source_cache.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

case "${1:-}" in
    "") ;;
    *) die "usage: $0" ;;
esac

mkdir -p "$BUILD_DIR/work"
require_command flock
exec 9>"$BUILD_DIR/work/rtthread.lock"
flock -n 9 || die "another RT-Thread build is running"

"$SCRIPT_DIR/fetch_sources.sh"
source_tree="$BUILD_DIR/sources/rt-thread"
toolchain="$BUILD_DIR/toolchains/arm-gnu-toolchain-$ARM_TOOLCHAIN_VERSION"
work_tree="$BUILD_DIR/work/rtthread"
image_dir="$BUILD_DIR/images/rtthread"
python_dir="$(source_cache_root)/python/kconfiglib/$KCONFIGLIB_VERSION"
bsp="$work_tree/bsp/qemu-virt64-aarch64"
app="$bsp/applications/task3"
packages_stub="$work_tree/packages-stub"

[ "$(git -C "$source_tree" rev-parse HEAD)" = "$RTTHREAD_COMMIT" ] ||
    die "RT-Thread source commit changed"
mkdir -p "$python_dir"
exec 8>"$python_dir.lock"
flock 8
if ! PYTHONPATH="$python_dir" python3 -c 'import kconfiglib' 2>/dev/null; then
    python3 -m pip install --disable-pip-version-check --no-deps \
        --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
        --target "$python_dir" "kconfiglib==$KCONFIGLIB_VERSION"
fi
rm -rf "$work_tree"
mkdir -p "$(dirname "$work_tree")" "$image_dir"
git clone --quiet --shared "$source_tree" "$work_tree"
git -C "$work_tree" checkout --quiet --detach "$RTTHREAD_COMMIT"
git -C "$work_tree" apply --unidiff-zero \
    "$TASK3_ROOT/patches/rtthread/0001-qemu-virt64-task3-config.patch"
mkdir -p "$app"
mkdir -p "$packages_stub"
: >"$packages_stub/Kconfig"
cp "$TASK3_ROOT/src/rtthread/task3_server.c" \
    "$TASK3_ROOT/src/rtthread/SConscript" \
    "$TASK3_ROOT/src/common/controller.c" \
    "$TASK3_ROOT/src/common/controller.h" \
    "$TASK3_ROOT/src/common/task3_protocol.c" \
    "$TASK3_ROOT/src/common/task3_protocol.h" \
    "$TASK3_ROOT/src/common/session.c" \
    "$TASK3_ROOT/src/common/session.h" \
    "$RTIPC_DIR/rt_ipc.c" \
    "$RTIPC_DIR/rt_ipc.h" \
    "$app/"

python3 "$TASK3_ROOT/scripts/set_kconfig.py" "$bsp/.config" \
    --fragment "$TASK3_ROOT/configs/rtthread.config"
(
    cd "$bsp"
    export RTT_EXEC_PATH="$toolchain/bin"
    export RTT_CC_PREFIX=aarch64-none-elf-
    export PATH="$toolchain/bin:$PATH"
    export PYTHONPATH="$python_dir"
    export PKGS_DIR="$packages_stub"
    scons --pyconfig-silent
    scons -j"$(getconf _NPROCESSORS_ONLN)"
)

test -s "$bsp/rtthread.bin"
test -s "$bsp/rtthread.elf"
grep -Fx 'CONFIG_BSP_USING_VIRTIO_NET=y' "$bsp/.config" >/dev/null
grep -Fx 'CONFIG_RT_USING_VIRTIO_NET=y' "$bsp/.config" >/dev/null
"$toolchain/bin/aarch64-none-elf-nm" "$bsp/rtthread.elf" |
    grep -F ' task3_server_start' >/dev/null
"$toolchain/bin/aarch64-none-elf-nm" "$bsp/rtthread.elf" |
    grep -F ' rt_virtio_net_init' >/dev/null
entry=$("$toolchain/bin/aarch64-none-elf-readelf" -h "$bsp/rtthread.elf" |
    awk '/Entry point address:/ {print $4}')
python3 "$TASK3_ROOT/scripts/check_elf_entry.py" "$entry"

cp "$bsp/rtthread.bin" "$image_dir/rtthread.bin"
cp "$bsp/rtthread.elf" "$image_dir/rtthread.elf"
printf 'rtthread_image=%s\n' "$image_dir/rtthread.bin"
