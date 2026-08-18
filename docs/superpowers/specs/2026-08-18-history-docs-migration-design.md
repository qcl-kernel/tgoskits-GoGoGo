# Historical Documentation Migration Design

## Goal

Consolidate historical Task 1/2 and Task 1/2/3 documentation from the current
`starryos-replace` worktree and the `tgoskits` worktree into the shared
`/home/yfblock/Code/hyper-rtos/history-docs` directory. The archive is organized
first by project phase and then by document type, while preserving enough
metadata to trace every archived file back to its repository, branch, commit,
and original path.

The migration must not move active source documentation, repository entry
points, generated test baselines, source code, or unrelated user changes.

## Sources And Destination

The migration reads from two independent Git worktrees:

- `starryos-replace`, currently on `feat/starryos-task123`;
- `tgoskits`, currently on `rtthread-migration`.

The destination is outside both source repositories:

```text
/home/yfblock/Code/hyper-rtos/history-docs
```

Because a cross-repository move cannot retain Git rename history, the archive
manifest is the authoritative provenance record. Source commits are recorded
before migration begins. The migration does not modify branch topology,
remotes, or existing commits.

## Archive Layout

The archive has exactly two phase roots:

```text
history-docs/
├── INDEX.md
├── manifest.json
├── task12/
│   ├── design/
│   ├── spec/
│   ├── plan/
│   ├── report/
│   ├── result/
│   ├── evidence/
│   ├── debug/
│   └── guide/
└── task123/
    ├── design/
    ├── spec/
    ├── plan/
    ├── report/
    ├── result/
    ├── evidence/
    ├── debug/
    └── guide/
```

Files are stored below each type by inferred date, source worktree, and
original relative path:

```text
<phase>/<type>/<YYYY-MM-DD>/<source>/<original-relative-path>
```

For example:

```text
task123/report/2026-08-18/starryos-replace/docs/reports/starryos-linux-stability-comparison.md
```

Keeping the original relative path prevents same-name collisions and makes a
manifest entry reversible. Empty type or date directories are not created.

## Phase Classification

`task12` contains material whose final scope is Task 1 real-time behavior or
Task 2 guest networking and application protocol work. This includes AxVisor
real-time policy, CPU affinity, timer and interrupt work, RTOS selection and
migration, virtio-net, RT-IPC, Linux/RTOS communication, and their benchmarks.

`task123` contains material that adds Task 3 or validates the integrated three-
task system. This includes StarryOS guest replacement, AI inference and control
feedback, end-to-end Task 1/2/3 runners, full reproduction, integrated
stability tests, and cross-task comparison reports.

Classification uses content and project intent, not only directory names. A
document that covers both phases is stored in `task123` when it describes the
integrated system or was produced after Task 3 integration began. There is no
third `general` phase: ambiguous files remain in their source repository until
their phase can be established from content or Git history.

## Type Classification

Each archived file has one primary type:

- `design`: architecture and accepted design decisions;
- `spec`: detailed requirements and approved specifications;
- `plan`: implementation, migration, or verification plans;
- `report`: interpreted findings, progress reports, and comparisons;
- `result`: structured or final benchmark outputs and summaries;
- `evidence`: raw logs, captures, manifests, and supporting measurements;
- `debug`: fault investigations, traces, and root-cause notes;
- `guide`: reproduction, build, launch, and operator instructions.

The original path is used as an initial hint, but the document title and
content decide the type when names conflict. A file is archived once per source
worktree and receives exactly one phase and one type.

## Date Classification

The archive date is selected deterministically in this order:

1. an unambiguous `YYYY-MM-DD` date in the filename;
2. the latest Git commit date that changed a tracked file in that worktree;
3. the filesystem modification date for an untracked evidence file.

The selected date and its source are recorded in the manifest. Dates do not
attempt to reconstruct an undocumented project milestone from directory names.

## Migration Boundary

Historical designs, specifications, plans, reports, results, debugging notes,
reproduction guides, and raw test evidence are eligible for migration.

The following remain in their source repositories:

- `README*`, `CHANGELOG*`, `AGENTS.md`, and `CLAUDE.md`;
- source code and executable scripts, regardless of filename;
- test baselines under `apps/**/validation/*.txt` and `apps/**/golden/*.txt`;
- syscall test lists under `apps/starry/qemu/syscall-test/syscalls/*.txt`;
- current architecture references under `book/design`,
  `docs/docs/architecture`, `memory/**/docs`, and
  `virtualization/**/docs`, unless a file is explicitly a historical plan,
  report, result, or debugging record;
- generated configuration and unrelated untracked files.

In particular, the untracked logs under `tgoskits/docs/docs/build/axvisor` are
eligible only when their content is Task 1/2 or Task 1/2/3 test evidence. Their
presence must not authorize cleanup of neighboring untracked configuration or
artifacts.

## Provenance And Duplicate Handling

`manifest.json` contains one entry per archived source file with at least:

- source repository and worktree identifier;
- source branch and commit captured at migration start;
- original and archived paths;
- phase, type, date, and date source;
- tracked or untracked status;
- byte size and SHA-256 digest.

Files with identical SHA-256 digests from different worktrees remain as
separate archive entries and separate physical files. The manifest records a
shared duplicate-group digest so source provenance is never discarded by
deduplication.

`INDEX.md` provides human-readable counts and links grouped by phase, type, and
date. It also records the source revisions and explains the classification
rules. The JSON manifest remains the machine-readable source of truth.

## Migration Procedure And Failure Handling

Migration is staged to avoid partial destructive changes:

1. capture source status, branches, commits, and the complete candidate list;
2. classify candidates without changing either worktree;
3. copy candidates into a temporary archive tree and generate the manifest;
4. verify file counts, sizes, and SHA-256 digests against every source file;
5. publish the verified tree under `history-docs`;
6. remove only the exact verified source candidates;
7. repair necessary links to archived material and generate the final index;
8. repeat integrity and Git-status checks.

Any ambiguous classification, destination collision, missing source file, hash
mismatch, broken required link, or unexpected source status aborts before
source deletion. Existing user changes are preserved. A source file is removed
only after its destination file and manifest entry both pass verification.

## Link Policy

Links between archived documents are rewritten when both endpoints are moved.
Links from retained source documentation to archived historical material are
updated only when they are still meaningful; otherwise the retained document
receives a direct archive link. Links to source code remain pointed at source
locations and are reported when they cannot be made portable across the two
repositories.

The verification report distinguishes broken local links from external URLs.
No network availability is required to validate this migration.

## Verification And Acceptance Criteria

The migration is complete only when all of the following hold:

- every selected source file has exactly one manifest entry and an existing
  archive file;
- every archive digest and size matches its pre-migration source value;
- candidate counts before migration equal archived counts plus explicitly
  rejected ambiguous candidates;
- no retained `README`, `CHANGELOG`, repository instruction file, test
  baseline, source file, or active architecture reference was moved;
- existing unrelated tracked and untracked changes in `tgoskits` are unchanged;
- Markdown local links are checked and all newly broken links are either fixed
  or listed with a reason;
- `starryos-replace` and `tgoskits` Git status output contains only the intended
  historical-document removals and link updates, plus pre-existing user state;
- `INDEX.md` totals agree with `manifest.json` totals by phase and type;
- a final migration report records commands, source revisions, counts,
  duplicate groups, unresolved links, and verification results.

The migration does not claim that `history-docs` is version-controlled unless
the outer repository is separately initialized and committed. Its manifest and
hash verification provide integrity and provenance independent of that choice.
