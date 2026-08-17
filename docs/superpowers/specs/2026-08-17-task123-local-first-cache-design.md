# Task 1/2/3 Local-First Artifact Cache Design

## Goal

Make `reproduce_task123.sh` reuse verified local inputs and build outputs before
accessing the network. If required content is absent, the script may download
it automatically, but it must show the source URL, destination, and live
progress. No machine-specific absolute path may appear in implementation or
configuration defaults.

## Scope

This change covers artifact resolution, source/download caching, build-output
reuse across quick/full phases, progress reporting, integrity checks, and
failure cleanup. It does not turn QEMU or cross-compilers into project-managed
downloads. Host tools remain prerequisites resolved from an explicit variable
or `PATH`.

## Resolution Order

Each input is resolved independently in this strict order:

1. An explicit environment variable supplied by the caller.
2. A valid entry in the shared Task 1/2/3 cache.
3. A path recorded by an accepted local evidence manifest.
4. A newly downloaded or built artifact.

Explicit inputs fail closed: a missing file or hash mismatch is an error and
must not silently fall through. Cache and evidence candidates are reusable only
after their recorded SHA-256 matches the current file. Evidence discovery is
repository-relative and parses existing `manifest.txt` files; it must not
contain or synthesize workstation-specific paths.

For RT-Thread source, the resolver may inspect Git repositories below the
repository's `tmp` directory and accept one only if its object database contains
the pinned commit and the required source paths. The checkout may be dirty
because it is used only as a read-only Git object source; uncommitted working
tree content is never copied into the build.

## Cache Layout

The default cache is repository-relative at `tmp/task123-cache` and can be
overridden with `TASK123_CACHE_DIR`. Its logical layout is:

```text
task123-cache/
  locks/
  sources/
  downloads/
  artifacts/<fingerprint>/
    linux/Image
    linux/rootfs.cpio
    rtthread/normal.bin
    rtthread/drop-status.bin
    rtthread/delayed-server.bin
    model/model_weights.h
    manifest.txt
  rootfs/
    rootfs.img
    manifest.txt
```

The fingerprint includes pinned upstream commits, hashes of relevant AxVisor
patches, guest sources, configs and build scripts, and the compiler identities
that affect generated binaries. A source, patch, config, or compiler change
therefore selects a new cache entry rather than silently reusing stale output.

Cache writes use an advisory lock and a staging directory under the cache.
Artifacts and their manifest are published by atomic rename only after every
required file is nonempty and its hash has been recorded. Failed or interrupted
work is never treated as a valid cache entry.

## Execution Flow

The one-click reproducer resolves or prepares the complete artifact set once
before starting a test profile. It then passes immutable absolute paths through
the existing runner environment for every phase. Quick and full profiles thus
reuse the same Linux, RT-Thread and rootfs artifacts instead of rebuilding them
for each `run_task123.sh` invocation.

The existing runner remains responsible for VM config generation, AxVisor
build, QEMU lifecycle, marker collection and result gates. Artifact preparation
is isolated from test execution so a QEMU failure cannot corrupt the shared
cache.

## Download And Progress Policy

Network access occurs only after local resolution fails. Before each network
operation, the terminal and `reproduction.log` receive a line containing:

```text
DOWNLOAD name=<name> url=<url> destination=<path>
```

Git fetches use `--progress` and are not quiet. Curl retains its progress meter
and reports retries. Buildroot, Cargo, uv and SCons output is streamed live with
`tee` while remaining in the per-run logs. Long local builds continue to emit
the existing `PHASE` and `STEP` markers. Download completion is followed by a
SHA-256 or pinned-commit verification marker.

Docker and host runs may share the same mounted cache. Realtime execution and
its authority remain on the host; cache sharing does not make container timing
results authoritative.

## Failure Behavior

- Missing or invalid explicit input: stop immediately.
- Invalid cache/evidence candidate: record the rejection and continue resolving.
- Download, checkout, build, or integrity failure: stop without publishing the
  staging directory.
- Concurrent preparation: wait on the cache lock and recheck after acquiring it.
- Test phase failure: preserve existing fail-closed runner behavior; cache
  contents remain immutable.

The resolver records the selected origin (`explicit`, `cache`, `evidence`, or
`download`) and final hash for every artifact in the reproduction summary.

## Verification

Automated tests must prove:

- a complete valid local evidence/cache set performs no Git, curl, Cargo image
  pull, or package-index network operation;
- explicit inputs take precedence and invalid explicit inputs fail closed;
- cache entries are invalidated when a relevant source/config/compiler
  fingerprint changes;
- normal, drop-status and delayed-server RT-Thread images are built once and
  reused by all quick/full phases;
- missing local content triggers visible `DOWNLOAD` and live progress output;
- interrupted or malformed staging content is never published;
- all runner lifecycle, result-gate and evidence archive tests continue to pass;
- implementation and defaults contain no workstation-specific absolute paths.
