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
renamed_inventory="$FIXTURE_ROOT/renamed-inventory.tsv"

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

shared_evidence='task12 shared evidence content'

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
    "$task12_source/docs/docs/build/axvisor/unrelated.log" \
    'unrelated log without a migration marker'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/_category_.json" \
    '{"label":"generated"}'
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
    docs/docs/build/axvisor/unrelated.log \
    docs/docs/build/axvisor/_category_.json \
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
    "$task123_source/docs/docs/build/axvisor/task123-shared-evidence.log" \
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
    "$task123_source/docs/docs/build/axvisor/task123-shared-evidence.log" \
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
        docs/docs/build/axvisor/task123-shared-evidence.log \
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
[[ "$selected_count" == 9 ]] ||
    fail "expected 9 selected inventory entries, got $selected_count"

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
assert_excluded docs/docs/build/axvisor/_category_.json
assert_excluded docs/docs/build/axvisor/unrelated.log
assert_excluded apps/demo/validation/baseline.txt

bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "renamed-source=$task123_source" \
    --output "$renamed_inventory"

task123_classification="$(awk -F '\t' \
    '$1 == "task123-source" && $6 == "docs/docs/build/axvisor/task123-shared-evidence.log" {
        print $7 "\t" $8
    }' "$inventory")"
renamed_classification="$(awk -F '\t' \
    '$1 == "renamed-source" && $6 == "docs/docs/build/axvisor/task123-shared-evidence.log" {
        print $7 "\t" $8
    }' "$renamed_inventory")"
[[ -n "$task123_classification" && "$task123_classification" == "$renamed_classification" ]] ||
    fail 'classification depends on source name'

output_target="$FIXTURE_ROOT/output-target.tsv"
output_file_link="$FIXTURE_ROOT/output-file-link.tsv"
printf '%s\n' 'do not overwrite' > "$output_target"
ln -s "$output_target" "$output_file_link"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "task12-source=$task12_source" \
    --output "$output_file_link" \
    > "$FIXTURE_ROOT/output-file-link.stdout" 2> "$FIXTURE_ROOT/output-file-link.stderr"; then
    fail 'inventory accepted a symlink output file'
fi
grep -Fq 'output file is symlink' "$FIXTURE_ROOT/output-file-link.stderr" ||
    fail 'symlink output file failure did not identify the output'
[[ "$(<"$output_target")" == 'do not overwrite' ]] ||
    fail 'symlink output target was modified'

output_parent="$FIXTURE_ROOT/output-parent"
output_parent_link="$FIXTURE_ROOT/output-parent-link"
mkdir -p -- "$output_parent"
ln -s "$output_parent" "$output_parent_link"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "task12-source=$task12_source" \
    --output "$output_parent_link/inventory.tsv" \
    > "$FIXTURE_ROOT/output-parent.stdout" 2> "$FIXTURE_ROOT/output-parent.stderr"; then
    fail 'inventory accepted a symlink output parent'
fi
grep -Fq 'output parent component is symlink' "$FIXTURE_ROOT/output-parent.stderr" ||
    fail 'symlink output parent failure did not identify the parent'
[[ ! -e "$output_parent/inventory.tsv" ]] ||
    fail 'symlink output parent target was created'

malformed_rules="$FIXTURE_ROOT/malformed-rules.tsv"
printf '%s\n' $'include\t[\ttask12\tdesign\tmalformed regex' > "$malformed_rules"
if bash "$ARCHIVER" inventory \
    --rules "$malformed_rules" \
    --source "task12-source=$task12_source" \
    --output "$FIXTURE_ROOT/malformed-inventory.tsv" \
    > "$FIXTURE_ROOT/malformed.stdout" 2> "$FIXTURE_ROOT/malformed.stderr"; then
    fail 'inventory accepted a malformed rule regex'
fi
grep -Fq 'invalid Bash regex' "$FIXTURE_ROOT/malformed.stderr" ||
    fail 'malformed regex failure was not reported'

date_inventory="$FIXTURE_ROOT/date-inventory.tsv"
invalid_then_valid="$task12_source/docs/superpowers/specs/2026-99-99-2026-08-09-date.md"
write_fixture_file "$invalid_then_valid" 'invalid date token followed by a valid date token'
touch -d '2026-08-14T12:00:00Z' "$invalid_then_valid"
invalid_only="$task12_source/docs/superpowers/specs/2026-99-99-only-invalid.md"
write_fixture_file "$invalid_only" 'only an invalid date token'
touch -d '2026-08-13T12:00:00Z' "$invalid_only"
bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "date-source=$task12_source" \
    --output "$date_inventory" \
    > "$FIXTURE_ROOT/date.stdout" 2> "$FIXTURE_ROOT/date.stderr"
awk -F '\t' \
    '$1 == "date-source" && $6 == "docs/superpowers/specs/2026-99-99-2026-08-09-date.md" {
        found = ($9 == "2026-08-09" && $10 == "filename")
    }
    END { exit found ? 0 : 1 }' "$date_inventory" ||
    fail 'valid date token after an invalid token was not selected from filename'
awk -F '\t' \
    '$1 == "date-source" && $6 == "docs/superpowers/specs/2026-99-99-only-invalid.md" {
        found = ($9 == "2026-08-13" && $10 == "filesystem_mtime")
    }
    END { exit found ? 0 : 1 }' "$date_inventory" ||
    fail 'only invalid filename date did not fall back to filesystem mtime'

ambiguous_date="$task12_source/docs/superpowers/specs/2026-08-01-2026-08-02-ambiguous.md"
write_fixture_file "$ambiguous_date" 'ambiguous dates'
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "date-source=$task12_source" \
    --output "$FIXTURE_ROOT/ambiguous-inventory.tsv" \
    > "$FIXTURE_ROOT/ambiguous.stdout" 2> "$FIXTURE_ROOT/ambiguous.stderr"; then
    fail 'inventory accepted ambiguous filename dates'
fi
grep -Fq 'ambiguous filename dates' "$FIXTURE_ROOT/ambiguous.stderr" ||
    fail 'ambiguous filename date failure was not reported'
mv -- "$ambiguous_date" "$ambiguous_date.disabled"

tab_path=$'docs/superpowers/specs/path\tname.md'
newline_path=$'docs/superpowers/specs/path\nname.md'
for odd_path in "$tab_path" "$newline_path"; do
    write_fixture_file "$task12_source/$odd_path" 'path audit fixture'
done
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "odd-path-source=$task12_source" \
    --output "$FIXTURE_ROOT/odd-path-inventory.tsv" \
    > "$FIXTURE_ROOT/odd-path.stdout" 2> "$FIXTURE_ROOT/odd-path.stderr"; then
    fail 'inventory silently accepted a TAB/newline candidate path'
fi
grep -Fq 'candidate path contains TAB/newline' "$FIXTURE_ROOT/odd-path.stderr" ||
    fail 'TAB/newline candidate path failure was not reported'

printf '%s\n' 'staged tracked change' >> "$task12_source/docs/README.md"
git -C "$task12_source" add -- docs/README.md
printf '%s\n' 'unstaged tracked change' >> \
    "$task12_source/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "dirty-source=$task12_source" \
    --output "$FIXTURE_ROOT/dirty-inventory.tsv" \
    > "$FIXTURE_ROOT/dirty.stdout" 2> "$FIXTURE_ROOT/dirty.stderr"; then
    fail 'inventory accepted tracked staged/unstaged changes'
fi
grep -Fq 'source=dirty-source' "$FIXTURE_ROOT/dirty.stderr" ||
    fail 'tracked change failure did not identify the source'
grep -Fq 'M  docs/README.md' "$FIXTURE_ROOT/dirty.stderr" ||
    fail 'tracked staged change was not listed'
grep -Fq ' M docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md' \
    "$FIXTURE_ROOT/dirty.stderr" ||
    fail 'tracked unstaged change was not listed'

echo 'PASS: archive history inventory fixture contract'
