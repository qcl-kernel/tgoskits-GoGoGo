# cpu-opengl-compute

Per-binding desktop-OpenGL compute carpet on StarryOS. OpenGL runs as a CPU software implementation:
Mesa llvmpipe provides a real GL 4.5 core context whose GL 4.3 compute pipeline (`glDispatchCompute`)
executes on the LLVM CPU JIT, so no host GPU is required. The on-target StarryOS gate builds and runs
the surfaceless-EGL desktop-GL C carpet (`opengl_c_egl`), the C++ carpet (`opengl_cpp`, reworked from
OSMesa to the same surfaceless-EGL path) and the glow (Rust) cell (`opengl_rust`, dynamic musl); the
moderngl (Python) cell (`opengl_moderngl`, provisioned best-effort where it resolves); the OSMesa-only
C carpet (`opengl_c`) and the PyOpenGL cell are exercised in the host reference layer pending their
on-target runtimes. Each cell enumerates the compute-relevant GL
API surface against the real `GL/gl.h` / `GL/glcorearb.h` headers (or the binding's documented API),
dispatches GLSL 430 compute shaders and checks every result element against a numpy or closed-form
reference, and drives the error paths against real `GL_INVALID_*` enums. A cell prints `<name> OK <n>`
only when its failure count is zero and the assertion total equals a pinned `EXPECTED` constant.

## Cells and assertions

| Cell | Binding | Context | Assertions | Runs |
|:--|:--|:--|--:|:--|
| `opengl_c_egl` | GL C API + `eglGetProcAddress` loader | EGL surfaceless | 88 | on-target (all arches) + host |
| `opengl_c` | GL C API + `OSMesaGetProcAddress` loader | OSMesa off-screen | 78 | host reference |
| `opengl_cpp` | GL C++ + DSA (`glMapNamedBufferRange`, program-uniform) | EGL surfaceless | 127 | on-target (all arches) + host |
| `opengl_py` | PyOpenGL + numpy | OSMesa off-screen | 90 | host reference |
| `opengl_moderngl` | moderngl + numpy | standalone (llvmpipe) | 48 | on-target where moderngl resolves (x64/aa apk; rv/la sdist follow-up) + host |
| `opengl_rust` | glow + khronos-egl (dynamic musl) | EGL surfaceless | 78 | on-target (all arches) + host |

Total: 501 assertions.

Each cell covers the compute API end to end: surfaceless / off-screen context creation
(OSMesa / EGL) - make-current - GL version/renderer introspection - compute work-group limit queries -
GLSL 430 compute-shader compile (plus a compile-error path asserting `GL_COMPILE_STATUS == GL_FALSE`
with a non-empty info log) - program link (plus a link-error path) - SSBO create / `glBufferData` /
`glBufferStorage` / `glBindBufferBase` / `glBindBufferRange` - uniform set + read-back -
`glDispatchCompute` + `glMemoryBarrier` - `glDispatchComputeIndirect` - fence sync
(`glFenceSync` / `glClientWaitSync` / `glGetSynciv`) - timer query (`GL_TIME_ELAPSED` /
`glQueryCounter`) - map read / map write + explicit flush - `glGetBufferSubData` readback -
`glCopyBufferSubData` / `glClearBufferData` - program-resource reflection
(`glGetProgramResourceIndex` / `glGetProgramInterfaceiv` / `glGetProgramResourceiv` /
`glGetProgramResourceName`). The operators (vector-add, saxpy including `alpha=0`, element-multiply and
a shared-memory tree reduction) are dispatched as real GLSL compute shaders and every output element is
compared to the closed-form / numpy reference with a relative tolerance. Boundary cases (zero-size
dispatch left as a no-op, a non-divisible tail guard, oversubscription with an `i>=n` guard, and a
`1<<20`-element grid verified element-wise) and error paths are asserted directly against the real GL
enum (`GL_INVALID_VALUE` / `GL_INVALID_OPERATION` / `GL_INVALID_ENUM`), and each operator carries a
negative control proving the checker rejects a wrong reference.

## Backend and runtime

Provisioned from Alpine edge (main + community) as musl packages: `mesa-gl` (libGL), `mesa-egl`
(libEGL), `mesa-gles` and `mesa-dri-gallium` (the llvmpipe gallium DRI driver), plus the `llvm-libs`
closure llvmpipe links against. Alpine edge builds these for all four target architectures (x86_64,
aarch64, riscv64, loongarch64), so the surfaceless-EGL desktop-GL carpet runs on-target on every arch.
`prebuild.sh` cross-compiles `opengl_c_egl` against the provisioned musl headers/libraries under
qemu-user (the GL/glcorearb.h, EGL and KHR headers are vendored under `programs/headers`, since
Alpine's `mesa-dev` is the only package carrying `glcorearb.h` and it pulls a large clang closure the
runtime does not need), and stages the binary plus the mesa closure into the per-arch rootfs.
`programs/run_all.sh` runs the native carpet and prints `TEST PASSED` when it reports `OK` and none
fails.

Runtime environment on target:

- `EGL_PLATFORM=surfaceless` creates a desktop-GL 4.3 context with no window-system surface.
- `LIBGL_ALWAYS_SOFTWARE=1` + `GALLIUM_DRIVER=llvmpipe` pin the gallium DRI driver to the llvmpipe CPU
  software rasterizer.
- `XDG_RUNTIME_DIR` points at a writable directory.
- `LP_NUM_THREADS=1` pins the mesa thread pool to one thread, matching StarryOS's single vCPU.

## Host reference layer

`opengl_rust` (glow + khronos-egl) now builds and runs on-target on every arch: it is cross-compiled
to a **dynamic** musl binary (`-C target-feature=-crt-static`) and khronos-egl's `dynamic` feature
dlopen()s the provisioned `libEGL` at runtime, requesting a GL 4.5 core context over EGL-surfaceless
and driving the compute lifecycle through glow's safe wrappers - the same surfaceless-EGL path as
`opengl_c_egl`. On the host it runs against the same Mesa llvmpipe driver for cross-checking.

The matrix's C++ desktop-GL compute binding is now satisfied on-target: `opengl_cpp` was reworked from
OSMesa to the same surfaceless-EGL path as `opengl_c_egl` (GL 1.x from libGL, GL 4.3 via
`eglGetProcAddress`), so it builds and runs on-target on every arch (127 assertions).

The remaining cells are host-reference for now:
- `opengl_c` is the OSMesa-only C variant; Alpine ships no `mesa-osmesa` on any arch, so it cannot be
  built on-target and stays host-reference (the surfaceless-EGL path is covered by `opengl_c_egl` /
  `opengl_cpp`).
- `opengl_moderngl` (moderngl standalone headless-EGL context) is provisioned on-target best-effort:
  `apk add py3-moderngl` + python3 + numpy, wired (appended to the manifest) on every arch where the
  moderngl native extension resolves - Alpine builds it for x86_64/aarch64; rv/la may need an sdist
  build (a follow-up), in which case it is honestly omitted from that arch's manifest. This satisfies
  the matrix's Python desktop-GL compute binding on-target.
- `opengl_py` (PyOpenGL) binds the GL 4.3 compute API through the OSMesa loader; making it on-target
  needs a PyOpenGL EGL rework (like `opengl_cpp`), a follow-up - it stays host-reference for now. The
  desktop-GL compute path it exercises is covered on-target by `opengl_c_egl` / `opengl_cpp` /
  `opengl_rust` / `opengl_moderngl`.

## Single-core execution

StarryOS runs on one vCPU (SMP is off by default), so llvmpipe's LLVM JIT executes every workgroup on a
single thread. `run_all.sh` pins the mesa thread pool with `LP_NUM_THREADS=1` and prints the detected
CPU count, so the single-core reality is explicit in the output. The carpets assert numerical
correctness and API ordering semantics, not throughput; the results are independent of thread count.

## Run

```
cargo xtask starry app qemu -t cpu-opengl-compute --arch x86_64
cargo xtask starry app qemu -t cpu-opengl-compute --arch aarch64
cargo xtask starry app qemu -t cpu-opengl-compute --arch riscv64
cargo xtask starry app qemu -t cpu-opengl-compute --arch loongarch64
```
