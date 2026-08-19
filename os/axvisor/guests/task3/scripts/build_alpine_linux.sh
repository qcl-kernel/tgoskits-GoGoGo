#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/source_cache.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

REPO_ROOT=$(CDPATH= cd -- "$TASK3_ROOT/../../../.." && pwd)
CACHE_ROOT=$(source_cache_root)
LINUX_VERSION=${LINUX_VERSION:-6.12.21}
LINUX_SHA256=${LINUX_SHA256:-9d1ae39a2ea024d99646f645fdbbbfa4545577132ba2643e01df75e32246d6c7}
ALPINE_VERSION=${ALPINE_VERSION:-3.23.0}
ALPINE_SHA256=${ALPINE_SHA256:-5552106ac866be0c46fdff7a2991a1ed85c0464301a1ac87454c41739d5b6431}
LINUX_ARCHIVE_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz
ALPINE_ARCHIVE_URL=https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/aarch64/alpine-minirootfs-$ALPINE_VERSION-aarch64.tar.gz
LINUX_CACHE=$CACHE_ROOT/linux/$LINUX_VERSION
ALPINE_CACHE=$CACHE_ROOT/alpine/$ALPINE_VERSION
BUILD_DIR=${BUILD_DIR:-$TASK3_ROOT/build/alpine-linux}
OUTPUT_DIR=${OUTPUT_DIR:-$BUILD_DIR/images/linux}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

mkdir -p "$LINUX_CACHE" "$ALPINE_CACHE" "$BUILD_DIR" "$OUTPUT_DIR"

download_verified() {
    url=$1
    archive=$2
    expected=$3
    if [ ! -s "$archive" ]; then
        curl --fail --location --retry 3 --output "$archive.part" "$url"
        mv "$archive.part" "$archive"
    fi
    verify_sha256 "$archive" "$expected"
}

apply_kernel_config() {
    cat "$TASK3_ROOT/configs/linux.config" > "$BUILD_DIR/linux/.config"
    make -C "$BUILD_DIR/linux" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
}

build_linux() {
    if [ -s "$OUTPUT_DIR/Image" ]; then return; fi
    archive=$LINUX_CACHE/linux-$LINUX_VERSION.tar.xz
    download_verified "$LINUX_ARCHIVE_URL" "$archive" "$LINUX_SHA256"
    rm -rf -- "$BUILD_DIR/linux"
    mkdir -p "$BUILD_DIR/linux"
    tar -xJf "$archive" -C "$BUILD_DIR/linux" --strip-components=1
    apply_kernel_config
    make -C "$BUILD_DIR/linux" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image
    install -m 0644 "$BUILD_DIR/linux/arch/arm64/boot/Image" "$OUTPUT_DIR/Image"
}

build_apps() {
    app=$BUILD_DIR/linux-app
    rm -rf -- "$app"
    mkdir -p "$app/task2/linux" "$app/task2/common"
    cp "$TASK3_ROOT/src/linux/"*.c "$TASK3_ROOT/src/linux/"*.h "$app/"
    cp "$TASK3_ROOT/src/common/"*.c "$TASK3_ROOT/src/common/"*.h "$app/"
    cp "$REPO_ROOT/os/axvisor/guests/rt-ipc/common/"*.c \
       "$REPO_ROOT/os/axvisor/guests/rt-ipc/common/"*.h "$app/task2/common/"
    cp "$REPO_ROOT/os/axvisor/guests/rt-ipc/linux/"*.c \
       "$REPO_ROOT/os/axvisor/guests/rt-ipc/linux/"*.h "$app/task2/linux/"
    cp "$REPO_ROOT/os/axvisor/guests/rt-ipc/linux/Makefile" "$app/task2/linux/"
    cp "$CACHE_ROOT/task3-model/model_weights.h" "$app/"
    make -C "$app/task2/linux" CROSS_COMPILE=aarch64-linux-gnu- target/rtipic-client
    aarch64-linux-gnu-gcc -std=c11 -O2 -static -Wall -Wextra \
        -I"$app" -I"$app/task2/common" -o "$app/task3-linux" \
        "$app/main.c" "$app/rtipc_client.c" "$app/deadline.c" \
        "$app/metrics.c" "$app/y4m.c" "$app/cnn.c" "$app/session.c" \
        "$app/task3_protocol.c" "$app/task2/common/rt_ipc.c"
}

build_initramfs() {
    if [ -s "$OUTPUT_DIR/rootfs.cpio.gz" ]; then return; fi
    archive=$ALPINE_CACHE/alpine-minirootfs-$ALPINE_VERSION-aarch64.tar.gz
    download_verified "$ALPINE_ARCHIVE_URL" "$archive" "$ALPINE_SHA256"
    root=$BUILD_DIR/alpine-root
    rm -rf -- "$root"
    mkdir -p "$root"
    tar -xzf "$archive" -C "$root"
    build_apps
    install -D -m 0755 "$BUILD_DIR/linux-app/task2/linux/target/rtipic-client" \
        "$root/bin/rtipic-client"
    install -D -m 0755 "$BUILD_DIR/linux-app/task3-linux" \
        "$root/usr/bin/task3-linux"
    install -D -m 0755 "$REPO_ROOT/os/axvisor/guests/linux-net/init-task123" \
        "$root/init"
    install -d -m 0755 "$root/opt/task3"
    install -m 0644 "$CACHE_ROOT/task3-model/line-follow.y4m" \
        "$CACHE_ROOT/task3-model/truth.csv" "$root/opt/task3/"
    (cd "$root" && find . -print0 | cpio --null -o --format=newc) |
        gzip -1 > "$OUTPUT_DIR/rootfs.cpio.gz.part"
    mv "$OUTPUT_DIR/rootfs.cpio.gz.part" "$OUTPUT_DIR/rootfs.cpio.gz"
    rm -f "$OUTPUT_DIR/rootfs.cpio"
    ln -s rootfs.cpio.gz "$OUTPUT_DIR/rootfs.cpio"
}

build_linux
build_initramfs
printf 'linux_image=%s\nlinux_initrd=%s\n' \
    "$OUTPUT_DIR/Image" "$OUTPUT_DIR/rootfs.cpio"
