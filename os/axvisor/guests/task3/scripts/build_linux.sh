#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"
. "$TASK3_ROOT/configs/dependencies.lock"

output="$BUILD_DIR/buildroot"
mkdir -p "$BUILD_DIR"
require_command flock
exec 9>"$output.lock"
flock -n 9 || die "another Linux image build owns $output"

"$SCRIPT_DIR/fetch_sources.sh" --sources-only
[ -s "$BUILD_DIR/model/model_weights.h" ] ||
    "$SCRIPT_DIR/build_model.sh"

source_tree="$BUILD_DIR/sources/buildroot"
staging="$BUILD_DIR/staging/linux-app"
images="$BUILD_DIR/images/linux"
downloads="$BUILD_DIR/downloads/buildroot"

[ -d "$source_tree/.git" ] || die "Buildroot source is not a Git checkout"
[ "$(git -C "$source_tree" remote get-url origin)" = "$BUILDROOT_URL" ] ||
    die "Buildroot source origin changed"
[ "$(git -C "$source_tree" rev-parse HEAD)" = "$BUILDROOT_COMMIT" ] ||
    die "Buildroot source commit changed"
[ -z "$(git -C "$source_tree" symbolic-ref -q HEAD)" ] ||
    die "Buildroot source is not detached"
rm -rf "$staging"
mkdir -p "$staging" "$output" "$images" "$downloads"
for file in \
    src/linux/main.c src/linux/rtipc_client.c src/linux/rtipc_client.h \
    src/linux/deadline.c src/linux/deadline.h \
    src/linux/metrics.c src/linux/metrics.h src/linux/y4m.c src/linux/y4m.h \
    src/linux/cnn.c src/linux/cnn.h src/common/session.c src/common/session.h \
    src/common/task3_protocol.c src/common/task3_protocol.h; do
    cp "$TASK3_ROOT/$file" "$staging/"
done
cp "$RTIPC_DIR/rt_ipc.c" "$RTIPC_DIR/rt_ipc.h" "$staging/"
cp "$BUILD_DIR/model/model_weights.h" "$BUILD_DIR/model/line-follow.y4m" \
    "$BUILD_DIR/model/truth.csv" "$staging/"

make -C "$source_tree" O="$output" BR2_EXTERNAL="$TASK3_ROOT/buildroot" \
    BR2_DEFCONFIG="$TASK3_ROOT/configs/buildroot_defconfig" defconfig
make -C "$source_tree" O="$output" BR2_EXTERNAL="$TASK3_ROOT/buildroot" \
    BR2_DL_DIR="$downloads" task3-linux-dirclean
make -C "$source_tree" O="$output" BR2_EXTERNAL="$TASK3_ROOT/buildroot" \
    BR2_DL_DIR="$downloads" -j"$(getconf _NPROCESSORS_ONLN)"

test -s "$output/images/Image"
test -s "$output/images/rootfs.cpio"
cp "$output/images/Image" "$images/Image"
cp "$output/images/rootfs.cpio" "$images/rootfs.cpio"
printf 'linux_image=%s\nlinux_initrd=%s\n' \
    "$images/Image" "$images/rootfs.cpio"
