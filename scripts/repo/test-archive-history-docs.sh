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

shared_evidence='qemu-system-aarch64: shared evidence content'

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
    'RTBENCH_RUN task1 evidence log'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/task12-shared-evidence.log" \
    "$shared_evidence"
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/unrelated.log" \
    'unrelated log without a migration marker'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/network-maintenance.log" \
    'network guest timer maintenance notes'
write_fixture_file \
    "$task12_source/docs/docs/build/axvisor/task12-pseudo-marker.log" \
    'notes mention RTBENCH_RUN and TASK1_START in prose'
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
    docs/docs/build/axvisor/task12-shared-evidence.log \
    docs/docs/build/axvisor/unrelated.log \
    docs/docs/build/axvisor/network-maintenance.log \
    docs/docs/build/axvisor/task12-pseudo-marker.log \
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
    "$task123_source/docs/docs/build/axvisor/task123-test-report.md" \
    'task123 test report'
write_fixture_file \
    "$task123_source/docs/docs/build/axvisor/task123-reproduction-cn.md" \
    'task123 reproduction guide'
write_fixture_file \
    "$task123_source/docs/docs/build/axvisor/task123-unrelated.log" \
    'task123 unrelated log without an explicit rule'
write_fixture_file \
    "$task123_source/os/axvisor/guests/task3/docs/results/task3-report.md" \
    'task3 report'
write_fixture_file \
    "$task123_source/os/axvisor/guests/task3/docs/results/evidence/normal/summary.json" \
    '{"result":"pass"}'

commit_fixture_repo "$task123_source" .

diff -u \
    "$task12_source/docs/docs/build/axvisor/task12-shared-evidence.log" \
    "$task123_source/docs/docs/build/axvisor/task123-shared-evidence.log" \
    || fail 'shared evidence fixtures differ'

if ! bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "task12-source=$task12_source" \
    --source "task123-source=$task123_source" \
    --output "$inventory" \
    > "$FIXTURE_ROOT/initial.stdout" 2> "$FIXTURE_ROOT/initial.stderr"; then
    echo "archive-history-docs.sh inventory is unavailable or failed" >&2
    exit 1
fi
grep -Fq 'inventory: source=task12-source selected=4 excluded=4 unmatched=3 skipped=0' \
    "$FIXTURE_ROOT/initial.stderr" ||
    fail 'task12 unsigned or explanatory build logs were not reported as unmatched'
grep -Fq 'inventory: source=task123-source selected=6 excluded=0 unmatched=2 skipped=0' \
    "$FIXTURE_ROOT/initial.stderr" ||
    fail 'task123 unrelated build logs were not reported as unmatched'

[[ -s "$inventory" ]] || fail 'inventory.tsv was not created'
rules_sidecar="$inventory.rules.sha256"
[[ -s "$rules_sidecar" ]] || fail 'rules sidecar was not created'
rules_digest="$(sha256sum -b -- "$RULES")"
rules_digest="${rules_digest%% *}"
grep -Fq $'rules_path\t' "$rules_sidecar" ||
    fail 'rules sidecar did not record the rules path'
grep -Fq 'rules_sha256'$'\t'"$rules_digest" "$rules_sidecar" ||
    fail 'rules sidecar did not record the rules digest'
grep -Fq $'rules_commit\t' "$rules_sidecar" ||
    fail 'rules sidecar did not record rules commit provenance'

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
        docs/docs/build/axvisor/task12-shared-evidence.log \
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
        docs/docs/build/axvisor/task123-reproduction-cn.md \
        task123 guide 2026-08-17 true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        task123-source \
        docs/docs/build/axvisor/task123-test-report.md \
        task123 report 2026-08-17 true
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
[[ "$selected_count" == 10 ]] ||
    fail "expected 10 selected inventory entries, got $selected_count"

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
assert_excluded docs/docs/build/axvisor/network-maintenance.log
assert_excluded docs/docs/build/axvisor/task12-pseudo-marker.log
assert_excluded docs/docs/build/axvisor/task123-shared-evidence.log
assert_excluded docs/docs/build/axvisor/task123-unrelated.log
assert_excluded apps/demo/validation/baseline.txt

bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "renamed-source=$task123_source" \
    --output "$renamed_inventory"

task123_classification="$(awk -F '\t' \
    '$1 == "task123-source" && $6 == "docs/docs/build/axvisor/task123-test-report.md" {
        print $7 "\t" $8
    }' "$inventory")"
renamed_classification="$(awk -F '\t' \
    '$1 == "renamed-source" && $6 == "docs/docs/build/axvisor/task123-test-report.md" {
        print $7 "\t" $8
    }' "$renamed_inventory")"
[[ -n "$task123_classification" && "$task123_classification" == "$renamed_classification" ]] ||
    fail 'classification depends on source name'

inside_source="$(mktemp -d "$FIXTURE_ROOT/inside-source.XXXXXX")"
inside_output="$inside_source/docs/tracked-output.tsv"
init_fixture_repo "$inside_source"
write_fixture_file "$inside_output" 'tracked source content'
commit_fixture_repo "$inside_source" docs/tracked-output.tsv
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "inside-source=$inside_source" \
    --output "$inside_output" \
    > "$FIXTURE_ROOT/inside-output.stdout" 2> "$FIXTURE_ROOT/inside-output.stderr"; then
    fail 'inventory accepted an output file inside a source root'
fi
grep -Fq 'output must be outside source root' "$FIXTURE_ROOT/inside-output.stderr" ||
    fail 'inside-source output failure was not reported'
[[ "$(<"$inside_output")" == 'tracked source content' ]] ||
    fail 'tracked source output file was modified'
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "inside-source=$inside_source" \
    --output "$inside_source" \
    > "$FIXTURE_ROOT/equal-output.stdout" 2> "$FIXTURE_ROOT/equal-output.stderr"; then
    fail 'inventory accepted a source root as output'
fi
grep -Fq 'output must be outside source root' "$FIXTURE_ROOT/equal-output.stderr" ||
    fail 'equal-source output failure was not reported'

flag_path='docs/reports/starryos-linux-stability-comparison.md'
git -C "$task123_source" update-index --assume-unchanged "$flag_path"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "assume-source=$task123_source" \
    --output "$FIXTURE_ROOT/assume-inventory.tsv" \
    > "$FIXTURE_ROOT/assume.stdout" 2> "$FIXTURE_ROOT/assume.stderr"; then
    fail 'inventory accepted an assume-unchanged tracked path'
fi
grep -Fq 'assume-unchanged' "$FIXTURE_ROOT/assume.stderr" ||
    fail 'assume-unchanged failure was not reported'
grep -Fq "$flag_path" "$FIXTURE_ROOT/assume.stderr" ||
    fail 'assume-unchanged path was not listed'
git -C "$task123_source" update-index --no-assume-unchanged "$flag_path"

git -C "$task123_source" update-index --skip-worktree "$flag_path"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "skip-source=$task123_source" \
    --output "$FIXTURE_ROOT/skip-inventory.tsv" \
    > "$FIXTURE_ROOT/skip.stdout" 2> "$FIXTURE_ROOT/skip.stderr"; then
    fail 'inventory accepted a skip-worktree tracked path'
fi
grep -Fq 'skip-worktree' "$FIXTURE_ROOT/skip.stderr" ||
    fail 'skip-worktree failure was not reported'
grep -Fq "$flag_path" "$FIXTURE_ROOT/skip.stderr" ||
    fail 'skip-worktree path was not listed'
git -C "$task123_source" update-index --no-skip-worktree "$flag_path"

archive_rules="$FIXTURE_ROOT/archive-rules.tsv"
cp -- "$RULES" "$archive_rules"
printf '%s\n' $'include\t^docs/docs/build/axvisor/task123-shared-evidence\\.log$\ttask123\tevidence\tduplicate evidence fixture' \
    >> "$archive_rules"

make_archive_fixture() {
    local name="$1"
    local fixture_root="$FIXTURE_ROOT/$name"
    local fixture_inventory="$fixture_root/inventory.tsv"
    local ignored_symlink

    mkdir -p -- "$fixture_root"
    cp -a -- "$task12_source" "$fixture_root/task12-source"
    cp -a -- "$task123_source" "$fixture_root/task123-source"
    write_fixture_file \
        "$fixture_root/task123-source/docs/reports/URI 中文 #?% path.md" \
        'URI encoding fixture'
    commit_fixture_repo "$fixture_root/task123-source" \
        'docs/reports/URI 中文 #?% path.md'
    write_fixture_file \
        "$fixture_root/task12-source/ignored-archive-sentinel.txt" \
        'ignored source sentinel'
    chmod 0600 -- \
        "$fixture_root/task12-source/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md"
    ln -s -- docs/README.md "$fixture_root/task12-source/tracked-readme.link"
    ln -s -- missing-tracked-target "$fixture_root/task12-source/tracked-dangling.link"
    ln -s -- docs/README.md "$fixture_root/task12-source/ignored-readme.link"
    ln -s -- missing-ignored-target "$fixture_root/task12-source/ignored-dangling.link"
    printf '%s\n' '/ignored-archive-sentinel.txt' \
        '/ignored-readme.link' \
        '/ignored-dangling.link' \
        >> "$fixture_root/task12-source/.git/info/exclude"
    commit_fixture_repo "$fixture_root/task12-source" \
        tracked-readme.link \
        tracked-dangling.link
    git -C "$fixture_root/task12-source" ls-files --error-unmatch -- \
        tracked-readme.link tracked-dangling.link > /dev/null ||
        fail "archive fixture tracked symlink setup failed: $name"
    for ignored_symlink in ignored-readme.link ignored-dangling.link; do
        git -C "$fixture_root/task12-source" check-ignore -q -- "$ignored_symlink" ||
            fail "archive fixture ignored symlink setup failed: $name/$ignored_symlink"
    done
    bash "$ARCHIVER" inventory \
        --rules "$archive_rules" \
        --source "task12-source=$fixture_root/task12-source" \
        --source "task123-source=$fixture_root/task123-source" \
        --output "$fixture_inventory" \
        > "$fixture_root/inventory.stdout" \
        2> "$fixture_root/inventory.stderr" ||
        fail "archive fixture inventory failed: $name"
    assert_inventory_source_roots "$fixture_root" "$fixture_inventory"
    printf '%s\n' "$fixture_root"
}

assert_inventory_sources_exist() {
    local inventory_file="$1"
    local fixture_root="$2"
    local source source_root branch commit tracked original_path phase type
    local date date_source size sha256 archived_path
    local source_path

    while IFS=$'\t' read -r source source_root branch commit tracked original_path \
        phase type date date_source size sha256 archived_path; do
        [[ -n "$source" ]] || continue
        source_path="$(resolve_inventory_source_path \
            "$fixture_root" "$source_root" "$original_path" "inventory/$source")"
        [[ -f "$source_path" && ! -L "$source_path" ]] ||
            fail "inventory source file is not a regular file: $source_path"
    done < <(tail -n +2 "$inventory_file")
}

assert_inventory_targets_exist() {
    local inventory_file="$1"
    local destination="$2"
    local source source_root branch commit tracked original_path phase type
    local date date_source size sha256 archived_path
    local target_path

    while IFS=$'\t' read -r source source_root branch commit tracked original_path \
        phase type date date_source size sha256 archived_path; do
        [[ -n "$source" ]] || continue
        target_path="$(resolve_inventory_archive_path \
            "$destination" "$archived_path" "inventory/$source")"
        [[ -f "$target_path" && ! -L "$target_path" ]] ||
            fail "inventory target file is not a regular file: $target_path"
    done < <(tail -n +2 "$inventory_file")
}

assert_safe_relative_path() {
    local path="$1"
    local label="$2"

    [[ -n "$path" && "$path" != /* ]] ||
        fail "$label is absolute or empty: $path"
    case "/$path/" in
        */../*) fail "$label contains parent traversal: $path" ;;
    esac
}

resolve_inventory_source_path() {
    local fixture_root="$1"
    local source_root="$2"
    local original_path="$3"
    local label="$4"
    local expected_root root_real source_path source_real

    case "$source_root" in
        "$fixture_root/task12-source") expected_root="$fixture_root/task12-source" ;;
        "$fixture_root/task123-source") expected_root="$fixture_root/task123-source" ;;
        *) fail "$label source_root is outside fixture: $source_root" ;;
    esac
    root_real="$(realpath -e -- "$source_root")" ||
        fail "$label source_root does not exist: $source_root"
    expected_root="$(realpath -e -- "$expected_root")" ||
        fail "$label fixture source does not exist: $expected_root"
    [[ "$root_real" == "$expected_root" ]] ||
        fail "$label source_root does not match fixture source: $source_root"
    assert_safe_relative_path "$original_path" "$label original_path"
    source_path="$root_real/$original_path"
    source_real="$(realpath -e -- "$source_path")" ||
        fail "$label source path does not exist: $source_path"
    [[ "$source_real" == "$root_real/"* ]] ||
        fail "$label source path escapes fixture source: $original_path"
    printf '%s\n' "$source_real"
}

build_inventory_source_paths() {
    local fixture_root="$1"
    local inventory_file="$2"
    local output_file="$3"
    local source source_root branch commit tracked original_path
    local source_path

    : > "$output_file"
    while IFS=$'\t' read -r source source_root branch commit tracked original_path _; do
        [[ -n "$source" ]] || continue
        source_path="$(resolve_inventory_source_path \
            "$fixture_root" "$source_root" "$original_path" "inventory/$source")"
        [[ -f "$source_path" && ! -L "$source_path" ]] ||
            fail "inventory source is not a regular file: $source_path"
        printf '%s\0' "$source_path" >> "$output_file"
    done < <(tail -n +2 "$inventory_file")
}

resolve_inventory_archive_path() {
    local destination="$1"
    local archived_path="$2"
    local label="$3"
    local destination_real target_real

    assert_safe_relative_path "$archived_path" "$label archived_path"
    destination_real="$(realpath -e -- "$destination")" ||
        fail "$label archive destination does not exist: $destination"
    target_real="$(realpath -m -- "$destination_real/$archived_path")" ||
        fail "$label archived target cannot be resolved: $archived_path"
    [[ "$target_real" == "$destination_real/"* ]] ||
        fail "$label archived target escapes destination: $archived_path"
    printf '%s\n' "$target_real"
}

assert_inventory_source_roots() {
    local fixture_root="$1"
    local inventory_file="$2"
    local source source_root branch commit tracked original_path
    local expected_root actual_root

    while IFS=$'\t' read -r source source_root branch commit tracked original_path _; do
        [[ -n "$source" ]] || continue
        case "$source" in
            task12-source) expected_root="$fixture_root/task12-source" ;;
            task123-source) expected_root="$fixture_root/task123-source" ;;
            *) fail "inventory has unexpected source name: $source" ;;
        esac
        actual_root="$(realpath -e -- "$source_root")" ||
            fail "inventory source_root does not exist: $source_root"
        expected_root="$(realpath -e -- "$expected_root")" ||
            fail "fixture source does not exist: $expected_root"
        [[ "$actual_root" == "$expected_root" ]] ||
            fail "inventory source_root does not match fixture: $source_root"
    done < <(tail -n +2 "$inventory_file")
}

snapshot_tree() {
    local tree_root="$1"
    local output_file="$2"
    local exclude_git="$3"
    local relative_path tree_path digest link_target

    (
        cd "$tree_root"
        if ((exclude_git)); then
            find -P . ! -path './.git' ! -path './.git/*' -mindepth 1 \
                \( -type d -o -type f -o -type l \) -print0
        else
            find -P . -mindepth 1 \( -type d -o -type f -o -type l \) -print0
        fi
    ) | LC_ALL=C sort -z | while IFS= read -r -d '' relative_path; do
        relative_path="${relative_path#./}"
        tree_path="$tree_root/$relative_path"
        if [[ -L "$tree_path" ]]; then
            link_target="$(readlink -- "$tree_path")"
            printf 'l\t%s\t%s\t-\0' "$tree_path" "$link_target"
        elif [[ -d "$tree_path" ]]; then
            printf 'd\t%s\t-\t-\0' "$tree_path"
        else
            digest="$(sha256sum -b -- "$tree_path")"
            digest="${digest%% *}"
            printf 'f\t%s\t-\t%s\0' "$tree_path" "$digest"
        fi
    done >> "$output_file"
}

snapshot_source_tree() {
    snapshot_tree "$1" "$2" 1
}

snapshot_fixture_sources() {
    local fixture_root="$1"
    local output_file="$2"

    : > "$output_file"
    snapshot_source_tree "$fixture_root/task12-source" "$output_file"
    snapshot_source_tree "$fixture_root/task123-source" "$output_file"
}

snapshot_directory_tree() {
    snapshot_tree "$1" "$2" 0
}

assert_snapshot_equal() {
    local expected_snapshot="$1"
    local actual_snapshot="$2"
    local label="$3"

    if ! cmp -s "$expected_snapshot" "$actual_snapshot"; then
        diff -u \
            <(tr '\0' '\n' < "$expected_snapshot") \
            <(tr '\0' '\n' < "$actual_snapshot") || true
        fail "$label full-tree lstat/path/content snapshot changed"
    fi
}

assert_fixture_sources_unchanged() {
    local fixture_root="$1"
    local expected_snapshot="$2"
    local label="$3"
    local actual_snapshot="$FIXTURE_ROOT/$label.source-tree.after"

    mkdir -p -- "$(dirname -- "$actual_snapshot")"
    snapshot_fixture_sources "$fixture_root" "$actual_snapshot"
    assert_snapshot_equal "$expected_snapshot" "$actual_snapshot" "$label sources"
}

assert_directory_unchanged() {
    local directory="$1"
    local expected_snapshot="$2"
    local label="$3"
    local actual_snapshot="$FIXTURE_ROOT/$label.destination-tree.after"

    mkdir -p -- "$(dirname -- "$actual_snapshot")"
    snapshot_directory_tree "$directory" "$actual_snapshot"
    assert_snapshot_equal "$expected_snapshot" "$actual_snapshot" "$label destination"
}

assert_failed_delete_preserved_sources() {
    local fixture_root="$1"
    local expected_snapshot="$2"
    local label="$3"
    local changed_path="${4:-}"
    local changed_digest="${5:-}"
    local entry_type source_path expected_link expected_digest
    local actual_digest actual_link
    local actual_snapshot="$FIXTURE_ROOT/$label.source-tree.after"
    local expected_after="$FIXTURE_ROOT/$label.source-tree.expected"

    : > "$expected_after"

    while IFS=$'\t' read -r -d '' entry_type source_path expected_link expected_digest; do
        if [[ "$entry_type" == f ]]; then
            [[ -f "$source_path" && ! -L "$source_path" ]] ||
                fail "$label removed source regular file: $source_path"
            actual_digest="$(sha256sum -b -- "$source_path")"
            actual_digest="${actual_digest%% *}"
            if [[ "$source_path" == "$changed_path" ]]; then
                [[ "$actual_digest" == "$changed_digest" ]] ||
                    fail "$label changed the intentionally mutated source: $source_path"
                expected_digest="$changed_digest"
            else
                [[ "$actual_digest" == "$expected_digest" ]] ||
                    fail "$label changed source regular file: $source_path"
            fi
        elif [[ "$entry_type" == l ]]; then
            [[ -L "$source_path" ]] ||
                fail "$label removed source symlink: $source_path"
            actual_link="$(readlink -- "$source_path")"
            [[ "$actual_link" == "$expected_link" ]] ||
                fail "$label changed source symlink: $source_path"
        elif [[ "$entry_type" == d ]]; then
            [[ -d "$source_path" && ! -L "$source_path" ]] ||
                fail "$label removed source directory: $source_path"
        else
            fail "$label snapshot has unknown entry type: $entry_type"
        fi
        printf '%s\t%s\t%s\t%s\0' \
            "$entry_type" "$source_path" "$expected_link" "$expected_digest" \
            >> "$expected_after"
    done < "$expected_snapshot"

    mkdir -p -- "$(dirname -- "$actual_snapshot")"
    snapshot_fixture_sources "$fixture_root" "$actual_snapshot"
    assert_snapshot_equal "$expected_after" "$actual_snapshot" "$label sources"
}

assert_only_inventory_sources_deleted() {
    local fixture_root="$1"
    local selected_paths="$2"
    local before_snapshot="$3"
    local label="$4"
    local after_snapshot="$FIXTURE_ROOT/$label.source-tree.after"
    local expected_after="$FIXTURE_ROOT/$label.source-tree.expected"
    local entry_type source_path expected_link expected_digest

    : > "$expected_after"

    while IFS=$'\t' read -r -d '' entry_type source_path expected_link expected_digest; do
        if [[ "$entry_type" == f ]] && grep -Fzxq -- "$source_path" "$selected_paths"; then
            [[ ! -e "$source_path" && ! -L "$source_path" ]] ||
                fail "$label retained selected source entry: $source_path"
            continue
        fi
        printf '%s\t%s\t%s\t%s\0' \
            "$entry_type" "$source_path" "$expected_link" "$expected_digest" \
            >> "$expected_after"
    done < "$before_snapshot"

    snapshot_fixture_sources "$fixture_root" "$after_snapshot"
    assert_snapshot_equal "$expected_after" "$after_snapshot" "$label sources"
}

run_required_command() {
    local label="$1"
    shift
    local stdout_file="$FIXTURE_ROOT/$label.stdout"
    local stderr_file="$FIXTURE_ROOT/$label.stderr"
    local command_display output

    mkdir -p -- "$(dirname -- "$stdout_file")"
    command_display="$(printf '%q ' "$@")"
    if "$@" > "$stdout_file" 2> "$stderr_file"; then
        return 0
    fi
    output="$(cat -- "$stdout_file" "$stderr_file")"
    if grep -Fq 'usage:' "$stderr_file" && ! grep -Fq 'stage' "$stderr_file"; then
        fail "$label: missing stage subcommand; command=$command_display; raw output:
$output"
    fi
    fail "$label failed; command=$command_display; raw output:
$output"
}

run_expected_failure() {
    local label="$1"
    shift
    local stdout_file="$FIXTURE_ROOT/$label.stdout"
    local stderr_file="$FIXTURE_ROOT/$label.stderr"
    local command_file="$FIXTURE_ROOT/$label.command"
    local command_display output

    mkdir -p -- "$(dirname -- "$stdout_file")"
    command_display="$(printf '%q ' "$@")"
    printf '%s\n' "$command_display" > "$command_file"
    if "$@" > "$stdout_file" 2> "$stderr_file"; then
        output="$(cat -- "$stdout_file" "$stderr_file")"
        fail "$label unexpectedly succeeded; command=$command_display; raw output:
$output"
    fi
}

assert_expected_failure_contains() {
    local label="$1"
    local expected="$2"
    local stdout_file="$FIXTURE_ROOT/$label.stdout"
    local stderr_file="$FIXTURE_ROOT/$label.stderr"
    local command_file="$FIXTURE_ROOT/$label.command"
    local command_display output

    if ! grep -Fq "$expected" "$stderr_file"; then
        command_display="$(<"$command_file")"
        output="$(cat -- "$stdout_file" "$stderr_file")"
        fail "$label did not report $expected; command=$command_display; raw output:
$output"
    fi
}

assert_archive_tree_entries() {
    local destination="$1"
    local expected_paths="$2"
    local archive_path relative_path expected_path
    local allowed_directory

    while IFS= read -r -d '' archive_path; do
        relative_path="${archive_path#"$destination/"}"
        if [[ -L "$archive_path" ]]; then
            fail "archive tree contains symlink: $archive_path"
        elif [[ -d "$archive_path" ]]; then
            allowed_directory=0
            while IFS= read -r -d '' expected_path; do
                case "$expected_path" in
                    "$relative_path"/*)
                        allowed_directory=1
                        break
                        ;;
                esac
            done < "$expected_paths"
            ((allowed_directory == 1)) ||
                fail "archive tree contains extra directory: $archive_path"
        elif [[ -f "$archive_path" ]]; then
            case "$relative_path" in
                manifest.json|INDEX.md|migration-inventory.tsv|rules.sha256)
                    ;;
                *)
                    grep -Fzxq -- "$relative_path" "$expected_paths" ||
                        fail "archive tree contains extra regular file: $archive_path"
                    ;;
            esac
        else
            fail "archive tree contains unsupported entry: $archive_path"
        fi
    done < <(find -P "$destination" -mindepth 1 -print0 | LC_ALL=C sort -z)
}

assert_manifest_matches_inventory() {
    local inventory_file="$1"
    local destination="$2"
    local inventory_paths="$FIXTURE_ROOT/inventory-archived-paths"
    local manifest_paths="$FIXTURE_ROOT/manifest-archived-paths"
    local actual_paths="$FIXTURE_ROOT/actual-archived-paths"
    local inventory_sources="$FIXTURE_ROOT/inventory-sources"
    local manifest_sources="$FIXTURE_ROOT/manifest-sources"
    local source source_root branch commit tracked original_path phase type
    local date date_source size sha256 archived_path source_path target_path
    local inventory_count manifest_count match_count source_count source_rows
    local actual_size actual_sha256 generated_at duplicate_count duplicate_group_json

    inventory_count="$(awk -F '\t' 'NR > 1 && NF { count++ } END { print count + 0 }' "$inventory_file")"
    manifest_count="$(jq -r '.entries | length' "$destination/manifest.json")"
    [[ "$manifest_count" == "$inventory_count" ]] ||
        fail "manifest entry count $manifest_count differs from inventory row count $inventory_count"
    jq -e '
        .schema_version == 1 and
        (.sources | type == "array") and
        (.entries | type == "array") and
        (.generated_at | type == "string" and
            length > 0 and
            test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"))
    ' "$destination/manifest.json" > /dev/null ||
        fail 'manifest schema_version or generated_at is invalid'
    generated_at="$(jq -er '.generated_at' "$destination/manifest.json")" ||
        fail 'manifest generated_at is missing'
    date -u -d "$generated_at" '+%Y-%m-%dT%H:%M:%SZ' > /dev/null ||
        fail 'manifest generated_at is not a valid RFC3339 timestamp'

    awk -F '\t' 'NR > 1 && NF { print $1 "\t" $2 "\t" $3 "\t" $4 }' \
        "$inventory_file" | LC_ALL=C sort -u > "$inventory_sources"
    jq -r '.sources[] | [.name, .root, .branch, .commit] | @tsv' \
        "$destination/manifest.json" | LC_ALL=C sort > "$manifest_sources"
    source_rows="$(wc -l < "$inventory_sources")"
    source_count="$(jq -r '.sources | length' "$destination/manifest.json")"
    [[ "$source_count" == "$source_rows" ]] ||
        fail "manifest source count $source_count differs from inventory source count $source_rows"
    if ! cmp -s "$inventory_sources" "$manifest_sources"; then
        diff -u "$inventory_sources" "$manifest_sources" || true
        fail 'manifest sources are not the exact inventory source set'
    fi

    : > "$inventory_paths"
    while IFS=$'\t' read -r source source_root branch commit tracked original_path \
        phase type date date_source size sha256 archived_path; do
        [[ -n "$source" ]] || continue
        duplicate_count="$(awk -F '\t' -v expected_sha256="$sha256" \
            'NR > 1 && $12 == expected_sha256 { count++ }
             END { print count + 0 }' "$inventory_file")"
        if ((duplicate_count >= 2)); then
            duplicate_group_json="\"$sha256\""
        else
            duplicate_group_json='null'
        fi
        match_count="$(jq -r \
            --arg source "$source" \
            --arg source_root "$source_root" \
            --arg branch "$branch" \
            --arg commit "$commit" \
            --argjson tracked "$tracked" \
            --arg original_path "$original_path" \
            --arg phase "$phase" \
            --arg type "$type" \
            --arg date "$date" \
            --arg date_source "$date_source" \
            --argjson size "$size" \
            --arg sha256 "$sha256" \
            --arg archived_path "$archived_path" \
            --argjson expected_duplicate_group "$duplicate_group_json" \
            '[.entries[] |
                select(.source == $source and
                    .source_root == $source_root and
                    .branch == $branch and
                    .commit == $commit and
                    .tracked == $tracked and
                    .original_path == $original_path and
                    .phase == $phase and
                    .type == $type and
                    .date == $date and
                    .date_source == $date_source and
                    .size == $size and
                    .sha256 == $sha256 and
                    .archived_path == $archived_path and
                    has("duplicate_group") and
                    .duplicate_group == $expected_duplicate_group)] | length' \
            "$destination/manifest.json")"
        [[ "$match_count" == 1 ]] ||
            fail "inventory row has $match_count manifest matches: $source/$original_path"

        target_path="$(resolve_inventory_archive_path \
            "$destination" "$archived_path" "manifest/$source")"
        [[ -f "$target_path" && ! -L "$target_path" ]] ||
            fail "inventory archive file is missing: $target_path"
        actual_size="$(stat -c '%s' -- "$target_path")"
        [[ "$actual_size" == "$size" ]] ||
            fail "archive size differs from inventory: $target_path"
        actual_sha256="$(sha256sum -b -- "$target_path")"
        actual_sha256="${actual_sha256%% *}"
        [[ "$actual_sha256" == "$sha256" ]] ||
            fail "archive SHA-256 differs from inventory: $target_path"
        printf '%s\0' "$archived_path" >> "$inventory_paths"
    done < <(tail -n +2 "$inventory_file")

    LC_ALL=C sort -z -o "$inventory_paths" "$inventory_paths"
    jq -j '.entries[] | .archived_path, "\u0000"' "$destination/manifest.json" |
        LC_ALL=C sort -z > "$manifest_paths"
    find -P "$destination" -type f -print0 |
        while IFS= read -r -d '' source_path; do
            case "$source_path" in
                "$destination/manifest.json"|"$destination/INDEX.md"|\
                "$destination/migration-inventory.tsv"|"$destination/rules.sha256")
                    continue
                    ;;
            esac
            printf '%s\0' "${source_path#"$destination/"}"
        done |
        LC_ALL=C sort -z > "$actual_paths"
    if ! cmp -s "$inventory_paths" "$manifest_paths"; then
        diff -u \
            <(tr '\0' '\n' < "$inventory_paths") \
            <(tr '\0' '\n' < "$manifest_paths") || true
        fail 'inventory and manifest archived_path values differ'
    fi
    if ! cmp -s "$inventory_paths" "$actual_paths"; then
        diff -u \
            <(tr '\0' '\n' < "$inventory_paths") \
            <(tr '\0' '\n' < "$actual_paths") || true
        fail 'archive files and inventory archived_path values differ'
    fi
    assert_archive_tree_entries "$destination" "$inventory_paths"
}

assert_index_counts_match_manifest() {
    local destination="$1"
    local expected_counts="$FIXTURE_ROOT/expected-index-counts.tsv"
    local actual_counts="$FIXTURE_ROOT/actual-index-counts.tsv"

    jq -r '.entries | group_by([.phase, .type])[] | [.[0].phase, .[0].type, length] | @tsv' \
        "$destination/manifest.json" | LC_ALL=C sort > "$expected_counts" ||
        fail 'manifest phase/type aggregation failed'
    awk -F '|' '
        $0 ~ /^\| Phase \| Type \| Count \|$/ { in_table = 1; next }
        in_table && $0 ~ /^\|[[:space:]]*[-]+[[:space:]]*\|/ { next }
        in_table && $0 ~ /^\|/ {
            phase = $2
            type = $3
            count = $4
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", phase)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", type)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", count)
            if (phase != "" && type != "" && count ~ /^[0-9]+$/) {
                print phase "\t" type "\t" count
            }
        }
    ' "$destination/INDEX.md" | LC_ALL=C sort > "$actual_counts"
    diff -u "$expected_counts" "$actual_counts" ||
        fail 'INDEX phase/type counts differ from manifest aggregation'
}

assert_archive_files_are_0644() {
    local destination="$1"
    local archive_path mode

    while IFS= read -r -d '' archive_path; do
        mode="$(stat -c '%a' -- "$archive_path")"
        [[ "$mode" == 644 ]] || fail "archive file mode is not 0644: $archive_path mode=$mode"
    done < <(find -P "$destination" -type f -print0)
}

assert_index_links_are_markdown() {
    local destination="$1"
    local special_archived_path special_encoded_path special_link decoded_link
    grep -Fq '[open](task12/design/2026-08-11/task12-source/docs/superpowers/specs/2026-08-11-rt-ipc-integration-design.md)' \
        "$destination/INDEX.md" || fail 'INDEX did not emit a normal Markdown archive link'
    if grep -Fq '\\(' "$destination/INDEX.md"; then
        fail 'INDEX contains escaped Markdown link syntax'
    fi
    if grep -Fq '%2F' "$destination/INDEX.md"; then
        fail 'INDEX percent-encoded a path separator'
    fi
    special_archived_path="$(jq -r '.entries[] | select(.original_path == "docs/reports/URI 中文 #?% path.md") | .archived_path' \
        "$destination/manifest.json")"
    [[ -n "$special_archived_path" ]] || fail 'special URI path is missing from manifest'
    special_encoded_path="$(printf '%s' "$special_archived_path" | jq -sRr \
        'split("/") | map(@uri) | join("/")')"
    special_link="$(grep -F '[open](' "$destination/INDEX.md" | grep -F "$special_encoded_path" | \
        sed -n 's/.*\[open\](\([^)]*\)).*/\1/p' || true)"
    [[ "$special_link" == "$special_encoded_path" ]] ||
        fail 'INDEX did not segment-encode the special archive path'
    case "$special_link" in
        *' '*|*'#'*|*'?'*) fail 'INDEX special link contains a raw URI delimiter or space' ;;
    esac
    decoded_link="$(printf '%b' "${special_link//%/\\x}")"
    [[ "$decoded_link" == "$special_archived_path" ]] ||
        fail 'INDEX special link does not decode to archived_path'
}

archive_fixture="$(make_archive_fixture archive-success)"
archive_inventory="$archive_fixture/inventory.tsv"
archive_destination="$archive_fixture/archive"
archive_snapshot="$archive_fixture/source-tree.before"
archive_selected_sources="$archive_fixture/selected-source-paths"
snapshot_fixture_sources "$archive_fixture" "$archive_snapshot"
build_inventory_source_paths \
    "$archive_fixture" "$archive_inventory" "$archive_selected_sources"
run_required_command archive-success/stage \
    bash "$ARCHIVER" stage \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
assert_fixture_sources_unchanged \
    "$archive_fixture" \
    "$archive_snapshot" \
    archive-success/stage

assert_inventory_sources_exist "$archive_inventory" "$archive_fixture"
[[ -f "$archive_destination/manifest.json" ]] ||
    fail 'stage did not create manifest.json'
[[ -f "$archive_destination/INDEX.md" ]] ||
    fail 'stage did not create INDEX.md'
assert_inventory_targets_exist "$archive_inventory" "$archive_destination"
assert_manifest_matches_inventory "$archive_inventory" "$archive_destination"
assert_archive_files_are_0644 "$archive_destination"
assert_index_links_are_markdown "$archive_destination"

archive_destination_before_repeat_stage="$archive_fixture/destination-before-repeat-stage"
archive_source_before_repeat_stage="$archive_fixture/source-before-repeat-stage"
snapshot_directory_tree "$archive_destination" "$archive_destination_before_repeat_stage"
snapshot_fixture_sources "$archive_fixture" "$archive_source_before_repeat_stage"
run_required_command archive-success/repeat-stage \
    bash "$ARCHIVER" stage \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
snapshot_directory_tree "$archive_destination" "$archive_fixture/destination-after-repeat-stage"
snapshot_fixture_sources "$archive_fixture" "$archive_fixture/source-after-repeat-stage"
assert_snapshot_equal \
    "$archive_destination_before_repeat_stage" \
    "$archive_fixture/destination-after-repeat-stage" \
    archive-success/repeat-stage destination
assert_snapshot_equal \
    "$archive_source_before_repeat_stage" \
    "$archive_fixture/source-after-repeat-stage" \
    archive-success/repeat-stage sources

inventory_only_fixture="$(make_archive_fixture archive-inventory-only-destination)"
inventory_only_inventory="$inventory_only_fixture/inventory.tsv"
inventory_only_destination="$inventory_only_fixture/archive"
inventory_only_source_snapshot="$inventory_only_fixture/source-tree.before"
mkdir -p -- "$inventory_only_destination"
cp -- "$inventory_only_inventory" "$inventory_only_destination/migration-inventory.tsv"
snapshot_fixture_sources "$inventory_only_fixture" "$inventory_only_source_snapshot"
snapshot_directory_tree \
    "$inventory_only_destination" \
    "$inventory_only_fixture/destination-before-publish-failure"
run_expected_failure archive-inventory-only-destination/injected-publish-failure \
    env ARCHIVE_HISTORY_DOCS_TEST_FAIL_PUBLISH_AFTER_BACKUP=1 \
    bash "$ARCHIVER" stage \
    --inventory "$inventory_only_inventory" \
    --destination "$inventory_only_destination"
assert_expected_failure_contains \
    archive-inventory-only-destination/injected-publish-failure \
    'injected publish failure'
snapshot_directory_tree \
    "$inventory_only_destination" \
    "$inventory_only_fixture/destination-after-publish-failure"
assert_snapshot_equal \
    "$inventory_only_fixture/destination-before-publish-failure" \
    "$inventory_only_fixture/destination-after-publish-failure" \
    archive-inventory-only-destination/injected-publish-failure destination
run_required_command archive-inventory-only-destination/stage \
    bash "$ARCHIVER" stage \
    --inventory "$inventory_only_inventory" \
    --destination "$inventory_only_destination"
run_required_command archive-inventory-only-destination/verify \
    bash "$ARCHIVER" verify \
    --inventory "$inventory_only_inventory" \
    --destination "$inventory_only_destination"
assert_fixture_sources_unchanged \
    "$inventory_only_fixture" \
    "$inventory_only_source_snapshot" \
    archive-inventory-only-destination/stage

run_required_command archive-success/verify-before-duplicate-mutation \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"

unique_manifest_path="$(jq -r '[.entries[] | select(has("duplicate_group") and .duplicate_group == null)][0].archived_path' \
    "$archive_destination/manifest.json")"
[[ -n "$unique_manifest_path" && "$unique_manifest_path" != null ]] ||
    fail 'archive fixture did not contain a unique manifest entry'
unique_manifest_sha="$(awk -F '\t' -v expected_path="$unique_manifest_path" \
    'NR > 1 && $13 == expected_path { print $12; exit }' "$archive_inventory")"
[[ -n "$unique_manifest_sha" ]] ||
    fail 'unique manifest entry was not found in inventory'
archive_manifest_backup="$archive_fixture/manifest.before-duplicate-mutation.json"
archive_manifest_tmp="$archive_fixture/manifest.duplicate-mutation.json"
cp -- "$archive_destination/manifest.json" "$archive_manifest_backup"
jq --arg archived_path "$unique_manifest_path" --arg duplicate_group "$unique_manifest_sha" \
    '(.entries[] | select(.archived_path == $archived_path) | .duplicate_group) = $duplicate_group' \
    "$archive_manifest_backup" > "$archive_manifest_tmp"
mv -- "$archive_manifest_tmp" "$archive_destination/manifest.json"
duplicate_value_destination_before="$archive_fixture/destination-before-duplicate-value-mutation"
snapshot_directory_tree "$archive_destination" "$duplicate_value_destination_before"
run_expected_failure archive-success/manifest-unique-duplicate-group/verify \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
duplicate_value_destination_after="$archive_fixture/destination-after-duplicate-value-mutation"
snapshot_directory_tree "$archive_destination" "$duplicate_value_destination_after"
assert_snapshot_equal \
    "$duplicate_value_destination_before" \
    "$duplicate_value_destination_after" \
    archive-success/manifest-unique-duplicate-group/verify
assert_expected_failure_contains \
    archive-success/manifest-unique-duplicate-group/verify \
    "$unique_manifest_path"
cp -- "$archive_manifest_backup" "$archive_destination/manifest.json"
run_required_command archive-success/verify-after-duplicate-value-mutation \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"

jq --arg archived_path "$unique_manifest_path" \
    'del(.entries[] | select(.archived_path == $archived_path).duplicate_group)' \
    "$archive_destination/manifest.json" > "$archive_manifest_tmp"
mv -- "$archive_manifest_tmp" "$archive_destination/manifest.json"
duplicate_missing_destination_before="$archive_fixture/destination-before-duplicate-missing-mutation"
snapshot_directory_tree "$archive_destination" "$duplicate_missing_destination_before"
run_expected_failure archive-success/manifest-unique-duplicate-group-missing/verify \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
duplicate_missing_destination_after="$archive_fixture/destination-after-duplicate-missing-mutation"
snapshot_directory_tree "$archive_destination" "$duplicate_missing_destination_after"
assert_snapshot_equal \
    "$duplicate_missing_destination_before" \
    "$duplicate_missing_destination_after" \
    archive-success/manifest-unique-duplicate-group-missing/verify
assert_expected_failure_contains \
    archive-success/manifest-unique-duplicate-group-missing/verify \
    "$unique_manifest_path"
cp -- "$archive_manifest_backup" "$archive_destination/manifest.json"

run_required_command archive-success/verify-after-duplicate-mutation \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"

duplicate_group_count="$(jq -r '
    [.entries[] | select(.original_path | endswith("shared-evidence.log"))]
    | map(.duplicate_group) | unique
    | if length == 1 and .[0] != null then "1" else "0" end
' "$archive_destination/manifest.json")"
[[ "$duplicate_group_count" == 1 ]] ||
    fail 'identical shared evidence did not produce one non-null duplicate group'
duplicate_entry_count="$(jq -r '
    [.entries[] | select(.original_path | endswith("shared-evidence.log"))] | length
' "$archive_destination/manifest.json")"
[[ "$duplicate_entry_count" == 2 ]] ||
    fail 'both identical shared evidence entries were not retained'
duplicate_sha="$(awk -F '\t' \
    '$6 ~ /shared-evidence\.log$/ { print $12 }' \
    "$archive_inventory" | LC_ALL=C sort -u)"
[[ "$(printf '%s\n' "$duplicate_sha" | awk 'NF { count++ } END { print count + 0 }')" == 1 ]] ||
    fail 'shared evidence inventory did not have one SHA-256'
jq -e --arg duplicate_sha "$duplicate_sha" '
    [.entries[] | select(.original_path | endswith("shared-evidence.log"))] |
    length == 2 and
    all(has("duplicate_group")) and
    (map(.sha256) | unique == [$duplicate_sha]) and
    (map(.duplicate_group) | unique == [$duplicate_sha])
' "$archive_destination/manifest.json" > /dev/null ||
    fail 'duplicate_group does not equal the shared evidence SHA-256'
assert_index_counts_match_manifest "$archive_destination"

[[ -f "$archive_fixture/task12-source/docs/README.md" ]] ||
    fail 'stage removed task12 README'
[[ -f "$archive_fixture/task12-source/docs/docs/architecture/axvisor/overview.md" ]] ||
    fail 'stage removed active architecture reference'
[[ -f "$archive_fixture/task12-source/apps/demo/validation/baseline.txt" ]] ||
    fail 'stage removed validation baseline'
run_required_command archive-success/delete \
    bash "$ARCHIVER" delete \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
run_required_command archive-success/verify-after-delete \
    bash "$ARCHIVER" verify \
    --inventory "$archive_inventory" \
    --destination "$archive_destination"
assert_only_inventory_sources_deleted \
    "$archive_fixture" \
    "$archive_selected_sources" \
    "$archive_snapshot" \
    archive-success/delete
[[ -f "$archive_fixture/task12-source/docs/README.md" ]] ||
    fail 'delete removed task12 README'
[[ -f "$archive_fixture/task12-source/docs/docs/architecture/axvisor/overview.md" ]] ||
    fail 'delete removed active architecture reference'
[[ -f "$archive_fixture/task12-source/apps/demo/validation/baseline.txt" ]] ||
    fail 'delete removed validation baseline'
[[ -f "$archive_fixture/task12-source/ignored-archive-sentinel.txt" ]] ||
    fail 'delete removed ignored source sentinel'

mutation_fixture="$(make_archive_fixture archive-source-mutation)"
mutation_inventory="$mutation_fixture/inventory.tsv"
mutation_destination="$mutation_fixture/archive"
mutation_snapshot="$mutation_fixture/source-tree.before"
mutation_source_root="$(awk -F '\t' 'END { print $2 }' "$mutation_inventory")"
mutation_original_path="$(awk -F '\t' 'END { print $6 }' "$mutation_inventory")"
mutation_source_path="$(resolve_inventory_source_path \
    "$mutation_fixture" \
    "$mutation_source_root" \
    "$mutation_original_path" \
    archive-source-mutation)"
snapshot_fixture_sources "$mutation_fixture" "$mutation_snapshot"
run_required_command archive-source-mutation/stage \
    bash "$ARCHIVER" stage \
    --inventory "$mutation_inventory" \
    --destination "$mutation_destination"
printf '%s\n' 'changed after stage' >> "$mutation_source_path"
mutation_source_digest="$(sha256sum -b -- "$mutation_source_path")"
mutation_source_digest="${mutation_source_digest%% *}"
mutation_destination_snapshot="$mutation_fixture/destination-tree.before-delete"
snapshot_directory_tree "$mutation_destination" "$mutation_destination_snapshot"
run_expected_failure archive-source-mutation/delete \
    bash "$ARCHIVER" delete \
    --inventory "$mutation_inventory" \
    --destination "$mutation_destination"
assert_expected_failure_contains archive-source-mutation/delete changed
assert_failed_delete_preserved_sources \
    "$mutation_fixture" \
    "$mutation_snapshot" \
    archive-source-mutation/delete \
    "$mutation_source_path" \
    "$mutation_source_digest"
mutation_destination_after="$mutation_fixture/destination-tree.after-delete"
snapshot_directory_tree "$mutation_destination" "$mutation_destination_after"
assert_snapshot_equal \
    "$mutation_destination_snapshot" \
    "$mutation_destination_after" \
    archive-source-mutation/delete destination

missing_target_fixture="$(make_archive_fixture archive-missing-target)"
missing_target_inventory="$missing_target_fixture/inventory.tsv"
missing_target_destination="$missing_target_fixture/archive"
missing_target_snapshot="$missing_target_fixture/source-tree.before"
mkdir -p -- "$missing_target_destination"
missing_target_archived_path="$(awk -F '\t' 'END { print $13 }' "$missing_target_inventory")"
missing_target_path="$(resolve_inventory_archive_path \
    "$missing_target_destination" \
    "$missing_target_archived_path" \
    archive-missing-target)"
snapshot_fixture_sources "$missing_target_fixture" "$missing_target_snapshot"
run_required_command archive-missing-target/stage \
    bash "$ARCHIVER" stage \
    --inventory "$missing_target_inventory" \
    --destination "$missing_target_destination"
rm -- "$missing_target_path"
missing_verify_before="$missing_target_fixture/destination-before-verify"
snapshot_directory_tree "$missing_target_destination" "$missing_verify_before"
run_expected_failure archive-missing-target/verify \
    bash "$ARCHIVER" verify \
    --inventory "$missing_target_inventory" \
    --destination "$missing_target_destination"
missing_verify_after="$missing_target_fixture/destination-after-verify"
snapshot_directory_tree "$missing_target_destination" "$missing_verify_after"
assert_snapshot_equal \
    "$missing_verify_before" \
    "$missing_verify_after" \
    archive-missing-target/verify
missing_delete_before="$missing_target_fixture/destination-before-delete"
snapshot_directory_tree "$missing_target_destination" "$missing_delete_before"
run_expected_failure archive-missing-target/delete \
    bash "$ARCHIVER" delete \
    --inventory "$missing_target_inventory" \
    --destination "$missing_target_destination"
missing_delete_after="$missing_target_fixture/destination-after-delete"
snapshot_directory_tree "$missing_target_destination" "$missing_delete_after"
assert_snapshot_equal \
    "$missing_delete_before" \
    "$missing_delete_after" \
    archive-missing-target/delete
assert_expected_failure_contains archive-missing-target/verify missing
assert_expected_failure_contains archive-missing-target/delete missing
assert_failed_delete_preserved_sources \
    "$missing_target_fixture" \
    "$missing_target_snapshot" \
    archive-missing-target/delete

corrupt_target_fixture="$(make_archive_fixture archive-corrupt-target)"
corrupt_target_inventory="$corrupt_target_fixture/inventory.tsv"
corrupt_target_destination="$corrupt_target_fixture/archive"
corrupt_target_snapshot="$corrupt_target_fixture/source-tree.before"
mkdir -p -- "$corrupt_target_destination"
corrupt_target_archived_path="$(awk -F '\t' 'END { print $13 }' "$corrupt_target_inventory")"
corrupt_target_path="$(resolve_inventory_archive_path \
    "$corrupt_target_destination" \
    "$corrupt_target_archived_path" \
    archive-corrupt-target)"
snapshot_fixture_sources "$corrupt_target_fixture" "$corrupt_target_snapshot"
run_required_command archive-corrupt-target/stage \
    bash "$ARCHIVER" stage \
    --inventory "$corrupt_target_inventory" \
    --destination "$corrupt_target_destination"
printf '%s\n' 'corrupted after stage' > "$corrupt_target_path"
corrupt_verify_before="$corrupt_target_fixture/destination-before-verify"
snapshot_directory_tree "$corrupt_target_destination" "$corrupt_verify_before"
run_expected_failure archive-corrupt-target/verify \
    bash "$ARCHIVER" verify \
    --inventory "$corrupt_target_inventory" \
    --destination "$corrupt_target_destination"
corrupt_verify_after="$corrupt_target_fixture/destination-after-verify"
snapshot_directory_tree "$corrupt_target_destination" "$corrupt_verify_after"
assert_snapshot_equal \
    "$corrupt_verify_before" \
    "$corrupt_verify_after" \
    archive-corrupt-target/verify
corrupt_delete_before="$corrupt_target_fixture/destination-before-delete"
snapshot_directory_tree "$corrupt_target_destination" "$corrupt_delete_before"
run_expected_failure archive-corrupt-target/delete \
    bash "$ARCHIVER" delete \
    --inventory "$corrupt_target_inventory" \
    --destination "$corrupt_target_destination"
corrupt_delete_after="$corrupt_target_fixture/destination-after-delete"
snapshot_directory_tree "$corrupt_target_destination" "$corrupt_delete_after"
assert_snapshot_equal \
    "$corrupt_delete_before" \
    "$corrupt_delete_after" \
    archive-corrupt-target/delete
assert_expected_failure_contains \
    archive-corrupt-target/verify \
    "$corrupt_target_archived_path"
assert_expected_failure_contains \
    archive-corrupt-target/delete \
    "$corrupt_target_archived_path"
assert_failed_delete_preserved_sources \
    "$corrupt_target_fixture" \
    "$corrupt_target_snapshot" \
    archive-corrupt-target/delete

collision_fixture="$(make_archive_fixture archive-collision)"
collision_inventory="$collision_fixture/inventory.tsv"
collision_destination="$collision_fixture/archive"
collision_snapshot="$collision_fixture/source-tree.before"
snapshot_fixture_sources "$collision_fixture" "$collision_snapshot"
mkdir -p -- "$collision_destination"
collision_archived_path="$(awk -F '\t' 'END { print $13 }' "$collision_inventory")"
collision_target_path="$(resolve_inventory_archive_path \
    "$collision_destination" \
    "$collision_archived_path" \
    archive-collision)"
mkdir -p -- "$(dirname -- "$collision_target_path")"
printf '%s\n' 'different collision content' > "$collision_target_path"
collision_destination_snapshot="$collision_fixture/destination-tree.before"
snapshot_directory_tree "$collision_destination" "$collision_destination_snapshot"
run_expected_failure archive-collision/stage \
    bash "$ARCHIVER" stage \
    --inventory "$collision_inventory" \
    --destination "$collision_destination"
assert_expected_failure_contains archive-collision/stage "$collision_archived_path"
[[ "$(<"$collision_target_path")" == 'different collision content' ]] ||
    fail 'destination collision content was modified'
assert_directory_unchanged \
    "$collision_destination" \
    "$collision_destination_snapshot" \
    archive-collision/stage
assert_fixture_sources_unchanged \
    "$collision_fixture" \
    "$collision_snapshot" \
    archive-collision/stage

git_destination_fixture="$(make_archive_fixture archive-git-destination)"
git_destination_inventory="$git_destination_fixture/inventory.tsv"
git_destination_source_snapshot="$git_destination_fixture/source-tree.before"
git_destination="$git_destination_fixture/.git/archive"
mkdir -p -- "$git_destination"
snapshot_fixture_sources "$git_destination_fixture" "$git_destination_source_snapshot"
snapshot_directory_tree "$git_destination" "$git_destination_fixture/destination-tree.before"
run_expected_failure archive-git-destination/stage \
    bash "$ARCHIVER" stage \
    --inventory "$git_destination_inventory" \
    --destination "$git_destination"
assert_expected_failure_contains archive-git-destination/stage '.git'
snapshot_directory_tree "$git_destination" "$git_destination_fixture/destination-tree.after"
assert_snapshot_equal \
    "$git_destination_fixture/destination-tree.before" \
    "$git_destination_fixture/destination-tree.after" \
    archive-git-destination/stage destination
assert_fixture_sources_unchanged \
    "$git_destination_fixture" \
    "$git_destination_source_snapshot" \
    archive-git-destination/stage
snapshot_directory_tree "$git_destination_fixture/.git" "$git_destination_fixture/git-root.before"
run_expected_failure archive-git-root-destination/stage \
    bash "$ARCHIVER" stage \
    --inventory "$git_destination_inventory" \
    --destination "$git_destination_fixture/.git"
assert_expected_failure_contains archive-git-root-destination/stage '.git'
snapshot_directory_tree "$git_destination_fixture/.git" "$git_destination_fixture/git-root.after"
assert_snapshot_equal \
    "$git_destination_fixture/git-root.before" \
    "$git_destination_fixture/git-root.after" \
    archive-git-root-destination/stage destination

archive_script_stage_body="$FIXTURE_ROOT/archive-script-stage-body"
sed -n '/^stage_archive()/,/^}/p' "$ARCHIVER" > "$archive_script_stage_body"
stage_tree_before_line="$(grep -n 'capture_archive_source_trees stage-before' "$archive_script_stage_body" | cut -d: -f1)"
stage_install_line="$(grep -n 'install -D -m 0644 -- "$source_path"' "$archive_script_stage_body" | cut -d: -f1)"
stage_tree_after_line="$(grep -n 'capture_archive_source_trees stage-after' "$archive_script_stage_body" | cut -d: -f1)"
stage_state_check_count="$(grep -c 'strict_archive_source_preflight' "$archive_script_stage_body")"
[[ -n "$stage_tree_before_line" && -n "$stage_install_line" && -n "$stage_tree_after_line" ]] ||
    fail 'stage source tree checks or install copy are missing'
((stage_tree_before_line < stage_install_line && stage_install_line < stage_tree_after_line)) ||
    fail 'stage source tree snapshots do not bracket archive copying'
((stage_state_check_count >= 2)) ||
    fail 'stage does not recheck source repository state after copying'

tracked_mutation_fixture="$(make_archive_fixture archive-tracked-mutation)"
tracked_mutation_inventory="$tracked_mutation_fixture/inventory.tsv"
tracked_mutation_inventory_tmp="$tracked_mutation_fixture/inventory.mutated.tsv"
tracked_mutation_destination="$tracked_mutation_fixture/archive"
awk -F '\t' -v OFS='\t' 'NR == 2 { $5 = ($5 == "true" ? "false" : "true") } { print }' \
    "$tracked_mutation_inventory" > "$tracked_mutation_inventory_tmp"
mv -- "$tracked_mutation_inventory_tmp" "$tracked_mutation_inventory"
tracked_mutation_source_snapshot="$tracked_mutation_fixture/source-tree.before"
snapshot_fixture_sources "$tracked_mutation_fixture" "$tracked_mutation_source_snapshot"
mkdir -p -- "$tracked_mutation_destination"
snapshot_directory_tree "$tracked_mutation_destination" "$tracked_mutation_fixture/destination-tree.before-stage"
run_expected_failure archive-tracked-mutation/stage \
    bash "$ARCHIVER" stage \
    --inventory "$tracked_mutation_inventory" \
    --destination "$tracked_mutation_destination"
assert_expected_failure_contains archive-tracked-mutation/stage tracked
snapshot_directory_tree "$tracked_mutation_destination" "$tracked_mutation_fixture/destination-tree.after-stage"
assert_snapshot_equal \
    "$tracked_mutation_fixture/destination-tree.before-stage" \
    "$tracked_mutation_fixture/destination-tree.after-stage" \
    archive-tracked-mutation/stage destination
assert_fixture_sources_unchanged \
    "$tracked_mutation_fixture" \
    "$tracked_mutation_source_snapshot" \
    archive-tracked-mutation/stage

tracked_delete_fixture="$(make_archive_fixture archive-tracked-delete-mutation)"
tracked_delete_inventory="$tracked_delete_fixture/inventory.tsv"
tracked_delete_inventory_original="$tracked_delete_fixture/inventory.original.tsv"
tracked_delete_destination="$tracked_delete_fixture/archive"
tracked_delete_archived_path=""
tracked_delete_manifest_tmp="$tracked_delete_fixture/manifest.tracked-mutation.json"
cp -- "$tracked_delete_inventory" "$tracked_delete_inventory_original"
cp -- "$tracked_delete_inventory.rules.sha256" "$tracked_delete_inventory_original.rules.sha256"
run_required_command archive-tracked-delete-mutation/stage \
    bash "$ARCHIVER" stage \
    --inventory "$tracked_delete_inventory_original" \
    --destination "$tracked_delete_destination"
tracked_delete_source_snapshot="$tracked_delete_fixture/source-tree.before-delete"
snapshot_fixture_sources "$tracked_delete_fixture" "$tracked_delete_source_snapshot"
awk -F '\t' -v OFS='\t' 'NR == 2 { $5 = ($5 == "true" ? "false" : "true") } { print }' \
    "$tracked_delete_inventory_original" > "$tracked_delete_inventory"
tracked_delete_archived_path="$(awk -F '\t' 'NR == 2 { print $13 }' "$tracked_delete_inventory")"
cp -- "$tracked_delete_inventory" "$tracked_delete_destination/migration-inventory.tsv"
jq --arg archived_path "$tracked_delete_archived_path" \
    '(.entries[] | select(.archived_path == $archived_path) | .tracked) |= not' \
    "$tracked_delete_destination/manifest.json" > "$tracked_delete_manifest_tmp"
mv -- "$tracked_delete_manifest_tmp" "$tracked_delete_destination/manifest.json"
tracked_delete_destination_snapshot="$tracked_delete_fixture/destination-tree.before-delete"
snapshot_directory_tree "$tracked_delete_destination" "$tracked_delete_destination_snapshot"
run_expected_failure archive-tracked-delete-mutation/delete \
    bash "$ARCHIVER" delete \
    --inventory "$tracked_delete_inventory" \
    --destination "$tracked_delete_destination"
assert_expected_failure_contains archive-tracked-delete-mutation/delete tracked
snapshot_directory_tree "$tracked_delete_destination" "$tracked_delete_fixture/destination-tree.after-delete"
assert_snapshot_equal \
    "$tracked_delete_destination_snapshot" \
    "$tracked_delete_fixture/destination-tree.after-delete" \
    archive-tracked-delete-mutation/delete destination
assert_fixture_sources_unchanged \
    "$tracked_delete_fixture" \
    "$tracked_delete_source_snapshot" \
    archive-tracked-delete-mutation/delete

symlink_delete_fixture="$(make_archive_fixture archive-symlink-delete-mutation)"
symlink_delete_inventory="$symlink_delete_fixture/inventory.tsv"
symlink_delete_destination="$symlink_delete_fixture/archive"
symlink_delete_source_root="$(awk -F '\t' 'NR == 2 { print $2 }' "$symlink_delete_inventory")"
symlink_delete_original_path="$(awk -F '\t' 'NR == 2 { print $6 }' "$symlink_delete_inventory")"
symlink_delete_source_path="$(resolve_inventory_source_path \
    "$symlink_delete_fixture" \
    "$symlink_delete_source_root" \
    "$symlink_delete_original_path" \
    symlink-delete-mutation)"
run_required_command symlink-delete-mutation/stage \
    bash "$ARCHIVER" stage \
    --inventory "$symlink_delete_inventory" \
    --destination "$symlink_delete_destination"
rm -- "$symlink_delete_source_path"
ln -s -- docs/README.md "$symlink_delete_source_path"
symlink_delete_source_snapshot="$symlink_delete_fixture/source-tree.before-delete"
snapshot_fixture_sources "$symlink_delete_fixture" "$symlink_delete_source_snapshot"
symlink_delete_destination_snapshot="$symlink_delete_fixture/destination-tree.before-delete"
snapshot_directory_tree "$symlink_delete_destination" "$symlink_delete_destination_snapshot"
run_expected_failure symlink-delete-mutation/delete \
    bash "$ARCHIVER" delete \
    --inventory "$symlink_delete_inventory" \
    --destination "$symlink_delete_destination"
assert_expected_failure_contains symlink-delete-mutation/delete symlink
[[ -L "$symlink_delete_source_path" ]] ||
    fail 'delete removed or followed a replaced source symlink'
snapshot_directory_tree "$symlink_delete_destination" "$symlink_delete_fixture/destination-tree.after-delete"
assert_snapshot_equal \
    "$symlink_delete_destination_snapshot" \
    "$symlink_delete_fixture/destination-tree.after-delete" \
    symlink-delete-mutation/delete destination
assert_fixture_sources_unchanged \
    "$symlink_delete_fixture" \
    "$symlink_delete_source_snapshot" \
    symlink-delete-mutation/delete

source_root_fixture="$(make_archive_fixture archive-source-root-destination)"
source_root_inventory="$source_root_fixture/inventory.tsv"
source_root_snapshot="$source_root_fixture/source-tree.before"
snapshot_fixture_sources "$source_root_fixture" "$source_root_snapshot"
source_root_destination_snapshot="$source_root_fixture/destination-tree.before"
snapshot_directory_tree \
    "$source_root_fixture/task12-source" \
    "$source_root_destination_snapshot"
run_expected_failure archive-source-root-destination/stage \
    bash "$ARCHIVER" stage \
    --inventory "$source_root_inventory" \
    --destination "$source_root_fixture/task12-source"
assert_expected_failure_contains \
    archive-source-root-destination/stage \
    "$source_root_fixture/task12-source"
assert_directory_unchanged \
    "$source_root_fixture/task12-source" \
    "$source_root_destination_snapshot" \
    archive-source-root-destination/stage
assert_fixture_sources_unchanged \
    "$source_root_fixture" \
    "$source_root_snapshot" \
    archive-source-root-destination/stage

workspace_fixture="$(make_archive_fixture archive-workspace-root-destination)"
workspace_inventory="$workspace_fixture/inventory.tsv"
workspace_root="$workspace_fixture/workspace-root"
mkdir -p -- "$workspace_root"
printf '%s\n' 'unrelated workspace content' > "$workspace_root/unrelated.txt"
workspace_root_snapshot="$workspace_fixture/source-tree.before"
snapshot_fixture_sources "$workspace_fixture" "$workspace_root_snapshot"
workspace_destination_snapshot="$workspace_fixture/destination-tree.before"
snapshot_directory_tree "$workspace_root" "$workspace_destination_snapshot"
run_expected_failure archive-workspace-root-destination/stage \
    bash "$ARCHIVER" stage \
    --inventory "$workspace_inventory" \
    --destination "$workspace_root"
assert_expected_failure_contains \
    archive-workspace-root-destination/stage \
    "$workspace_root"
[[ "$(<"$workspace_root/unrelated.txt")" == 'unrelated workspace content' ]] ||
    fail 'unsafe workspace root content was modified'
assert_directory_unchanged \
    "$workspace_root" \
    "$workspace_destination_snapshot" \
    archive-workspace-root-destination/stage
assert_fixture_sources_unchanged \
    "$workspace_fixture" \
    "$workspace_root_snapshot" \
    archive-workspace-root-destination/stage

escape_fixture="$(make_archive_fixture archive-path-escape)"
escape_inventory="$escape_fixture/inventory.tsv"
escape_inventory_tmp="$escape_fixture/inventory.tmp"
escape_inventory_last_line="$(wc -l < "$escape_inventory")"
awk -F '\t' -v OFS='\t' \
    -v last_line="$escape_inventory_last_line" \
    'NR == last_line { $13 = "../outside-archive" } { print }' \
    "$escape_inventory" > "$escape_inventory_tmp"
mv -- "$escape_inventory_tmp" "$escape_inventory"
escape_snapshot="$escape_fixture/source-tree.before"
snapshot_fixture_sources "$escape_fixture" "$escape_snapshot"
mkdir -p -- "$escape_fixture/archive"
escape_destination_snapshot="$escape_fixture/destination-tree.before"
snapshot_directory_tree "$escape_fixture/archive" "$escape_destination_snapshot"
run_expected_failure archive-path-escape/stage \
    bash "$ARCHIVER" stage \
    --inventory "$escape_inventory" \
    --destination "$escape_fixture/archive"
assert_expected_failure_contains archive-path-escape/stage ../outside-archive
[[ ! -e "$escape_fixture/outside-archive" ]] ||
    fail 'stage wrote outside destination for an escaping archived_path'
assert_directory_unchanged \
    "$escape_fixture/archive" \
    "$escape_destination_snapshot" \
    archive-path-escape/stage
assert_fixture_sources_unchanged \
    "$escape_fixture" \
    "$escape_snapshot" \
    archive-path-escape/stage

newline_source="$FIXTURE_ROOT/"$'source\nroot'
init_fixture_repo "$newline_source"
write_fixture_file \
    "$newline_source/docs/superpowers/specs/2026-08-10-newline-root-design.md" \
    'newline root design'
commit_fixture_repo "$newline_source" .
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "newline-source=$newline_source" \
    --output "$FIXTURE_ROOT/newline-root-inventory.tsv" \
    > "$FIXTURE_ROOT/newline-root.stdout" 2> "$FIXTURE_ROOT/newline-root.stderr"; then
    fail 'inventory accepted a source_root containing newline'
fi
grep -Fq 'source_root contains ASCII control byte' "$FIXTURE_ROOT/newline-root.stderr" ||
    fail 'newline source_root failure was not reported'

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

control_type_rules="$FIXTURE_ROOT/control-type-rules.tsv"
control_type_inventory="$FIXTURE_ROOT/control-type-inventory.tsv"
printf '%s\n' $'include\t^docs/superpowers/specs/.*\.md$\ttask12\tdesign\x01\tcontrol type' \
    > "$control_type_rules"
if bash "$ARCHIVER" inventory \
    --rules "$control_type_rules" \
    --source "control-type-source=$task12_source" \
    --output "$control_type_inventory" \
    > "$FIXTURE_ROOT/control-type.stdout" 2> "$FIXTURE_ROOT/control-type.stderr"; then
    fail 'inventory accepted a rule type containing 0x01'
fi
[[ ! -e "$control_type_inventory" ]] ||
    fail 'control type failure produced an inventory file'
grep -Fq 'rule_type contains ASCII control byte' "$FIXTURE_ROOT/control-type.stderr" ||
    fail 'rule type control byte failure was not reported'

control_reason_rules="$FIXTURE_ROOT/control-reason-rules.tsv"
control_reason_inventory="$FIXTURE_ROOT/control-reason-inventory.tsv"
printf '%s\n' $'include\t^docs/superpowers/specs/.*\.md$\ttask12\tdesign\treason with CR\r' \
    > "$control_reason_rules"
if bash "$ARCHIVER" inventory \
    --rules "$control_reason_rules" \
    --source "control-reason-source=$task12_source" \
    --output "$control_reason_inventory" \
    > "$FIXTURE_ROOT/control-reason.stdout" 2> "$FIXTURE_ROOT/control-reason.stderr"; then
    fail 'inventory accepted a rule reason containing CR'
fi
[[ ! -e "$control_reason_inventory" ]] ||
    fail 'control reason failure produced an inventory file'
grep -Fq 'rule_reason contains ASCII control byte' "$FIXTURE_ROOT/control-reason.stderr" ||
    fail 'rule reason control byte failure was not reported'

empty_exclude_rules="$FIXTURE_ROOT/empty-exclude-rules.tsv"
empty_exclude_inventory="$FIXTURE_ROOT/empty-exclude-inventory.tsv"
printf '%s\n' $'exclude\t^docs/superpowers/specs/.*\\.md$\t\t\tempty exclude fields' \
    > "$empty_exclude_rules"
bash "$ARCHIVER" inventory \
    --rules "$empty_exclude_rules" \
    --source "empty-exclude-source=$task12_source" \
    --output "$empty_exclude_inventory" \
    > "$FIXTURE_ROOT/empty-exclude.stdout" 2> "$FIXTURE_ROOT/empty-exclude.stderr" ||
    fail 'inventory rejected empty phase/type fields on an exclude rule'
[[ -s "$empty_exclude_inventory" ]] ||
    fail 'empty exclude rule did not produce an inventory header'

invalid_exclude_rules="$FIXTURE_ROOT/invalid-exclude-rules.tsv"
invalid_exclude_inventory="$FIXTURE_ROOT/invalid-exclude-inventory.tsv"
printf '%s\n' $'exclude\t^docs/superpowers/specs/.*\\.md$\texcluded\t\tinvalid exclude metadata' \
    > "$invalid_exclude_rules"
if bash "$ARCHIVER" inventory \
    --rules "$invalid_exclude_rules" \
    --source "invalid-exclude-source=$task12_source" \
    --output "$invalid_exclude_inventory" \
    > "$FIXTURE_ROOT/invalid-exclude.stdout" 2> "$FIXTURE_ROOT/invalid-exclude.stderr"; then
    fail 'inventory accepted non-empty phase/type metadata on an exclude rule'
fi
[[ ! -e "$invalid_exclude_inventory" ]] ||
    fail 'invalid exclude metadata produced an inventory file'
grep -Fq 'exclude rule must have empty phase and type' \
    "$FIXTURE_ROOT/invalid-exclude.stderr" ||
    fail 'invalid exclude metadata failure was not reported'

malicious_source_inventory="$FIXTURE_ROOT/malicious-source-inventory.tsv"
if bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "bad.name=$task12_source" \
    --output "$malicious_source_inventory" \
    > "$FIXTURE_ROOT/malicious-source.stdout" 2> "$FIXTURE_ROOT/malicious-source.stderr"; then
    fail 'inventory accepted a source name that is not a safe path component'
fi
[[ ! -e "$malicious_source_inventory" ]] ||
    fail 'malicious source name failure produced an inventory file'

malicious_phase_rules="$FIXTURE_ROOT/malicious-phase-rules.tsv"
malicious_phase_inventory="$FIXTURE_ROOT/malicious-phase-inventory.tsv"
printf '%s\n' $'include\t^docs/superpowers/specs/.*\\.md$\t../phase\tdesign\tmalicious phase' \
    > "$malicious_phase_rules"
if bash "$ARCHIVER" inventory \
    --rules "$malicious_phase_rules" \
    --source "malicious-phase-source=$task12_source" \
    --output "$malicious_phase_inventory" \
    > "$FIXTURE_ROOT/malicious-phase.stdout" 2> "$FIXTURE_ROOT/malicious-phase.stderr"; then
    fail 'inventory accepted a rule phase that is not a safe path component'
fi
[[ ! -e "$malicious_phase_inventory" ]] ||
    fail 'malicious phase failure produced an inventory file'

malicious_type_rules="$FIXTURE_ROOT/malicious-type-rules.tsv"
malicious_type_inventory="$FIXTURE_ROOT/malicious-type-inventory.tsv"
printf '%s\n' $'include\t^docs/superpowers/specs/.*\\.md$\ttask12\t../type\tmalicious type' \
    > "$malicious_type_rules"
if bash "$ARCHIVER" inventory \
    --rules "$malicious_type_rules" \
    --source "malicious-type-source=$task12_source" \
    --output "$malicious_type_inventory" \
    > "$FIXTURE_ROOT/malicious-type.stdout" 2> "$FIXTURE_ROOT/malicious-type.stderr"; then
    fail 'inventory accepted a rule type that is not a safe path component'
fi
[[ ! -e "$malicious_type_inventory" ]] ||
    fail 'malicious type failure produced an inventory file'

nul_reason_rules="$FIXTURE_ROOT/nul-reason-rules.tsv"
nul_reason_inventory="$FIXTURE_ROOT/nul-reason-inventory.tsv"
printf 'include\t^docs/superpowers/specs/.*\\.md$\ttask12\tdesign\treason with NUL\0\n' \
    > "$nul_reason_rules"
if bash "$ARCHIVER" inventory \
    --rules "$nul_reason_rules" \
    --source "nul-reason-source=$task12_source" \
    --output "$nul_reason_inventory" \
    > "$FIXTURE_ROOT/nul-reason.stdout" 2> "$FIXTURE_ROOT/nul-reason.stderr"; then
    fail 'inventory accepted a rules file containing NUL'
fi
[[ ! -e "$nul_reason_inventory" ]] ||
    fail 'NUL rules failure produced an inventory file'
grep -Fq 'rules file contains NUL' "$FIXTURE_ROOT/nul-reason.stderr" ||
    fail 'NUL rules failure was not reported'

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

tz_date_path="$task12_source/docs/superpowers/specs/tz-mtime-design.md"
write_fixture_file "$tz_date_path" 'timezone-independent mtime fixture'
touch -d '2026-08-09T23:30:00Z' "$tz_date_path"
for tz_name in UTC Asia/Shanghai; do
    tz_inventory="$FIXTURE_ROOT/tz-${tz_name//\//-}.tsv"
    TZ="$tz_name" bash "$ARCHIVER" inventory \
        --rules "$RULES" \
        --source "tz-source=$task12_source" \
        --output "$tz_inventory" \
        > "$FIXTURE_ROOT/tz-${tz_name//\//-}.stdout" \
        2> "$FIXTURE_ROOT/tz-${tz_name//\//-}.stderr"
    awk -F '\t' \
        '$1 == "tz-source" && $6 == "docs/superpowers/specs/tz-mtime-design.md" {
            found = ($9 == "2026-08-09" && $10 == "filesystem_mtime")
        }
        END { exit found ? 0 : 1 }' "$tz_inventory" ||
        fail "filesystem mtime date changed under TZ=$tz_name"
done

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

final_state_source="$(mktemp -d "$FIXTURE_ROOT/final-state-source.XXXXXX")"
init_fixture_repo "$final_state_source"
write_fixture_file "$final_state_source/docs/README.md" 'final state metadata'
write_fixture_file \
    "$final_state_source/docs/superpowers/specs/final-state-design.md" \
    'final state design'
commit_fixture_repo "$final_state_source" .
final_state_hook_bin="$FIXTURE_ROOT/final-state-hook-bin"
final_state_hook_state="$FIXTURE_ROOT/final-state-hook-state"
final_state_mutation="$final_state_source/docs/README.md"
mkdir -p -- "$final_state_hook_bin"
real_git="$(command -v git)"
write_fixture_file "$final_state_hook_bin/git" "#!/usr/bin/env bash
set -euo pipefail
real_git='$real_git'
state='$final_state_hook_state'
mutation='$final_state_mutation'
if [[ \"\$1\" == '-C' && \"\$3\" == 'status' ]]; then
    count=0
    if [[ -f \"\$state\" ]]; then
        count=\"\$(<\"\$state\")\"
    fi
    count=\$((count + 1))
    printf '%s\\n' \"\$count\" > \"\$state\"
    if [[ \"\$count\" == 2 ]]; then
        printf '%s\\n' 'final state mutation' >> \"\$mutation\"
    fi
fi
exec \"\$real_git\" \"\$@\"
"
chmod +x -- "$final_state_hook_bin/git"
final_state_inventory="$FIXTURE_ROOT/final-state-inventory.tsv"
if PATH="$final_state_hook_bin:$PATH" bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "final-state-source=$final_state_source" \
    --output "$final_state_inventory" \
    > "$FIXTURE_ROOT/final-state.stdout" 2> "$FIXTURE_ROOT/final-state.stderr"; then
    fail 'inventory published output after a final source state change'
fi
[[ ! -e "$final_state_inventory" ]] ||
    fail 'final source state failure published an inventory file'
if ! grep -Fq 'changed during inventory' "$FIXTURE_ROOT/final-state.stderr"; then
    fail 'final source state failure was not reported'
fi

final_untracked_source="$(mktemp -d "$FIXTURE_ROOT/final-untracked-source.XXXXXX")"
init_fixture_repo "$final_untracked_source"
write_fixture_file "$final_untracked_source/docs/README.md" 'final untracked metadata'
commit_fixture_repo "$final_untracked_source" docs/README.md
final_untracked_path="$final_untracked_source/docs/docs/build/axvisor/task12-untracked.log"
write_fixture_file "$final_untracked_path" 'qemu-system-aarch64: initial untracked evidence'
touch -d '2026-08-15T12:00:00Z' "$final_untracked_path"
final_untracked_hook_bin="$FIXTURE_ROOT/final-untracked-hook-bin"
final_untracked_hook_state="$FIXTURE_ROOT/final-untracked-hook-state"
mkdir -p -- "$final_untracked_hook_bin"
write_fixture_file "$final_untracked_hook_bin/git" "#!/usr/bin/env bash
set -euo pipefail
real_git='$real_git'
state='$final_untracked_hook_state'
mutation='$final_untracked_path'
if [[ \"\$1\" == '-C' && \"\$3\" == 'ls-files' && \"\$4\" == '--others' ]]; then
    count=0
    if [[ -f \"\$state\" ]]; then
        count=\"\$(<\"\$state\")\"
    fi
    count=\$((count + 1))
    printf '%s\\n' \"\$count\" > \"\$state\"
    if [[ \"\$count\" == 2 ]]; then
        printf '%s\\n' 'qemu-system-aarch64: final untracked mutation' >> \"\$mutation\"
    fi
fi
exec \"\$real_git\" \"\$@\"
"
chmod +x -- "$final_untracked_hook_bin/git"
final_untracked_inventory="$FIXTURE_ROOT/final-untracked-inventory.tsv"
if PATH="$final_untracked_hook_bin:$PATH" bash "$ARCHIVER" inventory \
    --rules "$RULES" \
    --source "final-untracked-source=$final_untracked_source" \
    --output "$final_untracked_inventory" \
    > "$FIXTURE_ROOT/final-untracked.stdout" 2> "$FIXTURE_ROOT/final-untracked.stderr"; then
    fail 'inventory published output after an untracked selected file changed'
fi
[[ ! -e "$final_untracked_inventory" ]] ||
    fail 'untracked content change produced an inventory file'
grep -Fq 'selected file changed during inventory' \
    "$FIXTURE_ROOT/final-untracked.stderr" ||
    fail 'untracked content change failure was not reported'

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
