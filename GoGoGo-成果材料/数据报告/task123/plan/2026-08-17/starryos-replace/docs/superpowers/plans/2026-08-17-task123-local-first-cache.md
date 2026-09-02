# Task 1/2/3 Local-First Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Task 1/2/3 reproduction reuse verified local artifacts and build outputs before automatically downloading missing content with visible progress.

**Architecture:** Add one focused artifact preparer that resolves explicit inputs, a fingerprinted cache, and accepted local evidence in order, then builds missing Linux/RT-Thread/rootfs artifacts into an atomically published cache entry. Both the one-click reproducer and standalone runner consume the preparer's generated manifest, while existing runner code retains VM construction, QEMU ownership, and result gating.

**Tech Stack:** Bash 5, Python 3 standard library for structured manifest handling, Git, SHA-256, flock, Buildroot, uv/SCons, Cargo, existing Task 1/2/3 shell contract tests.

---

## File Structure

- Create `os/axvisor/scripts/task123_artifacts.py`: parse evidence/cache manifests,
  validate hashes, discover repository-relative local candidates, compute the
  build fingerprint, and emit a normalized JSON resolution plan.
- Create `os/axvisor/scripts/prepare_task123_artifacts.sh`: own cache locking,
  staging builds, atomic publication, progress output, and the final shell-safe
  artifact environment file.
- Create `os/axvisor/scripts/test_prepare_task123_artifacts.sh`: exercise local,
  cache, download, invalidation, interruption, and no-hardcoded-path contracts.
- Modify `os/axvisor/scripts/reproduce_task123.sh`: prepare once, load immutable
  artifact paths, and reuse them for every quick/full phase.
- Modify `os/axvisor/scripts/run_task123.sh`: delegate missing-artifact fallback
  to the preparer and keep runner progress on its dedicated descriptor.
- Modify `os/axvisor/guests/task3/scripts/fetch_sources.sh`: identify network
  versus local Git sources and force visible Git progress.
- Modify `os/axvisor/patches/rtthread/prepare_rtthread_source.sh`: identify the
  source URL and force visible progress without `--quiet`.
- Modify `os/axvisor/guests/task3/configs/dependencies.lock`: pin the SCons
  version used by uv and include it in cache identity.
- Modify existing shell tests and Chinese reproduction documentation to lock the
  new behavior.

### Task 1: Structured Local Artifact Resolution

**Files:**
- Create: `os/axvisor/scripts/task123_artifacts.py`
- Create: `os/axvisor/scripts/test_prepare_task123_artifacts.sh`
- Reference: `os/axvisor/scripts/run_task123.sh`
- Reference: `docs/superpowers/specs/2026-08-17-task123-local-first-cache-design.md`

- [ ] **Step 1: Write failing resolver tests**

Create fixtures under a test-owned `mktemp -d` containing an accepted evidence
manifest and files for QEMU, Linux Image, initramfs, model and rootfs. Record
their real hashes and invoke:

```bash
python3 "$RESOLVER" resolve \
  --root "$fixture_root" \
  --cache "$fixture_root/tmp/task123-cache" \
  --evidence-root "$fixture_root/tmp/task123-results" \
  --output "$tmp/resolution.json"
```

Assert with Python that each selected object has `origin == "evidence"`, an
absolute path inside the fixture, and the expected SHA-256. Add cases proving:

```text
explicit valid input > cache > evidence
invalid explicit input => nonzero exit
invalid cache hash => evidence selected
evidence result_gate != PASS => rejected
no candidate => action == "build" or "download"
```

Also scan the resolver and its generated JSON for `/home/`, `yfblock`, and any
path outside the fixture.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
bash os/axvisor/scripts/test_prepare_task123_artifacts.sh
```

Expected: FAIL because `task123_artifacts.py` does not exist.

- [ ] **Step 3: Implement the resolver CLI**

Implement a `resolve` subcommand using only Python's standard library. Keep the
implementation split into these exact typed functions: `sha256_file(Path) ->
str`, `parse_runner_manifest(Path) -> dict[str, object]`,
`validate_candidate(Path, str) -> bool`, `find_accepted_evidence(Path) ->
list[dict[str, object]]`, `find_local_rtthread_repository(Path, str) -> Path |
None`, and `compute_fingerprint(Path, Path, list[str]) -> str`. Each parser
raises `ValueError` for malformed data; `main()` catches it, prints a
`task123 artifacts:` diagnostic to stderr, and exits 2.

`resolve` must accept explicit values through named arguments rather than read
ambient environment. Emit schema 1 atomically with a 64-character lowercase
fingerprint, an `artifacts` object keyed by the five base artifact names and any
resolved RT-Thread image names, one
`rtthread_repository` object, and a `missing` string array. Every selected
artifact object contains exactly `origin`, absolute `path`, and `sha256`.

Parse `ARTIFACT` lines with a strict regular
expression and reject duplicate names, malformed hashes, missing
`result_gate=PASS`, and paths that no longer match their hash.

- [ ] **Step 4: Run resolver tests and verify GREEN**

Run the test from Step 2. Expected: PASS for all local-resolution cases and no
network commands recorded by the fake command wrappers.

- [ ] **Step 5: Commit Task 1**

```bash
git add os/axvisor/scripts/task123_artifacts.py \
  os/axvisor/scripts/test_prepare_task123_artifacts.sh
git commit -m "feat(axvisor): resolve task123 artifacts locally"
```

### Task 2: Fingerprinted Atomic Build Cache

**Files:**
- Create: `os/axvisor/scripts/prepare_task123_artifacts.sh`
- Modify: `os/axvisor/scripts/task123_artifacts.py`
- Modify: `os/axvisor/scripts/test_prepare_task123_artifacts.sh`
- Modify: `os/axvisor/guests/task3/configs/dependencies.lock`

- [ ] **Step 1: Add failing cache and single-build tests**

Use fake Linux, RT-Thread and rootfs builders that append their invocation to a
record file and write deterministic fixture binaries. Invoke the preparer twice
with the same cache and assert:

```text
first call: each builder invoked exactly once
second call: no builder invoked
normal/drop-status/delayed-server paths are identical across calls
manifest hashes match every output
```

Change one tracked patch fixture and one fake compiler identity independently;
each change must select a different fingerprint directory and rebuild once.
Make a builder exit after writing one file and assert the final fingerprint
directory and valid manifest do not exist.

- [ ] **Step 2: Run the cache tests and verify RED**

Run:

```bash
bash os/axvisor/scripts/test_prepare_task123_artifacts.sh
```

Expected: FAIL because the preparer and atomic cache publication are absent.

- [ ] **Step 3: Pin SCons and implement cache preparation**

Add a concrete `SCONS_VERSION` to `dependencies.lock` and replace every
preparer-owned invocation with:

```bash
uv run --with "scons==$SCONS_VERSION" scons \
  -C "$bsp" -j"$(getconf _NPROCESSORS_ONLN)"
```

Implement the preparer interface:

```text
prepare_task123_artifacts.sh \
  --cache-dir DIR \
  --manifest FILE \
  [--evidence-root DIR]
```

Use `realpath`, reject `/` and the repository root as cache destinations, open
`$cache/locks/prepare.lock` with `flock`, resolve again after acquiring the
lock, and build into:

```bash
staging="$(mktemp -d "$cache/.prepare.XXXXXX")"
```

Create `$cache/sources` and `$cache/downloads` while holding the lock. Before
calling `build_linux.sh`, create `sources` and `downloads` symlinks in its
staging `BUILD_DIR` that point to those cache-owned directories. Validate both
symlink targets with `realpath` before execution. This preserves the pinned Git
objects and Buildroot package archives across failed and successful artifact
builds without publishing partial binaries.

Build Linux once through `build_linux.sh`, clone the pinned RT-Thread commit
from the resolver-selected local repository when available, apply patches once,
and build the three variants by setting:

```bash
TASK3_FAULT_DROP_STATUS_ONCE=0 TASK3_FAULT_DELAY_START_MS=0
TASK3_FAULT_DROP_STATUS_ONCE=1 TASK3_FAULT_DELAY_START_MS=0
TASK3_FAULT_DROP_STATUS_ONCE=0 TASK3_FAULT_DELAY_START_MS=3000
```

Resolve rootfs through explicit/cache/evidence first and call
`cargo xtask image pull qemu-aarch64` only when missing. Ask the Python helper
to write the cache manifest, verify it, then atomically rename staging to
`artifacts/$fingerprint`.

Generate a shell-safe environment file using `printf '%q'` with exactly these
keys:

```text
QEMU
LINUX_KERNEL_IMAGE
LINUX_INITRAMFS_IMAGE
TASK123_MODEL_IMAGE
ROOTFS_IMAGE
RTTHREAD_NORMAL_IMAGE
RTTHREAD_DROP_STATUS_IMAGE
RTTHREAD_DELAYED_SERVER_IMAGE
TASK123_ARTIFACT_FINGERPRINT
```

- [ ] **Step 4: Verify atomic cache behavior**

Run the test from Step 2. Expected: PASS, one build for identical inputs, a new
build for changed fingerprints, and no published partial entry.

- [ ] **Step 5: Commit Task 2**

```bash
git add os/axvisor/scripts/prepare_task123_artifacts.sh \
  os/axvisor/scripts/task123_artifacts.py \
  os/axvisor/scripts/test_prepare_task123_artifacts.sh \
  os/axvisor/guests/task3/configs/dependencies.lock
git commit -m "feat(axvisor): cache task123 guest artifacts"
```

### Task 3: Wire One-Click And Standalone Runner Reuse

**Files:**
- Modify: `os/axvisor/scripts/reproduce_task123.sh`
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/test_reproduce_task123.sh`
- Modify: `os/axvisor/scripts/test_task123_runner_lifecycle.sh`

- [ ] **Step 1: Write failing integration contracts**

Extend the reproducer fake tools to record preparer and runner environments.
For quick mode assert one preparer invocation followed by three runner calls;
for full mode assert one preparer invocation followed by eight runner calls.
Every call must receive identical paths for all seven artifact variables.

For standalone `run_task123.sh`, unset one artifact variable and assert it
invokes the preparer once, loads the generated environment, and still launches
exactly one QEMU. When all artifact variables are supplied, assert the preparer
is never invoked.

- [ ] **Step 2: Run integration contracts and verify RED**

Run:

```bash
bash os/axvisor/scripts/test_reproduce_task123.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
```

Expected: FAIL because preparation still occurs separately inside each runner.

- [ ] **Step 3: Prepare once in the reproducer**

Add `--cache-dir DIR`, defaulting repository-relatively to
`$ROOT/tmp/task123-cache`. Before selecting quick/full, invoke the preparer once
and stream it through `tee -a "$REPRODUCTION_LOG"`. Source only the generated
file owned by the current user after checking it is a regular, non-world-
writable file, then export the exact allowlisted keys.

Record each artifact's origin, path and hash in `reproduction-summary.txt`.
Keep `run_phase` unchanged except for passing the prepared environment to the
existing runner.

- [ ] **Step 4: Delegate standalone fallback in the runner**

Replace the runner's duplicated Linux/RT-Thread/rootfs build functions with a
single `prepare_missing_artifacts` call. Preserve direct validation when all
artifact variables are provided. Do not move VM config generation, AxVisor
build, QEMU lifecycle or result gates out of the runner.

- [ ] **Step 5: Verify runner reuse**

Run both tests from Step 2. Expected: PASS with one preparation per reproduction
profile, zero preparation for a fully explicit standalone run, and unchanged
QEMU ownership assertions.

- [ ] **Step 6: Commit Task 3**

```bash
git add os/axvisor/scripts/reproduce_task123.sh \
  os/axvisor/scripts/run_task123.sh \
  os/axvisor/scripts/test_reproduce_task123.sh \
  os/axvisor/scripts/test_task123_runner_lifecycle.sh
git commit -m "feat(axvisor): reuse task123 artifacts across phases"
```

### Task 4: Visible Automatic Download Progress

**Files:**
- Modify: `os/axvisor/guests/task3/scripts/fetch_sources.sh`
- Modify: `os/axvisor/patches/rtthread/prepare_rtthread_source.sh`
- Modify: `os/axvisor/scripts/prepare_task123_artifacts.sh`
- Modify: `os/axvisor/scripts/run_task123.sh`
- Modify: `os/axvisor/scripts/test_prepare_task123_artifacts.sh`
- Modify: `os/axvisor/scripts/test_task123_runner_lifecycle.sh`

- [ ] **Step 1: Add failing progress tests**

Use fake `git`, `curl`, `cargo`, `uv` and builders. For missing local content,
assert stdout and the reproduction log contain:

```text
DOWNLOAD name=rt-thread url=https://github.com/RT-Thread/rt-thread.git destination=$tmp/cache/sources/rt-thread
DOWNLOAD name=buildroot url=https://gitlab.com/buildroot.org/buildroot.git destination=$tmp/cache/sources/buildroot
DOWNLOAD name=rootfs url=cargo:xtask-image-pull destination=$tmp/cache/rootfs
```

Assert recorded Git arguments contain `fetch --progress` and do not contain
`--quiet`. For a complete local cache, configure every fake network command to
exit 97 and assert the preparer still succeeds without a `DOWNLOAD` line.

- [ ] **Step 2: Run progress tests and verify RED**

Run:

```bash
bash os/axvisor/scripts/test_prepare_task123_artifacts.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
```

Expected: FAIL because Git is quiet and download operations are not identified.

- [ ] **Step 3: Implement progress output**

Before external network operations, print the exact `DOWNLOAD` line through the
same terminal/log tee used by the reproducer. In both Git scripts replace quiet
fetches with:

```bash
git -C "$destination" fetch --progress --depth=1 --filter=blob:none \
  origin "$commit"
```

When the Git URL is a local filesystem path, print `LOCAL_SOURCE` instead of
`DOWNLOAD`. Keep curl's progress meter enabled and stream Buildroot, Cargo,
uv/SCons output. Ensure status comes from the producer under `set -o pipefail`,
not from `tee`.

- [ ] **Step 4: Verify online and offline progress contracts**

Run the tests from Step 2. Expected: PASS; fallback displays progress and local
cache resolution invokes no fake network tool.

- [ ] **Step 5: Commit Task 4**

```bash
git add os/axvisor/guests/task3/scripts/fetch_sources.sh \
  os/axvisor/patches/rtthread/prepare_rtthread_source.sh \
  os/axvisor/scripts/prepare_task123_artifacts.sh \
  os/axvisor/scripts/run_task123.sh \
  os/axvisor/scripts/test_prepare_task123_artifacts.sh \
  os/axvisor/scripts/test_task123_runner_lifecycle.sh
git commit -m "fix(axvisor): show task123 download progress"
```

### Task 5: Documentation And End-To-End Verification

**Files:**
- Modify: `docs/docs/build/axvisor/task123-reproduction-cn.md`
- Modify: `os/axvisor/scripts/test_task123_docs_contract.sh`
- Test: all Task 1/2/3 contract scripts

- [ ] **Step 1: Add failing documentation requirements**

Require the Chinese guide to contain the resolution order, cache directory,
`TASK123_CACHE_DIR`, `DOWNLOAD`, `LOCAL_SOURCE`, atomic publication, no
hardcoded paths, and the distinction between host prerequisites and managed
artifacts. Require executable preparer/resolver files in the docs contract.

- [ ] **Step 2: Run docs contract and verify RED**

Run:

```bash
bash os/axvisor/scripts/test_task123_docs_contract.sh
```

Expected: FAIL on the newly required cache documentation.

- [ ] **Step 3: Update the Chinese reproduction guide**

Document the zero-network local path, automatic fallback, live progress,
`--cache-dir`, cache fingerprint invalidation, safe cache removal guidance, and
how Docker mounts the same cache while host timing remains authoritative.

- [ ] **Step 4: Run focused verification**

Run:

```bash
bash -n \
  os/axvisor/scripts/prepare_task123_artifacts.sh \
  os/axvisor/scripts/reproduce_task123.sh \
  os/axvisor/scripts/run_task123.sh
python3 -m py_compile os/axvisor/scripts/task123_artifacts.py
bash os/axvisor/scripts/test_prepare_task123_artifacts.sh
bash os/axvisor/scripts/test_reproduce_task123.sh
bash os/axvisor/scripts/test_task123_runner_lifecycle.sh
bash os/axvisor/scripts/test_task123_result_gate.sh
bash os/axvisor/scripts/test_task123_docs_contract.sh
git diff --check
```

Expected: every command exits 0 and every shell contract prints PASS.

- [ ] **Step 5: Run one real local-cache smoke reproduction**

First confirm no existing Task 1/2/3 process is active. Run with network-guard
wrappers placed first in `PATH`: the Git wrapper permits local `rev-parse`,
`cat-file`, `status` and local-path fetches but exits 97 for HTTP(S) fetches;
curl exits 97 for every URL. Allow the real local cache/evidence resolver and
QEMU execution. Use a fresh output directory and verify:

```text
all artifact origins are explicit/cache/evidence/local_git
no DOWNLOAD line appears
TASK2_LINUX_END status=PASS
TASK3_LINUX_END status=PASS
TASK123_LINUX_END status=PASS
result_gate=PASS
```

Do not run the 300-second full profile until this smoke passes.

- [ ] **Step 6: Commit Task 5**

```bash
git add docs/docs/build/axvisor/task123-reproduction-cn.md \
  os/axvisor/scripts/test_task123_docs_contract.sh
git commit -m "docs(axvisor): document local-first task123 reproduction"
```

- [ ] **Step 7: Final branch audit**

Run:

```bash
git status --short --branch
git log --oneline -6
```

Expected: only intentionally retained pre-plan changes remain uncommitted, and
the five implementation commits are present in task order.
