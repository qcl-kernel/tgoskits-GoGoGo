#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVER="$ROOT/scripts/repo/archive-history-docs.sh"
RULES="$ROOT/scripts/repo/history-docs-rules.tsv"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/archive-history-contract.XXXXXX")"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

FIXED_GIT_DATE="2026-08-17T12:00:00Z"
task12_source="$(mktemp -d "$FIXTURE_ROOT/task12-source.XXXXXX")"
task123_source="$(mktemp -d "$FIXTURE_ROOT/task123-source.XXXXXX")"
inventory="$FIXTURE_ROOT/inventory.tsv"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_fixture_file() {
    local path="$1"
    local contents="$2"
    mkdir -p -- "$(dirname -- "$path")"
    printf '%s\n' "$contents" > "$path"
}

init_fixture_repo() {
    local repo="$1"
    git init -q --initial-branch=main "$repo"
    git -C "$repo" config user.name archive-contract-test
    git -C "$repo" config user.email archive-contract-test@example.invalid
}

commit_fixture_repo() {
    local repo="$1"
    shift
    git -C "$repo" add -- "$@"
    env GIT_AUTHOR_DATE="$FIXED_GIT_DATE" \
        GIT_COMMITTER_DATE="$FIXED_GIT_DATE" \
        git -C "$repo" commit -qm fixture
}

init_fixture_repo "$task12_source"
init_fixture_repo "$task123_source"

shared_evidence='shared evidence content'

write_fixture_file \
    "$task12_source/docs/README.md" \
    'repository entry point'
write_fixture_file \
    "$task12_source/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md" \
    'rt-ipc design'
write_fixture_file \
    "$task12_source/docs/superpowers/plans/2026-08-15-task1-task2-implementation.md" \
    'task1 task2 plan'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/task1-2026-08-15-run.log" \
    'task1 evidence log'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/shared-evidence.log" \
    "$shared_evidence"
write_fixture_file \
    "$task12_source/docs/docs/architecture/axvisor/overview.md" \
    'active architecture reference'
write_fixture_file \
    "$task12_source/apps/demo/validation/baseline.txt" \
    'validation baseline'

commit_fixture_repo "$task12_source" \
    docs/README.md \
    docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md \
    docs/superpowers/plans/2026-08-15-task1-task2-implementation.md \
    docs/docs/build/axvisor/shared-evidence.log \
    docs/docs/architecture/axvisor/overview.md \
    apps/demo/validation/baseline.txt
touch -d '2026-08-15T12:00:00Z' \
    "$task12_source/docs/docs/build/axvisor/task1-2026-08-15-run.log"

write_fixture_file \
    "$task123_source/docs/reports/starryos-linux-stability-comparison.md" \
    'integrated stability report'
write_fixture_file \
    "$task123_source/docs/superpowers/plans/2026-08-18-task123-native-runner.md" \
    'native task123 runner plan'
write_fixture_file \
    "$task123_source/docs/docs/build/axvisor/shared-evidence.log" \
    "$shared_evidence"
write_fixture_file \
    "$task123_source/os/axvisor/guests/task3/docs/results/task3-report.md" \
    'task3 report'
write_fixture_file \
    "$task123_source/os/axvisor/guests/task3/docs/results/evidence/normal/summary.json" \
    '{"result":"pass"}'

commit_fixture_repo "$task123_source" .

diff -u \
    "$task12_source/docs/docs/build/axvisor/shared-evidence.log" \
    "$task123_source/docs/docs/build/axvisor/shared-evidence.log" \
    || fail 'shared evidence fixtures differ'

if ! bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "task12-source=$task12_source" \
    --source "task123-source=$task123_source" \
    --output "$inventory"; then
    echo "archive-history-docs.sh inventory is unavailable or failed" >&2
    exit 1
fi

[[ -s "$inventory" ]] || fail 'inventory.tsv was not created'

header_file="$FIXTURE_ROOT/header.tsv"
printf '%s\n' \
    'source	source_root	branch	commit	tracked	original_path	phase	type	date	date_source	size	sha256	archived_path' \
    > "$header_file"
head -n 1 "$inventory" | diff -u "$header_file" - \
    || fail 'inventory header does not match the contract'

actual_projection="$FIXTURE_ROOT/actual.tsv"
expected_projection="$FIXTURE_ROOT/expected.tsv"

awk -F '\t' 'NR > 1 && NF {
    print $1 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $5
}' "$inventory" | LC_ALL=C sort > "$actual_projection"

{
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task12-source \
        docs/docs/build/axvisor/shared-evidence.log \
        task12 evidence 2026-08-17 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task12-source \
        docs/docs/build/axvisor/task1-2026-08-15-run.log \
        task12 evidence 2026-08-15 false
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task12-source \
        docs/superpowers/plans/2026-08-15-task1-task2-implementation.md \
        task12 plan 2026-08-15 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task12-source \
        docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md \
        task12 design 2026-08-11 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        docs/docs/build/axvisor/shared-evidence.log \
        task123 evidence 2026-08-17 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        docs/reports/starryos-linux-stability-comparison.md \
        task123 report 2026-08-17 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        docs/superpowers/plans/2026-08-18-task123-native-runner.md \
        task123 plan 2026-08-18 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        os/axvisor/guests/task3/docs/results/evidence/normal/summary.json \
        task123 evidence 2026-08-17 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        os/axvisor/guests/task3/docs/results/task3-report.md \
        task123 report 2026-08-17 true
} | LC_ALL=C sort > "$expected_projection"

diff -u "$expected_projection" "$actual_projection" \
    || fail 'inventory phase/type/date/tracked mappings differ'

selected_count="$(awk -F '\t' 'NR > 1 && NF { count++ } END { print count + 0 }' "$inventory")"
[[ "$selected_count" == 8 ]] ||
    fail "expected 8 selected inventory entries, got $selected_count"

assert_excluded() {
    local path="$1"
    if awk -F '\t' -v expected="$path" \
        'NR > 1 && $6 == expected { found = 1 }
         END { exit found ? 0 : 1 }' "$inventory"; then
        fail "excluded path appears in inventory: $path"
    fi
}

assert_excluded docs/README.md
assert_excluded docs/docs/architecture/axvisor/overview.md
assert_excluded apps/demo/validation/baseline.txt

echo 'PASS: archive history inventory fixture contract'
