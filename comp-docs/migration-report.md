# Historical Documentation Migration Report

## Scope

This archive contains the approved historical records from the `task12` and
`task123` stages. The original archive was inventoried and staged without
modifying its source worktrees; the later supplemental log migration deleted
only the explicitly verified untracked log paths after copying and hashing
them.

The archive was staged on 2026-08-19 from:

| Source | Branch | HEAD | Selected |
| --- | --- | --- | ---: |
| `starryos-replace` | `feat/starryos-task123` | `d7c52e8ef1941c7fcdc6cd5ca27ca58bd4698b4d` | 126 |
| `tgoskits` | `rtthread-migration` | `cbf9f8b31c4844d8cf14faf5c41e3c9df3bca3d0` | 199 |
| `tgoskits-untracked-logs` | `rtthread-migration` | `645ec0355221f9d4bd22ee995607b0761c09395e` | 68 |
| **Total** |  |  | **393** |

The `tgoskits-untracked-logs` source is a supplemental snapshot requested
after the initial archive. It contains every remaining Git-visible untracked
`.log` file under `docs/docs/build/axvisor/`; all are classified as `task12`
runtime evidence. This source name keeps its later commit provenance distinct
from the original `tgoskits` snapshot.

The machine-readable source of truth is `manifest.json`; the frozen input is
`migration-inventory.tsv`. Every selected file has a recorded source path,
phase, type, date, size, mode, and SHA-256 digest.

## Classification

| Phase | Design | Spec | Plan | Report | Result | Evidence | Debug | Guide | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `task12` | 16 | 0 | 10 | 44 | 4 | 254 | 0 | 1 | 329 |
| `task123` | 7 | 1 | 8 | 3 | 0 | 44 | 0 | 1 | 64 |
| **Total** | **23** | **1** | **18** | **47** | **4** | **298** | **0** | **2** | **393** |

There are 200 tracked and 193 untracked selected files. Sixty duplicate
groups were retained as separate entries because source provenance is more
important than deduplication.

The rules sidecar records the exact classification rules and their SHA-256.
Files not selected by those rules remain in their source worktrees. This
includes repository entry points and metadata, source code, test baselines,
active architecture references, generated configuration, and unrelated build
artifacts. The supplemental migration intentionally overrides the original
runtime-signature filter for the 68 remaining AxVisor logs at the user's
request; no other unmatched files were added.

## Integrity Verification

The following checks passed before this report was written:

- inventory classification and exclusion contract tests;
- `bash -n` for the archive script and contract test;
- `git diff --check`;
- staged archive file count, source-to-archive size checks, and SHA-256 checks;
- manifest, inventory, rules sidecar, index, and archive tree consistency;
- duplicate-group and destination collision validation;
- source worktree candidate snapshots before and after staging.

The staging implementation snapshots Git-visible tracked and untracked paths
only. It does not recursively hash ignored build output, which is outside the
migration boundary and is large in the `tgoskits` worktree. Selected files are
still hashed individually before publication and before any future deletion.

## Link Review

The archived Markdown scan found five relative links whose targets are also in
the archive. They remain byte-identical as evidence, so the new target mapping
is recorded here:

| Source document | Original target | Archive target |
| --- | --- | --- |
| `tgoskits/docs/docs/build/axvisor/rtthread-reproduction.md` | `./rtthread-realtime-report.md` | `task12/report/2026-08-18/tgoskits/docs/docs/build/axvisor/rtthread-realtime-report.md` |
| `starryos-replace/docs/docs/build/axvisor/rtos-realtime-report.md` | `./rtos-realtime-iterations.csv` | `task12/result/2026-08-07/starryos-replace/docs/docs/build/axvisor/rtos-realtime-iterations.csv` |
| `starryos-replace/docs/docs/build/axvisor/rtos-realtime-report.md` | `./rtos-realtime-iterations.png` | `task12/result/2026-08-07/starryos-replace/docs/docs/build/axvisor/rtos-realtime-iterations.png` |
| `tgoskits/docs/docs/build/axvisor/rtos-realtime-report.md` | `./rtos-realtime-iterations.csv` | `task12/result/2026-08-07/tgoskits/docs/docs/build/axvisor/rtos-realtime-iterations.csv` |
| `tgoskits/docs/docs/build/axvisor/rtos-realtime-report.md` | `./rtos-realtime-iterations.png` | `task12/result/2026-08-07/tgoskits/docs/docs/build/axvisor/rtos-realtime-iterations.png` |

No archived Markdown relative link was unresolved. Four links from retained
`docs/spin-migration-tracking.md` files continue to point to retained
architecture/build documents and do not require migration-link changes.

## Deletion Result

On 2026-08-19, the exact frozen inventory was passed to the archive `delete`
command. It verified the source branch, HEAD, tracked/untracked candidate set,
selected-file identity and hash, and archive identity and hash. Each selected
source was moved into a same-filesystem quarantine before the final archive and
source-tree checks; the quarantine was cleaned only after those checks passed.

Result: `delete: removed only verified inventory files from source worktrees`.

The subsequent 68-file supplemental migration copied each untracked log,
verified its size and SHA-256 digest at the archive destination, regenerated
the inventory, manifest, and index, and then removed the exact source path.

Post-delete verification passed:

- `manifest.json` contains 393 entries and archive verification succeeds;
- all original 325 selected paths and all 68 supplemental log paths are absent;
- `README*`, repository metadata, test baselines, active architecture
  references, and the `tgoskits/configs/` sentinel remain present;
- `tgoskits` has no remaining Git-visible untracked files;
- the archived source revisions remain recorded as
  `d7c52e8ef1941c7fcdc6cd5ca27ca58bd4698b4d` and
  `cbf9f8b31c4844d8cf14faf5c41e3c9df3bca3d0`;
- the supplemental untracked-log snapshot records
  `645ec0355221f9d4bd22ee995607b0761c09395e`;
- the source deletion commits are `5662e9dec5f0fd50ea45173dd3a7e2acb5048308`
  on `feat/starryos-task123` and
  `2490b969e57c04b4470e38a54ad2a4347b6bb44b` on `rtthread-migration`;
- the follow-up archive-tool verification fix is committed as
  `5f68ae9d1` on `feat/starryos-task123`; it does not change the archived
  source provenance recorded above;
- `git diff --check` passes in both source worktrees.

The archive remains outside the source Git repositories and must be versioned
separately if a committed history of the archive is required.
