#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
TASK123_INIT="$TASK3_ROOT/../linux-net/init-task123"
TASK3_SERVICE="$TASK3_ROOT/buildroot/rootfs-overlay/etc/init.d/S99task3"
TASK2_MAKEFILE="$TASK3_ROOT/../rt-ipc/linux/Makefile"
. "$TASK3_ROOT/configs/dependencies.lock"

required_files='
scripts/fetch_sources.sh
scripts/set_kconfig.py
scripts/check_elf_entry.py
scripts/build_linux.sh
scripts/build_rtthread.sh
configs/buildroot_defconfig
configs/linux.config
configs/rtthread.config
buildroot/external.desc
buildroot/Config.in
buildroot/external.mk
buildroot/package/task3-linux/Config.in
buildroot/package/task3-linux/task3-linux.mk
buildroot/rootfs-overlay/etc/init.d/S99task3
patches/rtthread/0001-qemu-virt64-task3-config.patch
'
for file in $required_files; do
    test -s "$TASK3_ROOT/$file" || {
        echo "missing build contract file: $file" >&2
        exit 1
    }
done

for script in fetch_sources.sh build_linux.sh build_rtthread.sh; do
    test -x "$TASK3_ROOT/scripts/$script"
    sh -n "$TASK3_ROOT/scripts/$script"
done
python3 -m py_compile "$TASK3_ROOT/scripts/set_kconfig.py" \
    "$TASK3_ROOT/scripts/check_elf_entry.py"

grep -F 'RTTHREAD_COMMIT' "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null
grep -F 'BUILDROOT_COMMIT' "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null
grep -F 'ARM_TOOLCHAIN_SHA256' "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null
grep -F 'rev-parse HEAD' "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null
grep -Fx 'RTTHREAD_COMMIT=ddf52e2cdd977f14fc04035c88672ac204aec713' \
    "$TASK3_ROOT/configs/dependencies.lock" >/dev/null
grep -Fx 'BUILDROOT_COMMIT=3815d578c5759fa824322ea3d95ad51b55ab888e' \
    "$TASK3_ROOT/configs/dependencies.lock" >/dev/null
grep -Fx 'BUILDROOT_URL=https://gitlab.com/buildroot.org/buildroot.git' \
    "$TASK3_ROOT/configs/dependencies.lock" >/dev/null
grep -Fx 'ARM_TOOLCHAIN_SHA256=eb54c4727440d03199a6af9a6d021e77f45410cad39effce4e5a1c10a88b7f04' \
    "$TASK3_ROOT/configs/dependencies.lock" >/dev/null
grep -F 'clone_locked buildroot "$BUILDROOT_URL"' \
    "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null
if grep -F 'BUILDROOT_TARBALL' "$TASK3_ROOT/scripts/fetch_sources.sh" >/dev/null; then
    echo 'Buildroot tarball fallback is not an exact Git checkout' >&2
    exit 1
fi
grep -F 'scons --pyconfig-silent' "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null
grep -F 'check_elf_entry.py' "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null
grep -F 'flock -n 9' "$TASK3_ROOT/scripts/build_linux.sh" >/dev/null
grep -F 'task3-linux-dirclean' "$TASK3_ROOT/scripts/build_linux.sh" >/dev/null
grep -F 'TASK3_LINUX_SITE="$staging"' \
    "$TASK3_ROOT/scripts/build_linux.sh" >/dev/null
grep -F 'TASK3_LINUX_SITE = $(BR2_EXTERNAL_TASK3_PATH)/../build/staging/linux-app' \
    "$TASK3_ROOT/buildroot/package/task3-linux/task3-linux.mk" >/dev/null
if grep -F 'TASK3_LINUX_SITE ?=' \
    "$TASK3_ROOT/buildroot/package/task3-linux/task3-linux.mk" >/dev/null; then
    echo 'TASK3_LINUX_SITE must not accept an ambient environment override' >&2
    exit 1
fi
grep -F 'flock -n 9' "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null
if grep -F 'rtconfig.h' "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null; then
    echo 'build_rtthread.sh must not write rtconfig.h' >&2
    exit 1
fi

test -x "$TASK123_INIT"
for marker in TASK2_LINUX_BEGIN TASK2_LINUX_END TASK3_LINUX_READY \
    TASK3_LINUX_END TASK123_LINUX_END; do
    grep -F "$marker" "$TASK123_INIT" >/dev/null
done
for token in \
    '--port 9877' \
    'TASK2_LINUX_END status=FAIL exit_status=%s' \
    'TASK3_LINUX_END status=FAIL exit_status=%s' \
    'TASK123_LINUX_END status=FAIL'; do
    grep -F -- "$token" "$TASK123_INIT" >/dev/null
done
test "$(grep -Fc '/bin/busybox poweroff -f' "$TASK123_INIT")" -eq 1
service_commands=$(sed -e '/^#!/d' -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' "$TASK3_SERVICE")
test "$service_commands" = 'exec /init'
if grep -F 'poweroff -f' "$TASK3_SERVICE" >/dev/null; then
    echo 'S99task3 must not power off independently' >&2
    exit 1
fi
grep -Fx 'all: target/rtipic-client' "$TASK2_MAKEFILE" >/dev/null

for setting in \
    'BR2_aarch64=y' \
    'BR2_cortex_a53=y' \
    'BR2_LINUX_KERNEL=y' \
    'BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_12=y' \
    'BR2_TARGET_ROOTFS_CPIO=y' \
    'BR2_PACKAGE_TASK3_LINUX=y'; do
    grep -Fx "$setting" "$TASK3_ROOT/configs/buildroot_defconfig" >/dev/null
done

for setting in \
    'CONFIG_ARM64=y' \
    'CONFIG_SMP=y' \
    'CONFIG_NR_CPUS=2' \
    'CONFIG_VIRTIO_MMIO=y' \
    'CONFIG_VIRTIO_NET=y' \
    'CONFIG_DEVTMPFS=y' \
    'CONFIG_DEVTMPFS_MOUNT=y' \
    'CONFIG_BLK_DEV_INITRD=y' \
    'CONFIG_PROC_FS=y' \
    'CONFIG_SYSFS=y' \
    'CONFIG_INET=y'; do
    grep -Fx "$setting" "$TASK3_ROOT/configs/linux.config" >/dev/null
done

for setting in \
    'CONFIG_RT_CPUS_NR=1' \
    'CONFIG_ARCH_RAM_OFFSET=0x40000000' \
    'CONFIG_RT_USING_LWIP=y' \
    'CONFIG_RT_USING_LWIP212=y' \
    'CONFIG_RT_LWIP_UDP=y' \
    'CONFIG_RT_LWIP_TCP=y' \
    'CONFIG_RT_LWIP_DNS=y' \
    'CONFIG_RT_LWIP_TCPTHREAD_STACKSIZE=8192' \
    'CONFIG_RT_USING_NETDEV=y' \
    'CONFIG_RT_USING_SAL=y' \
    'CONFIG_SAL_USING_LWIP=y' \
    'CONFIG_RT_USING_VIRTIO=y' \
    'CONFIG_BSP_USING_VIRTIO_NET=y' \
    'CONFIG_RT_LWIP_IPADDR="192.168.77.30"' \
    'CONFIG_RT_LWIP_MSKADDR="255.255.255.0"'; do
    grep -Fx "$setting" "$TASK3_ROOT/configs/rtthread.config" >/dev/null
done
if grep -Eq '^CONFIG_RT_(VIRTIO_NET|VIRTIO_TRANSPORT_MMIO)=' \
    "$TASK3_ROOT/configs/rtthread.config"; then
    echo 'rtthread.config contains nonexistent virtio symbols' >&2
    exit 1
fi
grep -F 'CONFIG_RT_USING_VIRTIO_NET=y' \
    "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null
grep -F 'rt_virtio_net_init' "$TASK3_ROOT/scripts/build_rtthread.sh" >/dev/null

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

lock_build="$tmp_dir/linux-lock"
mkdir -p "$lock_build"
exec 8>"$lock_build/buildroot.lock"
flock -n 8
if BUILD_DIR="$lock_build" "$TASK3_ROOT/scripts/build_linux.sh" \
    >"$lock_build/output" 2>&1; then
    echo 'build_linux accepted an already-held output lock' >&2
    exit 1
fi
flock -u 8
exec 8>&-
grep -F 'another Linux image build owns' "$lock_build/output" >/dev/null

checksum_build="$tmp_dir/checksum"
checksum_cache="$checksum_build/source-cache"
mkdir -p "$checksum_cache/arm-gnu-toolchain/$ARM_TOOLCHAIN_VERSION"
printf '%s\n' corrupt > \
    "$checksum_cache/arm-gnu-toolchain/$ARM_TOOLCHAIN_VERSION/archive.tar.xz"
if TGOS_SOURCE_CACHE="$checksum_cache" BUILD_DIR="$checksum_build" \
    "$TASK3_ROOT/scripts/fetch_sources.sh" --toolchain-only \
    >"$checksum_build/output" 2>&1; then
    echo 'fetch_sources accepted a corrupt toolchain archive' >&2
    exit 1
fi
grep -F 'sha256 mismatch' "$checksum_build/output" >/dev/null
test ! -e "$checksum_build/toolchains/arm-gnu-toolchain-$ARM_TOOLCHAIN_VERSION/bin/aarch64-none-elf-gcc"

fixture_repository="$tmp_dir/source-fixture"
git init --quiet "$fixture_repository"
git -C "$fixture_repository" -c user.name=Task3 \
    -c user.email=task3@example.invalid commit --quiet --allow-empty \
    -m 'fixture source'
fixture_commit=$(git -C "$fixture_repository" rev-parse HEAD)
fixture_root="$tmp_dir/fetch-root"
mkdir -p "$fixture_root/scripts" "$fixture_root/configs"
cp "$TASK3_ROOT/scripts/common.sh" "$TASK3_ROOT/scripts/source_cache.sh" \
    "$TASK3_ROOT/scripts/fetch_sources.sh" \
    "$fixture_root/scripts/"
sed \
    -e "s/^RTTHREAD_COMMIT=.*/RTTHREAD_COMMIT=$fixture_commit/" \
    -e "s/^BUILDROOT_COMMIT=.*/BUILDROOT_COMMIT=$fixture_commit/" \
    "$TASK3_ROOT/configs/dependencies.lock" \
    >"$fixture_root/configs/dependencies.lock"

make_valid_rt_checkout() {
    destination=$1
    git -c advice.detachedHead=false clone --quiet --shared \
        "$fixture_repository" "$destination"
    git -C "$destination" remote set-url origin \
        https://github.com/RT-Thread/rt-thread.git
    git -C "$destination" checkout --quiet --detach "$fixture_commit"
}

expect_fetch_failure() {
    build_dir=$1
    cache_root=$2
    message=$3
    if TASK3_ROOT="$fixture_root" BUILD_DIR="$build_dir" \
        TGOS_SOURCE_CACHE="$cache_root" \
        "$fixture_root/scripts/fetch_sources.sh" --sources-only \
        >"$build_dir/output" 2>&1; then
        echo "fetch_sources unexpectedly accepted: $message" >&2
        exit 1
    fi
    grep -F "$message" "$build_dir/output" >/dev/null
}

case_dir="$tmp_dir/rt-origin"
cache_root="$case_dir/cache"
mkdir -p "$cache_root/rt-thread/$fixture_commit"
git -c advice.detachedHead=false clone --quiet --shared \
    "$fixture_repository" \
    "$cache_root/rt-thread/$fixture_commit/source"
expect_fetch_failure "$case_dir" "$cache_root" 'rt-thread cache origin mismatch'

case_dir="$tmp_dir/rt-head"
cache_root="$case_dir/cache"
mkdir -p "$case_dir/sources" "$cache_root/rt-thread/$fixture_commit"
make_valid_rt_checkout "$case_dir/sources/rt-thread"
mv "$case_dir/sources/rt-thread" \
    "$cache_root/rt-thread/$fixture_commit/source"
git -C "$cache_root/rt-thread/$fixture_commit/source" -c user.name=Task3 \
    -c user.email=task3@example.invalid commit --quiet --allow-empty \
    -m 'mismatched head'
expect_fetch_failure "$case_dir" "$cache_root" 'rt-thread cache commit mismatch'

case_dir="$tmp_dir/rt-attached"
cache_root="$case_dir/cache"
mkdir -p "$case_dir/sources" "$cache_root/rt-thread/$fixture_commit"
make_valid_rt_checkout "$case_dir/sources/rt-thread"
mv "$case_dir/sources/rt-thread" \
    "$cache_root/rt-thread/$fixture_commit/source"
git -C "$cache_root/rt-thread/$fixture_commit/source" switch --quiet -c attached-test
expect_fetch_failure "$case_dir" "$cache_root" \
    'rt-thread cached checkout is not detached'

case_dir="$tmp_dir/buildroot-origin"
cache_root="$case_dir/cache"
mkdir -p "$case_dir/sources" "$cache_root/rt-thread/$fixture_commit" \
    "$cache_root/buildroot/$fixture_commit"
make_valid_rt_checkout "$case_dir/sources/rt-thread"
mv "$case_dir/sources/rt-thread" \
    "$cache_root/rt-thread/$fixture_commit/source"
git -c advice.detachedHead=false clone --quiet --shared \
    "$fixture_repository" \
    "$cache_root/buildroot/$fixture_commit/source"
expect_fetch_failure "$case_dir" "$cache_root" 'buildroot cache origin mismatch'

case_dir="$tmp_dir/buildroot-head"
cache_root="$case_dir/cache"
mkdir -p "$case_dir/sources" "$cache_root/rt-thread/$fixture_commit" \
    "$cache_root/buildroot/$fixture_commit"
make_valid_rt_checkout "$case_dir/sources/rt-thread"
mv "$case_dir/sources/rt-thread" \
    "$cache_root/rt-thread/$fixture_commit/source"
git -c advice.detachedHead=false clone --quiet --shared \
    "$fixture_repository" \
    "$cache_root/buildroot/$fixture_commit/source"
git -C "$cache_root/buildroot/$fixture_commit/source" remote set-url origin \
    https://gitlab.com/buildroot.org/buildroot.git
git -C "$cache_root/buildroot/$fixture_commit/source" -c user.name=Task3 \
    -c user.email=task3@example.invalid commit --quiet --allow-empty \
    -m 'mismatched buildroot head'
expect_fetch_failure "$case_dir" "$cache_root" 'buildroot cache commit mismatch'

printf '%s\n' 'CONFIG_KEEP=y' '# CONFIG_CHANGE is not set' >"$tmp_dir/.config"
python3 "$TASK3_ROOT/scripts/set_kconfig.py" "$tmp_dir/.config" \
    CONFIG_KEEP=n CONFIG_CHANGE=y CONFIG_TEXT='"value"'
grep -Fx '# CONFIG_KEEP is not set' "$tmp_dir/.config" >/dev/null
grep -Fx 'CONFIG_CHANGE=y' "$tmp_dir/.config" >/dev/null
grep -Fx 'CONFIG_TEXT="value"' "$tmp_dir/.config" >/dev/null

python3 "$TASK3_ROOT/scripts/check_elf_entry.py" 0x40000000
python3 "$TASK3_ROOT/scripts/check_elf_entry.py" 0x47ffffff
for invalid_entry in 0x3fffffff 0x48000000 0x4fffffff not-hex; do
    if python3 "$TASK3_ROOT/scripts/check_elf_entry.py" "$invalid_entry" \
        >"$tmp_dir/elf-entry-output" 2>&1; then
        echo "accepted invalid ELF entry: $invalid_entry" >&2
        exit 1
    fi
done

printf '%s\n' 'test_build_contracts: PASS'
