# QEMU Linux/RT-Thread AI Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible dual-QEMU demonstration where a Linux guest classifies a Y4M line-following video with an int8 CNN, sends the inference through RT-IPC/UDP, and an RT-Thread guest applies and reports a measurable virtual steering action.

**Architecture:** Host-side NumPy tools generate a deterministic model and test video. A static Linux C application performs inference, exchanges versioned control/status payloads over the existing RT-IPC C engine, and emits machine-readable per-frame results; an RT-Thread application owns the idempotent controller and virtual actuator. Two QEMU `virt` machines share an unprivileged multicast socket LAN, while host scripts build images, orchestrate runs, inject deterministic failures, and derive reports only from captured data.

**Tech Stack:** C11, Python 3 with NumPy, RT-IPC C, RT-Thread 5.2.2 with lwIP, Buildroot 2025.02.1, QEMU AArch64 `virt`, POSIX shell, Make.

---

## File Map

- `.gitignore`: excludes fetched sources, toolchains, generated model/video, images, and run output.
- `Makefile`: stable user entry points (`doctor`, `model`, `test`, `images`, `demo`, `fault-test`, `report`).
- `configs/dependencies.lock`: upstream tags/commits, toolchain URL/checksum, and RT-IPC source checksums.
- `configs/buildroot_defconfig`, `configs/linux.config`: fixed Linux image configuration.
- `configs/rtthread.config`: exact RT-Thread Kconfig values applied to the upstream BSP.
- `scripts/common.sh`: path resolution, logging, checksums, and process cleanup helpers.
- `scripts/doctor.sh`, `scripts/fetch_sources.sh`: environment validation and pinned dependency retrieval.
- `scripts/build_linux.sh`, `scripts/build_rtthread.sh`: reproducible image builds.
- `scripts/run_demo.sh`, `scripts/run_faults.sh`: dual-QEMU orchestration and deterministic failure runs.
- `scripts/summarize.py`, `scripts/render_report.py`: CSV validation, JSON metrics, and Chinese Markdown report generation.
- `model/dataset.py`, `model/train.py`, `model/generate_video.py`, `model/quantize.py`: deterministic data, training, int8 export, and Y4M generation.
- `src/common/task3_protocol.[ch]`: explicit network-order task-three payload codecs.
- `src/common/controller.[ch]`: RTOS-independent controller, actuator, reset, and frame-id idempotency.
- `src/common/session.[ch]`: platform-neutral RT-IPC action pumping and application transaction state.
- `src/linux/y4m.[ch]`, `src/linux/cnn.[ch]`: strict Y4M reader and int8 CNN runtime.
- `src/linux/metrics.[ch]`, `src/linux/rtipc_client.[ch]`, `src/linux/main.c`: Linux socket adapter, experiment loop, CSV, and summary markers.
- `src/rtthread/task3_server.c`, `src/rtthread/SConscript`: lwIP socket server and RT-Thread startup integration.
- `buildroot/`: BR2 external tree that installs the Linux application, video, truth CSV, and init script.
- `tests/`: host unit tests, protocol loopback tests, model equivalence runner, shell contract tests, and result fixtures.
- `README.md`, `docs/protocol.md`, `docs/results/task3-report.md`: reproducibility, topology/protocol, and generated result report.

### Task 1: Repository Scaffold and Dependency Lock

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `configs/dependencies.lock`
- Create: `scripts/common.sh`
- Create: `scripts/doctor.sh`
- Create: `tests/test_doctor.sh`

- [ ] **Step 1: Write the failing doctor contract**

```sh
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
output=$(TASK3_ROOT="$root" "$root/scripts/doctor.sh" --print-only)
printf '%s\n' "$output" | grep -F 'qemu-system-aarch64='
printf '%s\n' "$output" | grep -F 'aarch64-none-elf-gcc='
printf '%s\n' "$output" | grep -F 'numpy='
printf '%s\n' "$output" | grep -F 'rt_ipc.h=verified'
printf '%s\n' "$output" | grep -F 'rt_ipc.c=verified'
```

- [ ] **Step 2: Run the test and confirm the missing script failure**

Run: `sh tests/test_doctor.sh`

Expected: FAIL with `scripts/doctor.sh: not found`.

- [ ] **Step 3: Add locked dependencies and strict path helpers**

`configs/dependencies.lock` must contain these exact upstream identities and current shared protocol hashes:

```sh
RTTHREAD_TAG=v5.2.2
RTTHREAD_COMMIT=ddf52e2cdd977f14fc04035c88672ac204aec713
BUILDROOT_TAG=2025.02.1
BUILDROOT_COMMIT=3815d578c5759fa824322ea3d95ad51b55ab888e
ARM_TOOLCHAIN_VERSION=14.2.rel1
ARM_TOOLCHAIN_URL=https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-elf.tar.xz
ARM_TOOLCHAIN_SHA256=eb54c4727440d03199a6af9a6d021e77f45410cad39effce4e5a1c10a88b7f04
RTIPC_HEADER_SHA256=5e45d6d2ed432b635d4579a0ec011aa29acf6a27ff6e119e290cfc463531513e
RTIPC_SOURCE_SHA256=0b38c5612d92b43c6b6244ff0d08e745acdcba046fead9824bdb58fce034b747
```

Implement `common.sh` with `TASK3_ROOT`, `BUILD_DIR`, `RTIPC_DIR`, `die()`, `require_command()`, and `verify_sha256()`. Implement `doctor.sh --print-only` so it prints resolved tools and validates Python can import NumPy plus both RT-IPC hashes. The normal mode must fail if QEMU is older than 8.2, multicast socket backend is absent, or a host-side prerequisite is unavailable. If `aarch64-none-elf-gcc` is not yet installed, report `aarch64-none-elf-gcc=managed-download` and verify `curl`, `tar`, and `xz` are present so `make images` can fetch the locked toolchain.

- [ ] **Step 4: Add Make targets and ignored output**

The initial `Makefile` must expose commands without doing hidden downloads:

```make
.PHONY: doctor model test images demo fault-test report
doctor:
	./scripts/doctor.sh
model:
	./scripts/build_model.sh
test:
	$(MAKE) -C tests test
images:
	./scripts/build_linux.sh
	./scripts/build_rtthread.sh
demo:
	./scripts/run_demo.sh
fault-test:
	./scripts/run_faults.sh
report:
	./scripts/render_report.py --latest
```

Ignore `/build/`, Python caches, editor files, and generated reports under `docs/results/generated/`, while retaining the checked real report at `docs/results/task3-report.md`.

- [ ] **Step 5: Run the contract and repository checks**

Run: `sh tests/test_doctor.sh && git diff --check`

Expected: PASS and no whitespace errors.

- [ ] **Step 6: Commit the scaffold**

```bash
git add .gitignore Makefile configs/dependencies.lock scripts/common.sh scripts/doctor.sh tests/test_doctor.sh
git commit -m "build: add task3 dependency and environment checks"
```

### Task 2: Versioned Task-Three Payload Codec

**Files:**
- Create: `src/common/task3_protocol.h`
- Create: `src/common/task3_protocol.c`
- Create: `tests/test_task3_protocol.c`
- Create: `tests/Makefile`

- [ ] **Step 1: Write codec tests from fixed wire vectors**

Define tests that encode a STEP command with `frame_id=0x01020304`, `confidence=0x1234`, and `tx_ns=0x0102030405060708`, then assert exact bytes at every offset. Add decode failures for 23-byte commands, schema 2, unknown command/mode/class, nonzero reserved fields, and signed PWM/position round trips. The golden prefix must be:

```c
static const uint8_t expected[24] = {
    1, TASK3_CMD_STEP, TASK3_MODE_AI, TASK3_CLASS_LEFT,
    0x12, 0x34, 0, 0, 0x01, 0x02, 0x03, 0x04,
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0, 0, 0, 0,
};
```

- [ ] **Step 2: Run the focused test and verify the missing API failure**

Run: `make -C tests test_task3_protocol`

Expected: compilation FAIL because `task3_protocol.h` does not exist.

- [ ] **Step 3: Implement explicit network-order codecs**

Define enums for command, mode, class, status, and application errors; typed host-side structures; constants `TASK3_CTRL_WIRE_SIZE=24`, `TASK3_STATUS_WIRE_SIZE=24`, and `TASK3_ERROR_WIRE_SIZE=12`; and functions:

```c
int task3_encode_control(const task3_control_t *value, uint8_t out[24]);
int task3_decode_control(const uint8_t *wire, size_t len, task3_control_t *out);
int task3_encode_status(const task3_status_t *value, uint8_t out[24]);
int task3_decode_status(const uint8_t *wire, size_t len, task3_status_t *out);
int task3_encode_error(const task3_error_t *value, uint8_t out[12]);
int task3_decode_error(const uint8_t *wire, size_t len, task3_error_t *out);
```

Use local `read_be16/32/64` and `write_be16/32/64`; never cast the wire buffer to a structure. Decode into a temporary and assign `*out` only after all validation passes.

- [ ] **Step 4: Run codec tests with sanitizers**

Run: `make -C tests test_task3_protocol SANITIZE=1`

Expected: all codec cases PASS under AddressSanitizer and UndefinedBehaviorSanitizer.

- [ ] **Step 5: Commit the wire protocol**

```bash
git add src/common/task3_protocol.h src/common/task3_protocol.c tests/test_task3_protocol.c tests/Makefile
git commit -m "feat(protocol): add task3 control payload codec"
```

### Task 3: Idempotent Controller and Virtual Actuator

**Files:**
- Create: `src/common/controller.h`
- Create: `src/common/controller.c`
- Create: `tests/test_controller.c`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write controller state-transition tests**

Cover RESET, fixed-mode STEP, AI LEFT/CENTER/RIGHT mapping, PWM saturation, position saturation, invalid UNKNOWN class, and duplicate `frame_id`. The duplicate case must retain byte-for-byte equivalent status and leave `applied_steps` unchanged:

```c
task3_controller_t controller;
task3_controller_init(&controller);
task3_control_t step = {
    .command = TASK3_CMD_STEP,
    .mode = TASK3_MODE_AI,
    .klass = TASK3_CLASS_RIGHT,
    .confidence_q15 = 30000,
    .frame_id = 7,
};
task3_status_t first;
ASSERT_EQ(TASK3_APP_OK, task3_controller_apply(&controller, &step, &first));
uint64_t applied = controller.applied_steps;
task3_status_t duplicate;
ASSERT_EQ(TASK3_APP_OK, task3_controller_apply(&controller, &step, &duplicate));
ASSERT_EQ(applied, controller.applied_steps);
ASSERT_TRUE(duplicate.flags & TASK3_STATUS_FLAG_DUPLICATE);
ASSERT_EQ(first.actuator_q15, duplicate.actuator_q15);
```

- [ ] **Step 2: Verify the controller test fails to compile**

Run: `make -C tests test_controller`

Expected: compilation FAIL because `controller.h` is absent.

- [ ] **Step 3: Implement the deterministic controller**

Expose `task3_controller_init`, `task3_controller_reset`, and `task3_controller_apply(task3_controller_t *, const task3_control_t *, task3_status_t *)`. Use targets `-20000/0/20000`, proportional gain `PWM=(target-position)/16` clamped to `[-1000,1000]`, and actuator update `position += PWM*4` clamped to signed Q15. Cache the last successful STEP status. RESET clears position, counters, and the cache; STOP returns a status without advancing the plant. Invalid commands return a `task3_app_error_code_t` without mutation.

- [ ] **Step 4: Run unit tests and sanitizer suite**

Run: `make -C tests test_controller SANITIZE=1 && make -C tests test`

Expected: controller tests and all earlier tests PASS.

- [ ] **Step 5: Commit the controller**

```bash
git add src/common/controller.h src/common/controller.c tests/test_controller.c tests/Makefile
git commit -m "feat(control): add idempotent virtual steering controller"
```

### Task 4: Deterministic Y4M Dataset and Strict Reader

**Files:**
- Create: `model/dataset.py`
- Create: `model/generate_video.py`
- Create: `src/linux/y4m.h`
- Create: `src/linux/y4m.c`
- Create: `tests/test_dataset.py`
- Create: `tests/test_y4m.c`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write deterministic dataset tests**

Assert two calls with seed 3103 produce identical pixels/labels, training seed 1201 differs from test seed 3103, every image is `uint8[32,32]`, all three classes occur, and Y4M output has 600 `FRAME\n` markers plus a 600-row truth CSV. Assert target Q15 stays within `[-20000,20000]`.

- [ ] **Step 2: Write malformed Y4M reader tests**

Use temporary files for a valid `YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n` stream, wrong dimensions, `C420`, a missing frame marker, and a truncated 1024-byte plane. Assert valid frames return frame ids 0 and 1 and malformed inputs return distinct enum errors.

- [ ] **Step 3: Run both focused tests and verify failures**

Run: `python3 -m unittest tests.test_dataset -v && make -C tests test_y4m`

Expected: Python import failure for `model.dataset` and C compile failure for `y4m.h`.

- [ ] **Step 4: Implement renderer, video writer, and reader**

`render_frame(offset, rng)` must draw a vertically oriented line with width, illumination, Gaussian sensor noise, and bounded rectangular occlusion variations. Class thresholds are target Q15 below `-6000`, between `-6000` and `6000`, and above `6000`. `generate_video.py --frames 600 --seed 3103 --fps 10 --output build/model/line-follow.y4m --truth build/model/truth.csv` writes Cmono Y4M and CSV atomically.

The C reader stores width, height, fps numerator/denominator, frame index, and `FILE *`; it accepts only the exact supported geometry and chroma, consumes optional per-frame tags safely, and distinguishes clean EOF from truncation.

- [ ] **Step 5: Run deterministic and sanitizer tests**

Run: `python3 -m unittest tests.test_dataset -v && make -C tests test_y4m SANITIZE=1`

Expected: all cases PASS.

- [ ] **Step 6: Commit video generation and parsing**

```bash
git add model/dataset.py model/generate_video.py src/linux/y4m.h src/linux/y4m.c tests/test_dataset.py tests/test_y4m.c tests/Makefile
git commit -m "feat(video): add deterministic Y4M line input"
```

### Task 5: NumPy Training, Quantization, and C CNN Inference

**Files:**
- Create: `model/network.py`
- Create: `model/train.py`
- Create: `model/quantize.py`
- Create: `src/linux/cnn.h`
- Create: `src/linux/cnn.c`
- Create: `tests/cnn_runner.c`
- Create: `tests/test_model.py`
- Create: `scripts/build_model.sh`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write model quality and export tests**

Train in a temporary output directory and assert float accuracy `>=0.97`, quantized reference accuracy `>=0.95`, a generated `model_weights.h` contains all layer arrays and scales, and 32 golden inputs are emitted. Run `cnn_runner` on those inputs and compare all three int32 logits and the chosen class exactly with Python quantized output.

- [ ] **Step 2: Run the model test and confirm missing implementation**

Run: `python3 -m unittest tests.test_model -v`

Expected: FAIL importing `model.network`.

- [ ] **Step 3: Implement the float CNN and deterministic trainer**

Implement vectorized im2col-based valid 3x3 convolution, ReLU, 2x2 max pool, second valid convolution, three-bin horizontal spatial average pooling, and dense output with NumPy arrays. The pooling produces 24 features instead of erasing the horizontal position required by LEFT/CENTER/RIGHT classification. Backpropagate cross-entropy through every layer; train on 3000 generated frames with seed 1201 for 25 epochs, batch size 32, Adam learning rate 0.001, and a fixed permutation stream. Evaluate on 600 seed-3103 frames and write loss/accuracy metadata JSON. The trainer must fail if the float accuracy gate is missed.

- [ ] **Step 4: Implement quantization and generated model format**

Use per-layer symmetric int8 weights, int32 bias, explicit integer multiplier/shift requantization, saturating int8 ReLU activations, and int32 logits. Generate a self-contained header under `build/model/model_weights.h`; generated files must include architecture dimensions and a model SHA-256, not source timestamps.

- [ ] **Step 5: Implement the matching C runtime**

Expose:

```c
typedef struct { int32_t logits[3]; uint8_t klass; uint16_t confidence_q15; } cnn_result_t;
int cnn_infer_32x32(const uint8_t pixels[1024], cnn_result_t *result);
```

Use fixed-size caller-independent scratch buffers, checked integer arithmetic, the generated weights header, and the exact quantized rounding rule. Confidence is the nonnegative top-one/top-two logit margin normalized and saturated to Q15.

- [ ] **Step 6: Verify reproducibility and C equivalence**

Run: `./scripts/build_model.sh && sha256sum build/model/model_weights.h > build/first.sha && ./scripts/build_model.sh && sha256sum -c build/first.sha && python3 -m unittest tests.test_model -v`

Expected: checksum verification and all model tests PASS; reported quantized accuracy is at least 95%.

- [ ] **Step 7: Commit model and inference sources**

```bash
git add model/network.py model/train.py model/quantize.py src/linux/cnn.h src/linux/cnn.c tests/cnn_runner.c tests/test_model.py scripts/build_model.sh tests/Makefile
git commit -m "feat(ai): add reproducible int8 line classifier"
```

### Task 6: RT-IPC Session Adapter and Recovery Semantics

**Files:**
- Create: `src/common/session.h`
- Create: `src/common/session.c`
- Create: `tests/test_session.c`
- Create: `tests/test_rtipc_integration.sh`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write an in-memory two-peer session test**

Create client/server RT-IPC connections with a fake monotonic clock and packet queues. Verify handshake, one STEP/STATUS transaction, first CTRL_CMD drop and retransmission, first STATUS_REP drop and retransmission, repeated application `frame_id` idempotency, heartbeat timeout, reconnect, and resend of the outstanding frame after reconnect. Assert transport retries and application duplicates are separate counters.

- [ ] **Step 2: Run the test and confirm missing session API**

Run: `make -C tests test_session`

Expected: compilation FAIL because `session.h` does not exist.

- [ ] **Step 3: Implement action pumping without platform I/O**

Define callbacks `send_datagram(context, bytes, len)` and `deliver_message(context, type, payload, len, now_ms)`. `task3_session_on_datagram` and `task3_session_tick` call the RT-IPC engine, copy a DELIVER payload before any API that clears actions, and drain every generated SEND action. Configure RTO 50 ms, retries 5, heartbeat 1000/5000 ms, connect timeout 500 ms, and automatic reconnect. Client transaction state stores the one outstanding encoded STEP and reissues it with the same frame id only after reconnection.

- [ ] **Step 4: Run shared protocol and session tests**

Run: `make -C ../protocol/c test test_loopback && make -C tests test_session SANITIZE=1`

Expected: upstream RT-IPC tests and task-three session tests PASS.

- [ ] **Step 5: Commit session integration**

```bash
git add src/common/session.h src/common/session.c tests/test_session.c tests/test_rtipc_integration.sh tests/Makefile
git commit -m "feat(network): integrate task3 transactions with RT-IPC"
```

### Task 7: Linux Experiment Application and Metrics

**Files:**
- Create: `src/linux/metrics.h`
- Create: `src/linux/metrics.c`
- Create: `src/linux/rtipc_client.h`
- Create: `src/linux/rtipc_client.c`
- Create: `src/linux/main.c`
- Create: `tests/test_metrics.c`
- Create: `tests/test_linux_cli.sh`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write metric and CLI tests**

For a fixed latency vector `{10,20,30,40,100}`, assert min 10, mean 40, p50 30, p95 100, p99 100, max 100. Feed a position trace with a direction change and assert settling requires three consecutive in-band frames. Run the host CLI with `--help`, invalid IP, missing Y4M, and mismatched truth row count; assert clear nonzero failures without opening a socket for invalid inputs.

- [ ] **Step 2: Verify focused tests fail**

Run: `make -C tests test_metrics test_linux_cli`

Expected: missing `metrics.h` and missing Linux binary failures.

- [ ] **Step 3: Implement bounded metrics and CSV records**

Define one record per frame containing all design fields. Store at most 1200 normal-run records, 600 per mode; sort metric-specific copies for nearest-rank percentiles, compute confusion matrix and absolute Q15 tracking error, and detect settling with the exact three-frame rule. CSV writes must include a schema/version header and flush each completed transaction so QEMU termination does not lose prior rows. Because initramfs storage is ephemeral, every completed row must also be emitted as one escaped `TASK3_FRAME_CSV=<row>` serial marker for host extraction.

- [ ] **Step 4: Implement the POSIX UDP client**

Use nonblocking UDP with `poll`, `CLOCK_MONOTONIC_RAW`, and a fixed peer `192.168.77.30:9876`. The send callback supports `--drop-tx-seq N` before `sendto` and increments injected-drop counters. Run RESET/FIXED, 600 frames, RESET/AI, the same 600 frames, then STOP. Wait according to Y4M FPS using absolute sleeps, associate STATUS by frame id, emit each CSV record with `TASK3_FRAME_CSV=`, and emit exactly one `TASK3_SUMMARY_JSON=<json>` marker after validating both phases.

- [ ] **Step 5: Run host-side Linux tests**

Run: `make -C tests test_metrics test_linux_cli SANITIZE=1`

Expected: all tests PASS and `--help` documents video, truth, peer, frame count, CSV, and drop options.

- [ ] **Step 6: Commit the Linux application**

```bash
git add src/linux/metrics.h src/linux/metrics.c src/linux/rtipc_client.h src/linux/rtipc_client.c src/linux/main.c tests/test_metrics.c tests/test_linux_cli.sh tests/Makefile
git commit -m "feat(linux): add AI control experiment client"
```

### Task 8: RT-Thread Server Application

**Files:**
- Create: `src/rtthread/task3_server.c`
- Create: `src/rtthread/SConscript`
- Create: `tests/rtthread_stubs/rtthread.h`
- Create: `tests/rtthread_stubs/sys/socket.h`
- Create: `tests/test_rtthread_server.c`
- Modify: `tests/Makefile`

- [ ] **Step 1: Write a host-compiled RT-Thread handler test**

Compile the server handler with minimal RT-Thread/lwIP stubs. Feed RESET, valid STEP, repeated frame id, malformed command, and STOP deliveries. Assert response message types, cached duplicate status, error notification fields, and that the server prints no per-frame line unless verbose mode is enabled.

- [ ] **Step 2: Run the test and confirm missing server handler**

Run: `make -C tests test_rtthread_server`

Expected: compilation FAIL because `task3_server.c` is absent.

- [ ] **Step 3: Implement the lwIP UDP service and startup thread**

Bind `0.0.0.0:9876`, poll with a 10 ms receive timeout, drive `task3_session_tick`, and use RT-Thread's high-resolution counter conversion for processing microseconds. On network readiness, start one named thread with fixed priority and stack size. Emit `TASK3_RTOS_READY ip=192.168.77.30 port=9876` once, periodic aggregate counters every five seconds, and `TASK3_RTOS_FINAL` on STOP. The application must not allocate per packet after startup. A compile-time `TASK3_FAULT_DROP_STATUS_ONCE` switch, disabled in the normal image, drops the first STATUS datagram in a separately named fault-test image without changing RT-IPC core behavior.

- [ ] **Step 4: Run handler and common tests**

Run: `make -C tests test_rtthread_server SANITIZE=1 && make -C tests test`

Expected: all host tests PASS.

- [ ] **Step 5: Commit the RT-Thread application**

```bash
git add src/rtthread/task3_server.c src/rtthread/SConscript tests/rtthread_stubs tests/test_rtthread_server.c tests/Makefile
git commit -m "feat(rtthread): add RT-IPC steering control server"
```

### Task 9: Pinned Linux and RT-Thread Image Builds

**Files:**
- Create: `scripts/fetch_sources.sh`
- Create: `scripts/set_kconfig.py`
- Create: `scripts/build_linux.sh`
- Create: `scripts/build_rtthread.sh`
- Create: `configs/buildroot_defconfig`
- Create: `configs/linux.config`
- Create: `configs/rtthread.config`
- Create: `buildroot/external.desc`
- Create: `buildroot/Config.in`
- Create: `buildroot/external.mk`
- Create: `buildroot/package/task3-linux/Config.in`
- Create: `buildroot/package/task3-linux/task3-linux.mk`
- Create: `buildroot/rootfs-overlay/etc/init.d/S99task3`
- Create: `patches/rtthread/0001-qemu-virt64-task3-config.patch`
- Create: `tests/test_build_contracts.sh`

- [ ] **Step 1: Write source and image build contracts**

Assert fetch scripts reject a mismatched existing checkout, validate exact upstream commits, verify the Arm toolchain tarball checksum before extraction, never write `rtconfig.h`, and use `scons --pyconfig-silent`. Assert Linux defconfig contains AArch64/cortex-A53, virtio MMIO/net, devtmpfs, proc/sysfs, IPv4/UDP, initramfs, two CPUs, and the BR2 external task-three package. Assert RT-Thread config contains lwIP 2.1.2, static `192.168.77.30/24`, UDP, netdev, SAL/lwIP, virtio-net, one CPU, and the upstream `0x40000000` RAM offset.

- [ ] **Step 2: Run contract tests and verify missing files**

Run: `sh tests/test_build_contracts.sh`

Expected: FAIL listing the first absent config or script.

- [ ] **Step 3: Implement pinned source and toolchain retrieval**

Clone RT-Thread and Buildroot into `build/sources` with detached exact commits from the lock file. Download the AArch64 bare-metal toolchain to `build/downloads`, verify SHA-256, then extract to `build/toolchains`. Existing valid directories are reused; an origin or commit mismatch is a hard failure.

- [ ] **Step 4: Implement the Buildroot external package and Linux image**

The package compiles `task3-linux` with Buildroot's target compiler from Linux/common/RT-IPC sources and generated `model_weights.h`, installs it under `/usr/bin`, and installs Y4M/truth files under `/opt/task3`. `S99task3` mounts proc/sys/dev, configures `eth0` as `192.168.77.11/24`, prints `TASK3_LINUX_READY`, runs the client with CSV on the console-backed rootfs, and powers off only after the final summary marker. `build_linux.sh` invokes an out-of-tree Buildroot build and verifies nonempty `Image` and `rootfs.cpio` outputs.

- [ ] **Step 5: Implement the RT-Thread overlay and image build**

Copy task-three RTOS/common/RT-IPC sources into a clean build staging BSP, apply the committed configuration patch, update `.config` through `set_kconfig.py`, and run `scons --pyconfig-silent` followed by `scons -j$(nproc)`. Use only the fetched `aarch64-none-elf` toolchain. Verify the ELF entry is in QEMU RAM, `rtthread.bin` is nonempty, and the image contains `task3_server_start` according to `nm`. Support `--fault-drop-status-once` by building a separate `rtthread-drop-status.bin` with `TASK3_FAULT_DROP_STATUS_ONCE=1`; never overwrite the normal image with a fault variant.

- [ ] **Step 6: Run contract and image smoke builds**

Run: `sh tests/test_build_contracts.sh && ./scripts/build_linux.sh && ./scripts/build_rtthread.sh`

Expected: contracts PASS; `build/images/linux/Image`, `build/images/linux/rootfs.cpio`, and `build/images/rtthread/rtthread.bin` exist and are nonempty.

- [ ] **Step 7: Commit reproducible image definitions**

```bash
git add scripts/fetch_sources.sh scripts/set_kconfig.py scripts/build_linux.sh scripts/build_rtthread.sh configs buildroot patches/rtthread tests/test_build_contracts.sh
git commit -m "build: add reproducible Linux and RT-Thread images"
```

### Task 10: Dual-QEMU Orchestration and Normal End-to-End Run

**Files:**
- Create: `scripts/run_demo.sh`
- Create: `scripts/wait_for_marker.sh`
- Create: `tests/test_run_demo_contract.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write orchestration safety contracts**

Check the script uses two explicit PID variables, a trap that kills and waits only for those PIDs, no `pkill`/`killall`, a bounded readiness wait, unique run directory, configurable multicast port, and these fixed device arguments:

```text
-M virt,gic-version=2 -cpu cortex-a53
-netdev socket,id=net0,mcast=230.77.0.1:10077
-device virtio-net-device,netdev=net0,mac=<guest MAC>
```

Assert Linux uses `-smp 2 -m 256M -kernel Image -initrd rootfs.cpio`; RT-Thread uses `-smp 1 -m 128M -kernel rtthread.bin`.

- [ ] **Step 2: Run the contract and verify failure**

Run: `sh tests/test_run_demo_contract.sh`

Expected: FAIL because `run_demo.sh` is absent.

- [ ] **Step 3: Implement bounded two-process orchestration**

Create `build/runs/<UTC timestamp>-normal`, record commands and versions, start RT-Thread first with serial redirected to `rtthread.log`, wait at most 60 seconds for `TASK3_RTOS_READY`, then start Linux with serial redirected to `linux.log`. Wait at most 180 seconds for `TASK3_SUMMARY_JSON=`, terminate both owned processes, extract exactly 1200 `TASK3_FRAME_CSV=` markers to `frames.csv`, extract the summary marker to `summary.raw.json`, and invoke `summarize.py`. Preserve logs on every exit path and return nonzero on readiness, QEMU, frame count, summary, or gate failure. Smoke mode requires exactly twice its requested frame count instead of 1200.

- [ ] **Step 4: Run shell contracts and a short integration smoke test**

Run: `sh tests/test_run_demo_contract.sh && ./scripts/run_demo.sh --frames 30 --multicast-port 10078 --smoke`

Expected: shell contracts PASS, both readiness markers appear, 30 FIXED and 30 AI transactions complete, and the smoke summary is valid without enforcing the 600-frame quality gate.

- [ ] **Step 5: Commit orchestration**

```bash
git add scripts/run_demo.sh scripts/wait_for_marker.sh tests/test_run_demo_contract.sh Makefile
git commit -m "feat(qemu): orchestrate dual-guest AI control demo"
```

### Task 11: Fault Injection, Metrics Summary, and Report Generation

**Files:**
- Create: `scripts/run_faults.sh`
- Create: `scripts/summarize.py`
- Create: `scripts/render_report.py`
- Create: `tests/fixtures/normal_frames.csv`
- Create: `tests/fixtures/fault_events.csv`
- Create: `tests/test_summarize.py`
- Create: `tests/test_report.py`
- Create: `tests/test_fault_contract.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write summary and report tests**

Use checked fixtures with known confusion matrix, retries, latency order statistics, errors, tracking MAE, and settling intervals. Assert summary JSON uses schema 1, computes success rate and effective payload throughput, rejects missing/duplicate frame rows, and enforces gates only for 600-frame normal runs. Assert the report contains topology, commands, versions, runtime, load placement, timing method/error sources, baseline-vs-AI table, reliability table, and direct references to source result files.

- [ ] **Step 2: Write fault-run shell contracts**

Require five named cases: `drop-control`, `drop-status`, `duplicate-frame`, `delayed-server`, and `malformed`. Each case must use a separate run directory and expected marker, and the script must fail if duplicate `applied_steps` increases.

- [ ] **Step 3: Run tests and confirm missing tools**

Run: `python3 -m unittest tests.test_summarize tests.test_report -v && sh tests/test_fault_contract.sh`

Expected: FAIL importing summary/report modules or finding `run_faults.sh`.

- [ ] **Step 4: Implement strict summary and report generation**

Parse CSV with `csv.DictReader`, validate integer ranges and one row per mode/frame, calculate nearest-rank percentiles, confusion matrix, request/recovery counters, tracking error, stable transitions, and throughput. Write JSON atomically. `render_report.py` accepts an explicit run directory or `--latest`, requires complete raw logs/CSV/JSON, and renders values without embedded defaults; missing evidence is a hard error.

- [ ] **Step 5: Implement deterministic fault scenarios**

Run short QEMU sessions with the Linux `--drop-tx-seq` option, the separately built `rtthread-drop-status.bin`, explicit guest start delays, and the Linux duplicate-frame mode. For malformed packets, use a Linux-side mode that sends schema 2, a wrong-size valid-CRC payload, and a corrupted-CRC packet, then requests status to prove the actuator did not change. Aggregate each expected recovery marker into `fault-summary.json`.

- [ ] **Step 6: Run host tests and fault integration**

Run: `python3 -m unittest tests.test_summarize tests.test_report -v && sh tests/test_fault_contract.sh && ./scripts/run_faults.sh`

Expected: all tests PASS; every fault case reports recovered or correctly rejected, with zero duplicate control applications.

- [ ] **Step 7: Commit metrics and recovery tooling**

```bash
git add scripts/run_faults.sh scripts/summarize.py scripts/render_report.py tests/fixtures tests/test_summarize.py tests/test_report.py tests/test_fault_contract.sh Makefile
git commit -m "test: add task3 recovery and result reporting"
```

### Task 12: Full Evaluation, Documentation, and Reproducibility Audit

**Files:**
- Create: `README.md`
- Create: `docs/protocol.md`
- Create: `docs/results/task3-report.md`
- Create: `tests/test_docs_contract.sh`

- [ ] **Step 1: Write documentation evidence contracts**

Assert README names branch and commit procedure, dependency versions, complete build/run commands, QEMU CPU/memory/device arguments, MAC/IP/route/port topology, no-NAT/no-firewall policy, 60+60 second runtime, expected output locations, CPU load roles, and cleanup behavior. Assert protocol documentation includes every field/offset and reliability boundary. Assert the result report contains no placeholder words or fabricated fallback values and cites an existing normal run plus fault summary.

- [ ] **Step 2: Run the documentation contract and verify failure**

Run: `sh tests/test_docs_contract.sh`

Expected: FAIL because README and final evidence report are absent.

- [ ] **Step 3: Run fresh full evaluation**

Run: `make doctor && make model && make test && make images && make demo && make fault-test && make report`

Expected: all unit/build/integration commands PASS; normal evaluation contains 600 FIXED and 600 AI frames; request success is at least 99.5%, quantized accuracy at least 95%, AI tracking MAE improves by at least 30%, and all recovery cases pass.

- [ ] **Step 4: Write documentation from verified commands and outputs**

Document the exact observed tool versions and generated image paths, both full QEMU command lines, guest startup parameters, application protocol, measurement precision and limitations, raw-data schema, one-command workflow, and troubleshooting. Generate `docs/results/task3-report.md` from the successful run via `render_report.py`, then add a short human-written interpretation that does not alter generated numeric tables.

- [ ] **Step 5: Run final reproducibility and cleanliness checks**

Run:

```bash
sh tests/test_docs_contract.sh
make test
git diff --check
git status --short
```

Expected: documentation and tests PASS, no whitespace errors, and only intended source/config/docs plus the real report are tracked; `build/` remains ignored.

- [ ] **Step 6: Commit final documentation and evidence**

```bash
git add README.md docs/protocol.md docs/results/task3-report.md tests/test_docs_contract.sh
git commit -m "docs: publish reproducible task3 evaluation"
```

- [ ] **Step 7: Record final branch state**

Run: `git log --oneline --decorate -15 && git status --short --branch`

Expected: branch `feat/task3-ai-control` contains the design, plan, staged implementation commits, and final evidence commit with a clean worktree.
