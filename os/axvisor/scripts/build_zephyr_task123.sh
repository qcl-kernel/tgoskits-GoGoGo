#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
export TGOS_SOURCE_CACHE="${TGOS_SOURCE_CACHE:-$ROOT/tmp/source-cache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$TGOS_SOURCE_CACHE/uv}"
source "$SCRIPT_DIR/network_env.sh"

ZEPHYR_VERSION=v4.4.2
ZEPHYR_COMMIT=dccb09599635bdff17633fa7e9dab014b91dce90
ZEPHYR_SDK_VERSION=1.0.1
VERSION_ROOT="$TGOS_SOURCE_CACHE/zephyr/$ZEPHYR_COMMIT"
SOURCE="$VERSION_ROOT/source"
PYTHON_VENV="$VERSION_ROOT/zephyr-venv-312"
SDK="$TGOS_SOURCE_CACHE/zephyr-sdk/zephyr-sdk-$ZEPHYR_SDK_VERSION"
SDK_CURRENT="$TGOS_SOURCE_CACHE/zephyr-sdk/current"
APP="${ZEPHYR_TASK123_APP:-$ROOT/os/axvisor/guests/zephyr-task123}"
OUTPUT="${1:-$TGOS_SOURCE_CACHE/zephyr/$ZEPHYR_COMMIT/current-image}"
BUILD="${ZEPHYR_TASK123_BUILD:-$VERSION_ROOT/build-task123}"
JOBS="${ZEPHYR_TASK123_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
die() { echo "build-zephyr-task123: $*" >&2; exit 1; }

zephyr_generation_is_current() {
    local output=$1
    local expected_input_digest=$2
    local current="$output/current"
    local digest_file="$current/zephyr.bin.inputs.sha256"
    local cached_input_digest=

    [[ "$expected_input_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -L "$current" && -s "$current/zephyr.bin" &&
       -s "$current/zephyr.bin.meta.json" && -s "$digest_file" ]] || return 1
    cached_input_digest="$(sed -n '1p' "$digest_file")"
    [[ "$cached_input_digest" == "$expected_input_digest" ]] || return 1
    [[ "$(wc -l < "$digest_file")" -eq 1 ]] || return 1
    "$SCRIPT_DIR/zephyr_image_metadata.py" check \
        --image "$current/zephyr.bin" \
        --metadata "$current/zephyr.bin.meta.json" >/dev/null
}

publish_zephyr_generation() {
    local image=$1
    local metadata=$2
    local input_digest_value=$3
    local output=$4
    local generations="$output/generations"
    local staging
    local generation
    local generation_name
    local current_link
    local publication_lock_fd

    [[ -s "$image" && -s "$metadata" ]] ||
        die "Zephyr generation inputs are missing"
    [[ "$input_digest_value" =~ ^[0-9a-f]{64}$ ]] ||
        die "Zephyr generation input digest is invalid"
    mkdir -p -- "$generations"
    exec {publication_lock_fd}>"$output/.publication.lock"
    flock "$publication_lock_fd"

    staging="$(mktemp -d "$generations/.staging.XXXXXX")"
    if ! cp -- "$image" "$staging/zephyr.bin" ||
       ! cp -- "$metadata" "$staging/zephyr.bin.meta.json" ||
       ! printf '%s\n' "$input_digest_value" > "$staging/zephyr.bin.inputs.sha256"; then
        rm -rf -- "$staging"
        return 1
    fi
    if ! "$SCRIPT_DIR/zephyr_image_metadata.py" check \
            --image "$staging/zephyr.bin" \
            --metadata "$staging/zephyr.bin.meta.json" >/dev/null; then
        rm -rf -- "$staging"
        return 1
    fi

    generation_name="generation-${input_digest_value:0:16}-$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"
    generation="$generations/$generation_name"
    if ! mv -- "$staging" "$generation"; then
        rm -rf -- "$staging"
        return 1
    fi
    current_link="$output/.current.$$.$RANDOM"
    if ! ln -s -- "generations/$generation_name" "$current_link" ||
       ! mv -Tf -- "$current_link" "$output/current"; then
        rm -f -- "$current_link"
        return 1
    fi
}

input_digest_material_tree() {
    local label=$1
    local tree=$2
    local relative
    local digest

    printf 'tree=%s\n' "$label"
    while IFS= read -r -d '' relative; do
        digest="$(sha256sum -- "$tree/$relative")"
        digest=${digest%% *}
        printf '%s  %s/%s\n' "$digest" "$label" "$relative"
    done < <(find "$tree" -type f -printf '%P\0' | LC_ALL=C sort -z)
}

input_digest() {
    local builder_digest
    {
        input_digest_material_tree zephyr-task123-app "$APP"
        input_digest_material_tree rt-ipc-common "$ROOT/os/axvisor/guests/rt-ipc/common"
        input_digest_material_tree task3-common "$ROOT/os/axvisor/guests/task3/src/common"
        printf 'builder-script\n'
        builder_digest="$(sha256sum -- "$SCRIPT_DIR/build_zephyr_task123.sh")"
        builder_digest=${builder_digest%% *}
        printf '%s  builder-script\n' "$builder_digest"
    } | sha256sum | awk '{print $1}'
}

main() {
    local expected_input_digest
    local artifact_staging
    local entry
    local build_lock_fd

    if [[ "${1:-}" == "--input-digest" ]]; then
        [[ "$#" -eq 1 ]] || die "--input-digest does not accept additional arguments"
        input_digest
        return 0
    fi
    [[ "$#" -le 1 ]] || die "expected at most one output directory"

    for tool in curl sha256sum tar cmake ninja dtc readelf python3 uv flock; do
        command -v "$tool" >/dev/null || die "required command not found: $tool"
    done
    mkdir -p -- "$VERSION_ROOT" "$OUTPUT"
    exec {build_lock_fd}>"$VERSION_ROOT/.task123-image-build.lock"
    flock "$build_lock_fd"
    expected_input_digest="$(input_digest)"
    if zephyr_generation_is_current "$OUTPUT" "$expected_input_digest"; then
        echo "Zephyr Task123 image cache is current: $OUTPUT/current/zephyr.bin"
        return 0
    fi

    "$SCRIPT_DIR/prepare_zephyr_source.sh" "$SOURCE"
    "$SCRIPT_DIR/prepare_zephyr_sdk.sh" "$SDK_CURRENT"
    [[ -x "$SDK/bin/aarch64-zephyr-elf-gcc" ]] ||
        die "prepared Zephyr SDK compiler is missing at $SDK"

    if [[ ! -x "$PYTHON_VENV/bin/python" ]]; then
        uv venv --python 3.12 "$PYTHON_VENV"
    fi
    if ! "$PYTHON_VENV/bin/python" -c 'import jsonschema, pykwalify.core, elftools' 2>/dev/null; then
        uv pip install --python "$PYTHON_VENV/bin/python" \
            -r "$SOURCE/scripts/requirements-base.txt"
    fi

    # A tarball source tree is not a west workspace. Seed the module metadata once;
    # CMake reuses these deterministic files on subsequent invocations.
    if [[ ! -f "$BUILD/Kconfig/kconfig_module_dirs.cmake" ]]; then
        mkdir -p "$BUILD/Kconfig"
        ZEPHYR_BASE="$SOURCE" "$PYTHON_VENV/bin/python" "$SOURCE/scripts/zephyr_module.py" \
            -m "$SOURCE" \
            --kconfig-out "$BUILD/Kconfig/Kconfig.modules" \
            --cmake-out "$BUILD/zephyr_modules.txt" \
            --sysbuild-kconfig-out "$BUILD/Kconfig/Kconfig.sysbuild.modules" \
            --sysbuild-cmake-out "$BUILD/sysbuild_modules.txt" \
            --settings-out "$BUILD/zephyr_settings.txt"
    fi

    cmake -S "$APP" -B "$BUILD" -G Ninja \
        -DCMAKE_PREFIX_PATH="$SOURCE/share/zephyr-package/cmake" \
        -DCMAKE_DTS_PREPROCESSOR="$SDK/bin/aarch64-zephyr-elf-gcc" \
        -DZEPHYR_TOOLCHAIN_VARIANT=cross-compile \
        -DTOOLCHAIN_ROOT="$SOURCE" \
        -DSYSROOT_DIR="$SDK/aarch64-zephyr-elf" \
        -DTOOLCHAIN_HOME="$SDK/bin" \
        -DBOARD=qemu_cortex_a53 \
        -DBUILD_VERSION="$ZEPHYR_VERSION" \
        -DDTC_OVERLAY_FILE="$APP/virtnet.overlay" \
        -DEXTRA_CFLAGS='-Did_aa64isar2_el1=S3_0_C0_C6_2' \
        -DPython3_EXECUTABLE="$PYTHON_VENV/bin/python" \
        -DPYTHON_EXECUTABLE="$PYTHON_VENV/bin/python" \
        -DCROSS_COMPILE="$SDK/bin/aarch64-zephyr-elf-"
    unset CMAKE_C_COMPILER
    unset CMAKE_CXX_COMPILER
    unset CMAKE_ASM_COMPILER
    ninja -C "$BUILD" -j "$JOBS"

    artifact_staging="$(mktemp -d "$VERSION_ROOT/.task123-image.XXXXXX")"
    cp -- "$BUILD/zephyr/zephyr.bin" "$artifact_staging/zephyr.bin"
    entry="$(readelf -h "$BUILD/zephyr/zephyr.elf" | awk '/Entry point address:/ {print $NF}')"
    [[ "$entry" =~ ^0x[0-9a-fA-F]+$ ]] || die "unable to read Zephyr entry point"
    python3 - \
        "$artifact_staging/zephyr.bin" "$artifact_staging/zephyr.bin.build-meta.json" "$entry" \
        "$ZEPHYR_VERSION" "$ZEPHYR_COMMIT" "$ZEPHYR_SDK_VERSION" \
        "$BUILD/zephyr/zephyr.elf" <<'PY'
import hashlib
import json
import pathlib
import sys

image, metadata, entry, zephyr, commit, sdk, elf = sys.argv[1:]
payload = pathlib.Path(image).read_bytes()
record = {
    "schema": 1,
    "rtos": "zephyr",
    "image_sha256": hashlib.sha256(payload).hexdigest(),
    "image_size": len(payload),
    "entry_point": int(entry, 16),
    "zephyr_version": zephyr,
    "zephyr_commit": commit,
    "zephyr_sdk_version": sdk,
    "board": "qemu_cortex_a53",
    "virtio_net": True,
    "real_spi_interrupt": True,
}
pathlib.Path(metadata).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
print(f"Zephyr Task123 image: {image} ({len(payload)} bytes, entry={entry}, elf={elf})")
PY
    "$SCRIPT_DIR/zephyr_image_metadata.py" write \
        --image "$artifact_staging/zephyr.bin" \
        --source "$artifact_staging/zephyr.bin.build-meta.json" \
        --output "$artifact_staging/zephyr.bin.meta.json"
    publish_zephyr_generation \
        "$artifact_staging/zephyr.bin" \
        "$artifact_staging/zephyr.bin.meta.json" \
        "$expected_input_digest" "$OUTPUT"
    rm -rf -- "$artifact_staging"
    echo "Zephyr Task123 image published: $OUTPUT/current/zephyr.bin"
}

if [[ "${BASH_SOURCE[0]}" == "$0" &&
      "${ZEPHYR_TASK123_BUILD_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
