# AxVisor Linux + RT-Thread Docker Reproduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pinned Docker environment and Chinese runbook that reproduce the 2-vCPU Linux plus CPU-pinned RT-Thread system, VirtIO-net/RT-IPC communication, and realtime benchmarks from a fresh Ubuntu host.

**Architecture:** A dedicated reproduction image extends the immutable amd64 project CI image and replaces its QEMU runtime with QEMU 11.0.2 built from a pinned Git commit. Docker Compose supplies the cpuset, `SYS_NICE`, user identity, writable caches, and source mount; existing repository scripts remain the only build and benchmark entry points.

**Tech Stack:** Docker Engine, Docker Compose, Ubuntu 24.04, QEMU 11.0.2 TCG, Rust/Cargo, GNU AArch64 tools, RT-Thread 5.2.2, uv/SCons, POSIX shell, AxVisor, VirtIO-net, UDP/IP, RT-IPC.

---

## File Map

- Create `container/Dockerfile.rtthread-repro`: immutable toolchain and QEMU image.
- Create `container/rtthread-repro-preflight.sh`: in-container capability, version, cpuset, and writable-path checks.
- Create `container/test-rtthread-repro.sh`: fail-closed static and rendered-Compose contract.
- Create `compose.rtthread-repro.yml`: supported runtime options and mounts.
- Create `docs/docs/build/axvisor/rtthread-reproduction.md`: end-user Chinese runbook.
- Modify `docs/docs/build/axvisor/rtthread-realtime-report.md`: append only Docker-specific measurements and evidence when collected; do not stage the whole pre-existing dirty report.

### Task 1: Add a failing Docker reproduction contract

**Files:**
- Create: `container/test-rtthread-repro.sh`
- Test: `container/test-rtthread-repro.sh`

- [ ] **Step 1: Write the contract before implementation**

Create a shell test that requires:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DOCKERFILE="$ROOT/container/Dockerfile.rtthread-repro"
COMPOSE="$ROOT/compose.rtthread-repro.yml"
PREFLIGHT="$ROOT/container/rtthread-repro-preflight.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
for file in "$DOCKERFILE" "$COMPOSE" "$PREFLIGHT"; do
    [[ -f "$file" ]] || fail "missing Docker reproduction file: $file"
done

for token in \
    'ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4' \
    'ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4' \
    'QEMU_VERSION=11.0.2' \
    'QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482' \
    'aarch64-linux-gnu-strip' 'pidstat' 'socat' 'uclampset'; do
    grep -Fq -- "$token" "$DOCKERFILE" || fail "Dockerfile missing: $token"
done

grep -Fq 'SYS_NICE' "$COMPOSE" || fail 'Compose must add SYS_NICE'
grep -Fq 'RT_REPRO_CPUSET' "$COMPOSE" || fail 'Compose must expose RT_REPRO_CPUSET'
grep -Fq 'RT_REPRO_UID' "$COMPOSE" || fail 'Compose must preserve output ownership'
grep -Fq 'RT_REPRO_GID' "$COMPOSE" || fail 'Compose must preserve output ownership'
if grep -Eq 'privileged:[[:space:]]*true|network_mode:[[:space:]]*host|/dev/kvm' "$COMPOSE"; then
    fail 'Compose must not use privileged, host networking, or KVM'
fi

for token in qemu-system-aarch64 uv uclampset pidstat socat aarch64-linux-gnu-strip; do
    grep -Fq -- "$token" "$PREFLIGHT" || fail "preflight missing command: $token"
done

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    rendered=$(RT_REPRO_UID=1000 RT_REPRO_GID=1000 RT_REPRO_CPUSET=0-3 \
        docker compose -f "$COMPOSE" config)
    grep -Fq 'SYS_NICE' <<<"$rendered" || fail 'rendered Compose lost SYS_NICE'
    grep -Fq 'cpuset: 0-3' <<<"$rendered" || fail 'rendered Compose lost cpuset'
fi

echo 'PASS: RT-Thread Docker reproduction contract'
```

- [ ] **Step 2: Run the contract and observe the expected failure**

Run:

```bash
bash container/test-rtthread-repro.sh
```

Expected: non-zero exit with `missing Docker reproduction file`.

- [ ] **Step 3: Commit only the contract**

```bash
git add -- container/test-rtthread-repro.sh
git commit --only -m "test: define RT-Thread Docker reproduction contract" -- \
  container/test-rtthread-repro.sh
```

Before and after the commit, run `git diff --cached --name-status` and verify the pre-existing staged `rt_benchmark.c` remains untouched.

### Task 2: Build the pinned reproduction image and preflight

**Files:**
- Create: `container/Dockerfile.rtthread-repro`
- Create: `container/rtthread-repro-preflight.sh`
- Test: `container/test-rtthread-repro.sh`

- [ ] **Step 1: Implement the dedicated multi-stage Dockerfile**

Use the exact immutable inputs:

```dockerfile
ARG BASE_IMAGE=ghcr.io/rcore-os/tgoskits-container@sha256:d011369e5da7d4d5f4379fafad3d46868c116b9d23bfc6f92ce3846432cad9d4
ARG UV_IMAGE=ghcr.io/astral-sh/uv@sha256:265d074d08ed8080bc578087ca68a8e94611f9c7be671d40e18b3d3b1ad0dad4

FROM ${UV_IMAGE} AS uv
FROM ${BASE_IMAGE} AS qemu-builder
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
RUN set -eux; \
    git clone --filter=blob:none --no-checkout https://gitlab.com/qemu-project/qemu.git /tmp/qemu; \
    git -C /tmp/qemu fetch --depth 1 origin "${QEMU_COMMIT}"; \
    git -C /tmp/qemu checkout --detach "${QEMU_COMMIT}"; \
    test "$(git -C /tmp/qemu rev-parse HEAD)" = "${QEMU_COMMIT}"; \
    git -C /tmp/qemu submodule update --init --depth 1; \
    cd /tmp/qemu; \
    ./configure --prefix="/opt/qemu-${QEMU_VERSION}" \
      --target-list=aarch64-softmmu --enable-slirp --disable-docs \
      --disable-gtk --disable-sdl --disable-vte --disable-werror; \
    make -j"$(nproc)"; \
    make install

FROM ${BASE_IMAGE}
ARG QEMU_VERSION=11.0.2
ARG QEMU_COMMIT=e545d8bb9d63e9dd61542b88463183314cff9482
ARG UV_VERSION=0.11.16
ARG RTTHREAD_COMMIT=ddf52e2cdd977f14fc04035c88672ac204aec713
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu \
      libcap2-bin socat sysstat util-linux \
    && rm -rf /var/lib/apt/lists/*
COPY --from=qemu-builder "/opt/qemu-${QEMU_VERSION}" "/opt/qemu-${QEMU_VERSION}"
COPY --from=uv /uv /uvx /usr/local/bin/
COPY container/rtthread-repro-preflight.sh /usr/local/bin/rtthread-repro-preflight
RUN chmod 0755 /usr/local/bin/rtthread-repro-preflight \
    && for tool in aarch64-linux-gnu-strip pidstat socat uclampset; do \
         command -v "$tool"; \
       done
ENV PATH="/opt/qemu-${QEMU_VERSION}/bin:${PATH}" \
    QEMU="/opt/qemu-${QEMU_VERSION}/bin/qemu-system-aarch64" \
    UV_LINK_MODE=copy
LABEL org.opencontainers.image.title="tgoskits RT-Thread reproduction" \
      io.tgoskits.qemu.version="${QEMU_VERSION}" \
      io.tgoskits.qemu.commit="${QEMU_COMMIT}" \
      io.tgoskits.uv.version="${UV_VERSION}" \
      io.tgoskits.rtthread.commit="${RTTHREAD_COMMIT}"
WORKDIR /workspace
CMD ["bash"]
```

If QEMU's pinned commit requires additional release submodules, keep the commit
unchanged and add only the minimal clone/submodule flags needed for that commit.

- [ ] **Step 2: Implement the complete in-container preflight**

```bash
#!/usr/bin/env bash
set -euo pipefail

fail() { echo "[rtthread-repro] ERROR: $*" >&2; exit 1; }

[[ "$(uname -m)" = x86_64 ]] || fail "container must run on x86_64"
visible_cpus=$(nproc)
[[ "$visible_cpus" -ge 4 ]] || fail "at least four CPUs must be visible"

for tool in \
    cargo rustc git make uv qemu-system-aarch64 \
    aarch64-linux-gnu-strip aarch64-linux-gnu-objcopy \
    aarch64-linux-musl-gcc pidstat socat uclampset; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing command: $tool"
done

qemu_version=$(qemu-system-aarch64 --version | head -n 1)
[[ "$qemu_version" == *'version 11.0.2'* ]] \
    || fail "unexpected QEMU version: $qemu_version"
[[ "$(uv --version)" = 'uv 0.11.16' ]] \
    || fail "unexpected uv version: $(uv --version)"

for directory in \
    "${HOME:?HOME is required}" \
    "${CARGO_HOME:?CARGO_HOME is required}" \
    "${UV_CACHE_DIR:?UV_CACHE_DIR is required}" \
    /workspace/docs/docs/build/axvisor/docker-repro; do
    mkdir -p -- "$directory"
    [[ -w "$directory" ]] || fail "directory is not writable: $directory"
done

allowed_cpus=$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)
[[ -n "$allowed_cpus" ]] || fail 'could not read Cpus_allowed_list'
echo "[rtthread-repro] cpus_allowed=$allowed_cpus visible_cpus=$visible_cpus"
echo "[rtthread-repro] loadavg=$(cat /proc/loadavg)"

sleep 30 &
probe_pid=$!
cleanup() {
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
uclampset -m 1 -p "$probe_pid" >/dev/null
cleanup
trap - EXIT INT TERM

echo "[rtthread-repro] qemu=$qemu_version"
echo "[rtthread-repro] uv=$(uv --version)"
echo '[rtthread-repro] PASS'
```

- [ ] **Step 3: Run static validation**

```bash
bash -n container/rtthread-repro-preflight.sh
set +e
contract_output=$(bash container/test-rtthread-repro.sh 2>&1)
contract_status=$?
set -e
test "$contract_status" -ne 0
grep -Fq 'compose.rtthread-repro.yml' <<<"$contract_output"
```

Expected: syntax check exits zero; the contract fails only for the missing
Compose file. Dockerfile and preflight token checks are reached after Task 3.

- [ ] **Step 4: Commit only the image and preflight**

```bash
git add -- container/Dockerfile.rtthread-repro \
  container/rtthread-repro-preflight.sh
git commit --only -m "build: add pinned RT-Thread reproduction image" -- \
  container/Dockerfile.rtthread-repro container/rtthread-repro-preflight.sh
```

### Task 3: Define the container runtime

**Files:**
- Create: `compose.rtthread-repro.yml`
- Test: `container/test-rtthread-repro.sh`

- [ ] **Step 1: Implement Compose with no privileged access**

```yaml
services:
  rtthread-repro:
    build:
      context: .
      dockerfile: container/Dockerfile.rtthread-repro
    image: tgoskits-rtthread-repro:2026-08-16
    init: true
    cap_add:
      - SYS_NICE
    cpuset: "${RT_REPRO_CPUSET:-0-3}"
    user: "${RT_REPRO_UID:-1000}:${RT_REPRO_GID:-1000}"
    working_dir: /workspace
    environment:
      HOME: /workspace/.docker-cache/home
      CARGO_HOME: /workspace/.docker-cache/cargo
      UV_CACHE_DIR: /workspace/.docker-cache/uv
      RTTHREAD_SRC: /workspace/.docker-cache/rt-thread-5.2.2
      QEMU: /opt/qemu-11.0.2/bin/qemu-system-aarch64
    volumes:
      - .:/workspace
    stdin_open: true
    tty: true
    security_opt:
      - no-new-privileges:true
    stop_grace_period: 30s
```

- [ ] **Step 2: Run the contract and shell syntax checks**

```bash
bash -n container/rtthread-repro-preflight.sh container/test-rtthread-repro.sh
bash container/test-rtthread-repro.sh
RT_REPRO_UID="$(id -u)" RT_REPRO_GID="$(id -g)" RT_REPRO_CPUSET=0-3 \
  docker compose -f compose.rtthread-repro.yml config >/dev/null
```

Expected: all commands exit zero and the contract prints PASS.

- [ ] **Step 3: Commit the runtime contract**

```bash
git add -- compose.rtthread-repro.yml
git commit --only -m "build: define RT-Thread Docker runtime" -- \
  compose.rtthread-repro.yml
```

### Task 4: Write the Chinese Docker runbook

**Files:**
- Create: `docs/docs/build/axvisor/rtthread-reproduction.md`
- Reference: `docs/docs/build/axvisor/rtthread-realtime-report.md`

- [ ] **Step 1: Document fresh-host preparation**

Include exact Ubuntu commands for Docker Engine/Compose installation or state
that distribution Docker 29+/Compose 2.40+ were validated. Require:

```bash
docker --version
docker compose version
git clone git@github.com:qcl-kernel/tgoskits-GoGoGo.git tgoskits
cd tgoskits
git switch rtthread-migration
git rev-parse HEAD
```

Record that the intended source revision includes the Docker implementation
commits; do not tell readers to reproduce from the earlier report HEAD.

- [ ] **Step 2: Document host resource and ownership setup**

```bash
export RT_REPRO_UID="$(id -u)"
export RT_REPRO_GID="$(id -g)"
export RT_REPRO_CPUSET="4-7"   # replace with four lightly loaded CPUs
mkdir -p .docker-cache/{home,cargo,uv} docs/docs/build/axvisor/docker-repro
```

Explain that cpuset is placement, not host isolation, and show `mpstat -P ALL 1`
or `pidstat` as a host-side load check.

- [ ] **Step 3: Document image and preflight commands**

```bash
docker compose -f compose.rtthread-repro.yml build --pull
docker compose -f compose.rtthread-repro.yml run --rm rtthread-repro \
  rtthread-repro-preflight
docker image inspect tgoskits-rtthread-repro:2026-08-16 --format '{{json .RepoDigests}} {{json .Config.Labels}}'
```

- [ ] **Step 4: Document fast verification**

Use one Compose invocation with `bash -lc` to run format, Rust suites, RT-IPC C
tests, all 12 shell contracts, fresh RT-Thread build, and AxVisor aarch64
`axtest`. List expected pass counts and warn about existing non-fatal upstream
RT-Thread compiler warnings.

- [ ] **Step 5: Document the suite and 300-second runs**

Provide the exact existing runner commands with container-visible paths:

```bash
env RTIPC_COUNT=1000 RTBENCH_SUITE_SAMPLES=1000 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/docker-repro/suite-1000.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/docker-repro/suite-1000-cpu.log \
  bash os/axvisor/scripts/run_rtipc_test.sh

env RTIPC_COUNT=30000 RTBENCH_STABILITY_SECONDS=300 \
  RTBENCH_START_MODE=concurrent QEMU_UCLAMP_MIN=1024 \
  LOG=docs/docs/build/axvisor/docker-repro/stability-300s.log \
  CPU_LOAD_LOG=docs/docs/build/axvisor/docker-repro/stability-300s-cpu.log \
  bash os/axvisor/scripts/run_rtipc_test.sh
```

Wrap each command in the documented Compose `run --rm` invocation.

- [ ] **Step 6: Document native baseline, result gates, and evidence**

Include `run_rtthread_native_baseline.sh`, all generated `.qemu`, `.artifacts`,
`.timing`, and CPU logs, SHA-256 collection, success markers, error counters,
sample completeness, percentile extraction, and the same-container A/B rule.
Link the existing report and explicitly separate host data from Docker data.

- [ ] **Step 7: Validate and commit only the new runbook**

```bash
for marker in TB_D TO_DO PLACE_HOLDER; do
  pattern=${marker/_/}
  ! rg -n "$pattern" docs/docs/build/axvisor/rtthread-reproduction.md
done
git diff --check -- docs/docs/build/axvisor/rtthread-reproduction.md
git add -- docs/docs/build/axvisor/rtthread-reproduction.md
git commit --only -m "docs: add RT-Thread Docker reproduction runbook" -- \
  docs/docs/build/axvisor/rtthread-reproduction.md
```

The placeholder scan must return status 1 with no matches; the diff check must
return zero.

### Task 5: Build and verify the image

**Files:** Verify only.

- [ ] **Step 1: Build from immutable inputs**

```bash
export RT_REPRO_UID="$(id -u)"
export RT_REPRO_GID="$(id -g)"
export RT_REPRO_CPUSET="0-3"
mkdir -p .docker-cache/{home,cargo,uv} docs/docs/build/axvisor/docker-repro
docker compose -f compose.rtthread-repro.yml build --pull
```

Expected: image `tgoskits-rtthread-repro:2026-08-16` builds successfully.

- [ ] **Step 2: Run preflight and version checks**

```bash
docker compose -f compose.rtthread-repro.yml run --rm rtthread-repro \
  rtthread-repro-preflight
```

Expected: QEMU 11.0.2, uv 0.11.16, at least four allowed CPUs, writable paths,
and successful uclamp probe.

- [ ] **Step 3: Record immutable image evidence**

Record `docker image inspect` ID, labels, base digest, Docker version, Compose
version, host kernel, CPU model, cpuset, and the SHA-256 of Dockerfile/Compose in
the runbook verification section or Docker report appendix.

### Task 6: Run containerized functional verification

**Files:** Verify only.

- [ ] **Step 1: Run static and unit tests inside the image**

Run the exact matrix from the cleanup plan:

```bash
cargo fmt --all -- --check
cargo test -p arm_vcpu
cargo test -p axvmconfig
cargo test -p axvirtio-net
cargo test -p axvm --features host-test
make -C os/axvisor/guests/rt-ipc/tests clean test
bash container/test-rtthread-repro.sh
```

- [ ] **Step 2: Run all 12 shell contracts inside the image**

Execute the established loop from
`docs/superpowers/plans/2026-08-16-debug-code-cleanup.md` and require every
script to exit zero.

- [ ] **Step 3: Run fresh RT-Thread build and AxVisor axtest**

```bash
RTTHREAD_TEST_BUILD=1 \
  bash os/axvisor/patches/rtthread/test_fresh_rtthread_patchset.sh
cargo xtask ktest qemu -p axvisor --test axtest --arch aarch64
```

Expected: fresh RT-Thread image exists and `AXTEST_SUMMARY pass=83 fail=0`.

### Task 7: Run Docker end-to-end and realtime acceptance

**Files:**
- Modify: `docs/docs/build/axvisor/rtthread-realtime-report.md` only when actual Docker metrics exist.
- Create: `docs/docs/build/axvisor/docker-repro/*` evidence logs.

- [ ] **Step 1: Run a short end-to-end smoke**

Use `RTIPC_COUNT=100`, no long benchmark mode, and a dedicated Docker log path.
Require Linux 2-vCPU marker, RT-Thread lwIP/server readiness, all three payloads
at 100/100, zero errors/timeouts, and successful result gate.

- [ ] **Step 2: Run the 1,000-sample suite**

Use the Task 4 command. Require all three payloads at 1000/1000 and all suite
markers to pass.

- [ ] **Step 3: Run one 300-second stability test**

Use the Task 4 command. Require `90000/90000` requests and
`299999/299999` samples. If only max or `miss_1ms` worsens, run one repeat before
drawing a conclusion.

- [ ] **Step 4: Run the native RT-Thread baseline in the same image/cpuset**

Use `run_rtthread_native_baseline.sh` with separate Docker evidence paths and
the same QEMU path and uclamp value.

- [ ] **Step 5: Append Docker-only results without mixing host data**

Append image ID, host/cgroup/cpuset information, commands, exit codes, network
counts, percentiles, maximum, `miss_1ms`, CPU distribution, artifact hashes, and
the explicit Docker-overhead caveat. Do not stage the report because it already
contains unrelated uncommitted work; identify the appended hunk and after hash.

### Task 8: Final integrity and review

**Files:** Verify all new Docker and documentation files.

- [ ] **Step 1: Run final fast verification**

```bash
bash -n container/test-rtthread-repro.sh container/rtthread-repro-preflight.sh
bash container/test-rtthread-repro.sh
docker compose -f compose.rtthread-repro.yml config >/dev/null
git diff --check
```

- [ ] **Step 2: Verify security and data boundaries**

Confirm rendered Compose contains `SYS_NICE`, the selected cpuset, no resource
quota, no `privileged`, no host network, and no KVM/device mapping. Confirm all
logs remain under `docs/docs/build/axvisor/docker-repro/` and no external QEMU
process was terminated.

- [ ] **Step 3: Request spec and quality review**

Review against
`docs/superpowers/specs/2026-08-16-rtthread-full-reproduction-document-design.md`.
Critical or Important findings must be fixed and re-reviewed before completion.

- [ ] **Step 4: Report branch/index status**

Run `git status --short`, `git diff --cached --name-status`, and the scoped diff
stats. Explicitly report that the pre-existing staged `rt_benchmark.c` was not
included in Docker commits and that the dirty realtime report was not staged.
