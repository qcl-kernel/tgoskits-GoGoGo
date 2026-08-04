#!/usr/bin/env bash
# prebuild.sh - provision the pure-CPU llama.cpp (ggml) inference stack and stage the
# greedy-decode correctness carpet into the per-arch Alpine rootfs.
#
# What the carpet proves: llama.cpp greedy-decoding (temperature=0, pure argmax sampler,
# n_gpu_layers=0) qwen3-0.6b.gguf must produce the EXACT SAME token IDs on StarryOS as the
# committed golden reference (generated on a host CPU with the same pinned llama.cpp source).
# Greedy decode is deterministic, so the golden is reproducible; any divergence is a ggml CPU
# kernel numerical bug. No GPU is involved - this is the C-side (ggml CPU backend only).
#
# Provisioning model: llama.cpp is cross-compiled FROM SOURCE for the target arch entirely on
# the HOST with a musl-cross toolchain (${triple}-gcc/${triple}-g++), driven by a generated
# CMake toolchain file (CMAKE_SYSTEM_NAME=Linux + the cross C/C++ compilers). The earlier
# approach ran the target Alpine gcc/cmake under qemu-user; that fails because gcc spawns
# cc1/cc1plus via posix_spawn, which qemu-user cannot exec. Cross-compiling natively on the
# host avoids qemu-user entirely and builds the SAME CPU-only ggml source, so the golden stays
# byte-reproducible on-target. The carpet (infer_llamacpp.cpp) is compiled with the same
# ${triple}-g++ against the freshly built libllama. libllama/libggml plus the toolchain's
# libstdc++/libgcc_s runtime are staged into the overlay next to the binary; the base Alpine
# rootfs already provides ld-musl + libc. The models, golden token files, and run_all.sh are
# staged too. A capability manifest lists provisioned cells; run_all.sh gates on it
# (fail==0 && total==EXPECTED==pass, EXPECTED == number of model cells).
#
# llama.cpp is pinned to commit LLAMA_CPP_COMMIT below (the same source the host golden was
# generated with) so the target runs byte-identical inference code -> the golden is exactly
# reproducible on-target.
#
# Env from the app runner: STARRY_ARCH, STARRY_ROOTFS, STARRY_STAGING_ROOT, STARRY_OVERLAY_DIR,
# STARRY_APP_DIR.
set -euo pipefail

app_dir="${STARRY_APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
arch="${STARRY_ARCH:?prebuild: STARRY_ARCH required}"
base_rootfs="${STARRY_ROOTFS:?prebuild: STARRY_ROOTFS required}"
staging_root="${STARRY_STAGING_ROOT:?prebuild: STARRY_STAGING_ROOT required}"
overlay_dir="${STARRY_OVERLAY_DIR:?prebuild: STARRY_OVERLAY_DIR required}"

CARPET="$app_dir/programs/carpets/infer_llamacpp"
GOLDEN_DIR="$CARPET/golden"

# Pinned llama.cpp source (must match the source the committed golden was generated with).
LLAMA_CPP_COMMIT="c92e806d1c81091c9035edce99c35374da1b465e"
LLAMA_CPP_TARBALL_URL="https://github.com/ggml-org/llama.cpp/archive/${LLAMA_CPP_COMMIT}.tar.gz"
# Models: both GGUFs greedy-decoded token-by-token against golden. Provided by the app runner
# (staged into the app dir models/ by the parent / a pre-step) or fetched. sha256 pinned for
# reproducibility. Each MODELS entry is "name|sha256|url".
MODELS=(
    "qwen3-0.6b.gguf|9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031|https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf"
    "deepseek-r1-distill-qwen-1.5b.gguf|1741e5b2d062b07acf048bf0d2c514dadf2a48f94e2b4aa0cfe069af3838ee2f|https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
)
# Cells: "cell|model-file|golden-glob" - one greedy-decode run per model.
CELLS=(
    "infer_llamacpp_qwen3|qwen3-0.6b.gguf|qwen3-0.6b.*.tokens"
    "infer_llamacpp_deepseek|deepseek-r1-distill-qwen-1.5b.gguf|deepseek-r1-distill-qwen-1.5b.*.tokens"
)

# Host musl-cross toolchain for the target arch. Resolves ${triple}-gcc/${triple}-g++ on PATH
# first, then the /opt/${triple}-cross install used by the sibling carpets. GCC (not zig) is
# used here because we build llama.cpp from source with this exact compiler: there is no Alpine
# prebuilt libstdc++ .so to link against (which would trip the musl-cross binutils .relr.dyn
# issue), so the plain musl-cross g++ is both correct and consistent for building the libs and
# the carpet.
case "$arch" in
    x86_64)      triple=x86_64-linux-musl ;;
    aarch64)     triple=aarch64-linux-musl ;;
    riscv64)     triple=riscv64-linux-musl ;;
    loongarch64) triple=loongarch64-linux-musl ;;
    *) echo "prebuild: unsupported arch: $arch" >&2; exit 1 ;;
esac

CROSS_CC=""; CROSS_CXX=""; CROSS_SYSROOT=""
# Resolve a COMPLETE C++ musl-cross toolchain: gcc and g++ MUST come from the same install (a
# bare ${triple}-gcc on PATH may be a C-only musl-gcc with no matching g++ and no libstdc++).
# Locate g++ first, then take gcc from the same bindir.
resolve_toolchain() {
    local gxx="" bindir
    for cand in \
        "/opt/${triple}-cross/bin/${triple}-g++" \
        "/opt/${triple}-musl-cross/bin/${triple}-g++" \
        "/usr/local/${triple}-cross/bin/${triple}-g++"; do
        [[ -x "$cand" ]] && { gxx="$cand"; break; }
    done
    if [[ -z "$gxx" ]]; then
        gxx="$(command -v "${triple}-g++" 2>/dev/null || true)"
    fi
    [[ -n "$gxx" ]] || { echo "prebuild: no complete ${triple}-g++ toolchain on host" >&2; exit 3; }
    CROSS_CXX="$gxx"
    bindir="$(dirname "$gxx")"
    CROSS_CC="$bindir/${triple}-gcc"
    [[ -x "$CROSS_CC" ]] || { echo "prebuild: ${triple}-gcc missing next to $gxx" >&2; exit 3; }
    # The toolchain sysroot (holds libstdc++.so.6 / libgcc_s.so.1 / libc.so for the target).
    CROSS_SYSROOT="$("$CROSS_CC" -print-sysroot 2>/dev/null || true)"
    [[ -n "$CROSS_SYSROOT" && -d "$CROSS_SYSROOT" ]] \
        || CROSS_SYSROOT="$(dirname "$bindir")/${triple}"
    echo "prebuild: cross CC=$CROSS_CC CXX=$CROSS_CXX sysroot=$CROSS_SYSROOT"
}

ensure_host_tools() {
    local missing=()
    command -v debugfs >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v resize2fs >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v cmake >/dev/null 2>&1 || missing+=(cmake)
    if [[ ${#missing[@]} -gt 0 ]]; then
        command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y --no-install-recommends "${missing[@]}" \
            || { echo "prebuild: missing host tools: ${missing[*]}" >&2; exit 1; }
    fi
}

# Two GGUFs (qwen3-0.6b ~600 MiB + deepseek-r1-distill-qwen-1.5b ~1.1 GiB = ~1.7 GiB). Grow the
# shared Alpine rootfs image so the overlay (both models + libs + carpet) fits. NOTE: this grows
# the shared per-arch rootfs image in place (same approach as the render carpets); a per-app
# rootfs would be cleaner and is flagged for follow-up.
ROOTFS_SIZE=8G
grow_rootfs() {
    [[ -f "$base_rootfs" ]] || { echo "prebuild: rootfs image missing: $base_rootfs" >&2; exit 2; }
    local before after; before=$(stat -c %s "$base_rootfs")
    truncate -s "$ROOTFS_SIZE" "$base_rootfs"
    e2fsck -f -y "$base_rootfs" >/dev/null 2>&1 || true
    resize2fs "$base_rootfs" >/dev/null 2>&1
    after=$(stat -c %s "$base_rootfs")
    echo "prebuild: rootfs grown $((before/1024/1024)) -> $((after/1024/1024)) MiB for model + llama.cpp closure"
}

fetch_llama_src() {
    local src="$staging_root/build/llama.cpp"
    mkdir -p "$staging_root/build"
    if [[ ! -f "$src/CMakeLists.txt" ]]; then
        # Prefer a source tree the parent staged next to the app (offline / reproducible), else fetch.
        if [[ -d "$app_dir/vendor/llama.cpp" && -f "$app_dir/vendor/llama.cpp/CMakeLists.txt" ]]; then
            echo "prebuild: using vendored llama.cpp source ($app_dir/vendor/llama.cpp)"
            cp -a "$app_dir/vendor/llama.cpp" "$src"
        else
            echo "prebuild: fetching pinned llama.cpp source ${LLAMA_CPP_COMMIT}"
            curl -fsSL "$LLAMA_CPP_TARBALL_URL" -o "$staging_root/build/llama.tar.gz"
            tar -xzf "$staging_root/build/llama.tar.gz" -C "$staging_root/build"
            mv "$staging_root/build/llama.cpp-${LLAMA_CPP_COMMIT}" "$src"
        fi
    fi
    echo "$src"
}

# Emit a CMake toolchain file selecting the host musl-cross C/C++ compilers for the target.
# CMAKE_SYSTEM_NAME=Linux marks this a cross build; FIND_ROOT_PATH modes keep library/header
# lookups inside the target sysroot while still finding host build programs (cmake, ninja).
write_cmake_toolchain() {
    local tc="$1"
    cat > "$tc" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${arch})
set(CMAKE_C_COMPILER "${CROSS_CC}")
set(CMAKE_CXX_COMPILER "${CROSS_CXX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
}

# Cross-compile llama.cpp CPU-only (dynamic musl) on the host. GGML_NATIVE=OFF keeps the ISA
# baseline portable; no CUDA/Vulkan/Metal/OpenCL backend is built; the ggml CPU backend
# (libggml-cpu) is the only compute backend, which is exactly what we want to validate. Only the
# libraries are needed (the carpet links libllama directly).
build_llama_cpp() {
    local src; src="$(fetch_llama_src)"
    local bld="$src/build-starry"
    local tc="$staging_root/build/toolchain-${arch}.cmake"
    write_cmake_toolchain "$tc"
    echo "prebuild: cmake-configure llama.cpp (CPU-only, dynamic musl) for $arch (host cross)"
    cmake -S "$src" -B "$bld" \
        -DCMAKE_TOOLCHAIN_FILE="$tc" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=OFF \
        -DGGML_CPU=ON \
        -DGGML_OPENMP=OFF \
        -DGGML_BLAS=OFF \
        -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF -DGGML_OPENCL=OFF \
        -DLLAMA_CURL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
        >/dev/null
    echo "prebuild: build libllama + libggml (host cross-compile)"
    cmake --build "$bld" --target llama --config Release -- -j"$(nproc)" >/dev/null
    # collect the produced shared libs
    local libs; libs="$(find "$bld" -name 'libllama.so*' -o -name 'libggml*.so*' 2>/dev/null)"
    [[ -n "$libs" ]] || { echo "prebuild: llama.cpp build produced no shared libs for $arch" >&2; exit 4; }
    echo "$src"
}

# Cross-compile the carpet against the freshly built libllama, dynamic musl. -rpath-link lets the
# link-time resolver find the transitive libggml deps in the build tree; -rpath points at the
# on-target install dir.
compile_carpet() {
    local src="$1" bin="$2"
    local bld="$src/build-starry"
    local llama_lib_dir; llama_lib_dir="$(dirname "$(find "$bld" -name 'libllama.so*' | head -1)")"
    echo "prebuild: cross-compile infer_llamacpp carpet for $arch (host $CROSS_CXX)"
    "$CROSS_CXX" -O2 -std=c++17 \
        -I "$src/include" -I "$src/ggml/include" \
        "$CARPET/src/infer_llamacpp.cpp" \
        -L "$llama_lib_dir" -lllama -lggml -lggml-base \
        -Wl,-rpath,/opt/cpu-unknow-infer/lib -Wl,-rpath-link,"$llama_lib_dir" \
        -o "$bin/infer_llamacpp"
    [[ -x "$bin/infer_llamacpp" ]] || { echo "prebuild: carpet failed to compile for $arch" >&2; exit 5; }
    # stage the shared libs next to the binary
    mkdir -p "$bin/lib"
    find "$bld" \( -name 'libllama.so*' -o -name 'libggml*.so*' \) -exec cp -a {} "$bin/lib/" \;
    # stage the toolchain C++ runtime the dynamic binary/libs need (base Alpine rootfs has ld-musl
    # + libc, but not the musl-cross libstdc++/libgcc_s the g++-built code was linked against).
    # Ship only the versioned runtime .so (the SONAME the loader resolves), not the -gdb.py helper
    # or the unversioned dev symlink.
    cp -a "$CROSS_SYSROOT/lib/libstdc++.so.6"* "$bin/lib/" 2>/dev/null || true
    cp -a "$CROSS_SYSROOT/lib/libgcc_s.so.1"*  "$bin/lib/" 2>/dev/null || true
    rm -f "$bin/lib"/*-gdb.py 2>/dev/null || true
}

# Stage one model by name|sha256|url, verifying the pinned sha256. Reuses a local copy if present.
provision_model() {
    local bin="$1" name="$2" sha="$3" url="$4"
    local model_src=""
    for cand in "$app_dir/models/$name" "$app_dir/../../../gpu-infer/models/$name" "/home/heke/rcore/gpu-infer/models/$name"; do
        [[ -f "$cand" ]] && { model_src="$cand"; break; }
    done
    if [[ -z "$model_src" ]]; then
        echo "prebuild: fetching model $name"
        curl -fsSL "$url" -o "$bin/$name"
        model_src="$bin/$name"
    fi
    local got; got="$(sha256sum "$model_src" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
        echo "prebuild: model $name sha256 mismatch (got $got want $sha)" >&2; exit 6
    fi
    [[ "$model_src" == "$bin/$name" ]] || cp "$model_src" "$bin/$name"
    echo "prebuild: staged $name ($(stat -c %s "$bin/$name") bytes, sha256 ok)"
}

compile_carpets() {
    local bin="$staging_root/opt/cpu-unknow-infer"; mkdir -p "$bin/golden"
    local src; src="$(build_llama_cpp)"
    compile_carpet "$src" "$bin"
    local entry name sha url
    for entry in "${MODELS[@]}"; do
        IFS='|' read -r name sha url <<< "$entry"
        provision_model "$bin" "$name" "$sha" "$url"
    done
    cp "$GOLDEN_DIR"/*.tokens "$bin/golden/"
    cp "$app_dir/programs/run_all.sh" "$bin/run_all.sh"; chmod +x "$bin/run_all.sh"
}

populate_overlay() {
    local bin="$staging_root/opt/cpu-unknow-infer"
    # Capability manifest: one "cell|model|golden-glob" line per model cell that is actually
    # provisioned (carpet binary + model present + at least one matching golden). run_all.sh gates
    # on this set. Both Qwen3 and DeepSeek cells are provisioned when their models are staged.
    : > "$bin/expected_cells"
    if [[ -x "$bin/infer_llamacpp" ]]; then
        local entry cell model glob
        for entry in "${CELLS[@]}"; do
            IFS='|' read -r cell model glob <<< "$entry"
            if [[ -f "$bin/$model" ]] && ls "$bin"/golden/$glob >/dev/null 2>&1; then
                echo "$cell|$model|$glob" >> "$bin/expected_cells"
            else
                echo "prebuild: WARN cell $cell not provisioned (model or golden missing) - excluded from manifest"
            fi
        done
    fi
    echo "prebuild: expected_cells for $arch = $(cut -d'|' -f1 "$bin/expected_cells" | tr '\n' ' ')"
    mkdir -p "$overlay_dir/opt" "$overlay_dir/usr/bin" "$overlay_dir/usr/lib"
    cp -a "$staging_root/opt/cpu-unknow-infer" "$overlay_dir/opt/"
    # The C++ runtime (libstdc++/libgcc_s) is shipped in /opt/cpu-unknow-infer/lib (on the rpath
    # and LD_LIBRARY_PATH); also mirror it into /usr/lib for any incidental lookup.
    cp -a "$bin/lib/libstdc++.so.6"* "$overlay_dir/usr/lib/" 2>/dev/null || true
    cp -a "$bin/lib/libgcc_s.so.1"*  "$overlay_dir/usr/lib/" 2>/dev/null || true
    ln -sf /opt/cpu-unknow-infer/run_all.sh "$overlay_dir/usr/bin/run_all.sh"
    echo "prebuild: overlay populated for $arch"
}

resolve_toolchain
ensure_host_tools
grow_rootfs
compile_carpets
populate_overlay
echo "prebuild: cpu-unknow-infer overlay ready for $arch"
