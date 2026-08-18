#!/usr/bin/env bash

set -euo pipefail

ARCHIVE_TMP_DIR=""
ARCHIVE_OUTPUT_TMP=""
ARCHIVE_SIDECAR_TMP=""
ARCHIVE_STAGE_TMP=""

cleanup() {
    [[ -z "$ARCHIVE_TMP_DIR" ]] || rm -rf -- "$ARCHIVE_TMP_DIR"
    [[ -z "$ARCHIVE_OUTPUT_TMP" ]] || rm -f -- "$ARCHIVE_OUTPUT_TMP"
    [[ -z "$ARCHIVE_SIDECAR_TMP" ]] || rm -f -- "$ARCHIVE_SIDECAR_TMP"
    [[ -z "$ARCHIVE_STAGE_TMP" ]] || rm -rf -- "$ARCHIVE_STAGE_TMP"
}

trap cleanup EXIT

usage() {
    cat >&2 <<'EOF'
usage: archive-history-docs.sh inventory --rules FILE --source NAME=PATH... --output FILE
       archive-history-docs.sh stage --inventory FILE --destination DIR
       archive-history-docs.sh verify --inventory FILE --destination DIR
       archive-history-docs.sh delete --inventory FILE --destination DIR
EOF
    exit 2
}

die() {
    echo "archive-history-docs.sh: $*" >&2
    exit 1
}

require_value() {
    (($# >= 2)) || usage
    [[ -n "$2" ]] || die "empty value for $1"
}

canonical_existing_path() {
    realpath -e -- "$1" 2>/dev/null || die "path does not exist: $1"
}

validate_output_path() {
    local requested="$1"
    local lexical parent current component
    local -a components=()

    if [[ "$requested" == /* ]]; then
        lexical="$requested"
    else
        lexical="$PWD/$requested"
    fi
    parent="${lexical%/*}"
    [[ "$parent" == "$lexical" ]] && parent="$PWD"
    [[ -n "$parent" ]] || parent="/"

    current="/"
    IFS='/' read -r -a components <<< "${parent#/}"
    for component in "${components[@]}"; do
        [[ -z "$component" || "$component" == . ]] && continue
        if [[ "$component" == .. ]]; then
            current="$(dirname -- "$current")"
            continue
        fi
        if [[ "$current" == / ]]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        [[ -L "$current" ]] &&
            die "output parent component is symlink: $current"
    done

    [[ -L "$lexical" ]] && die "output file is symlink: $lexical"
    VALIDATED_OUTPUT_PATH="$(realpath -m -- "$lexical")"
}

validate_tsv_field() {
    local label="$1"
    local value="$2"
    local source="$3"
    local display

    if printf '%s' "$value" | LC_ALL=C grep -zq '[[:cntrl:]]'; then
        display="$(printf '%q' "$value")"
        die "source=$source $label contains ASCII control byte: $display"
    fi
}

validate_path_component() {
    local label="$1"
    local value="$2"
    local source="$3"
    local display

    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        display="$(printf '%q' "$value")"
        die "source=$source $label is not a safe path component: $display"
    fi
}

check_tracked_index_flags() {
    local source="$1"
    local repo="$2"
    local tmp_dir="$3"
    local record tag path display
    local flagged=0

    git -C "$repo" ls-files -v -z > "$tmp_dir/$source.flags-v"
    while IFS= read -r -d '' record; do
        tag="${record:0:1}"
        path="${record:2}"
        if [[ "$tag" == [[:lower:]] ]]; then
            if ((flagged == 0)); then
                echo "archive-history-docs.sh: source=$source has tracked index flags: $repo" >&2
            fi
            display="$(printf '%q' "$path")"
            printf 'assume-unchanged\t%s\n' "$display" >&2
            flagged=1
        fi
    done < "$tmp_dir/$source.flags-v"

    git -C "$repo" ls-files -t -z > "$tmp_dir/$source.flags-t"
    while IFS= read -r -d '' record; do
        tag="${record:0:1}"
        path="${record:2}"
        if [[ "$tag" == S ]]; then
            if ((flagged == 0)); then
                echo "archive-history-docs.sh: source=$source has tracked index flags: $repo" >&2
            fi
            display="$(printf '%q' "$path")"
            printf 'skip-worktree\t%s\n' "$display" >&2
            flagged=1
        fi
    done < "$tmp_dir/$source.flags-t"

    ((flagged == 0))
}

capture_candidate_snapshot() {
    local repo="$1"
    local tracked_file="$2"
    local untracked_file="$3"
    local candidates_file="$4"

    git -C "$repo" ls-files -z | LC_ALL=C sort -z > "$tracked_file"
    git -C "$repo" ls-files --others --exclude-standard -z |
        LC_ALL=C sort -z > "$untracked_file"
    LC_ALL=C sort -z -u "$tracked_file" "$untracked_file" > "$candidates_file"
}

valid_date() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$(date -u -d "$candidate" +%F 2>/dev/null || true)" == "$candidate" ]]
}

load_rules() {
    local rules_file="$1"
    local line action regex phase type reason rest regex_status

    [[ -f "$rules_file" ]] || die "rules file does not exist: $rules_file"
    if od -An -v -t x1 -- "$rules_file" | grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
        die "rules file contains NUL: $rules_file"
    fi
    RULE_ACTIONS=()
    RULE_REGEXES=()
    RULE_PHASES=()
    RULE_TYPES=()
    RULE_REASONS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue

        [[ "$line" == *$'\t'* ]] || die "rule does not have five tab-separated fields"
        action="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        [[ "$rest" == *$'\t'* ]] || die "rule does not have five tab-separated fields"
        regex="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        [[ "$rest" == *$'\t'* ]] || die "rule does not have five tab-separated fields"
        phase="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        [[ "$rest" == *$'\t'* ]] || die "rule does not have five tab-separated fields"
        type="${rest%%$'\t'*}"
        reason="${rest#*$'\t'}"
        [[ "$reason" != *$'\t'* ]] || die "rule does not have five tab-separated fields"
        validate_tsv_field rule_action "$action" rules
        validate_tsv_field rule_path_regex "$regex" rules
        validate_tsv_field rule_phase "$phase" rules
        validate_tsv_field rule_type "$type" rules
        validate_tsv_field rule_reason "$reason" rules
        [[ "$action" == include || "$action" == exclude ]] ||
            die "invalid rule action: $action"
        [[ -n "$regex" && -n "$reason" ]] || die "rule has an empty pattern or reason"
        if [[ "" =~ $regex ]]; then
            :
        else
            regex_status=$?
            ((regex_status == 2)) && die "invalid Bash regex in rule: $regex"
        fi
        if [[ "$action" == include ]]; then
            [[ -n "$phase" && -n "$type" ]] || die "include rule has an empty phase or type"
            validate_path_component rule_phase "$phase" rules
            validate_path_component rule_type "$type" rules
        else
            [[ -z "$phase" && -z "$type" ]] ||
                die "exclude rule must have empty phase and type"
        fi

        RULE_ACTIONS+=("$action")
        RULE_REGEXES+=("$regex")
        RULE_PHASES+=("$phase")
        RULE_TYPES+=("$type")
        RULE_REASONS+=("$reason")
    done < "$rules_file"

    ((${#RULE_ACTIONS[@]} > 0)) || die "rules file is empty: $rules_file"
}

classify_path() {
    local path="$1"
    local i regex_status

    CLASS_ACTION=""
    CLASS_PHASE=""
    CLASS_TYPE=""
    CLASS_REASON=""
    for ((i = 0; i < ${#RULE_ACTIONS[@]}; i++)); do
        if [[ "$path" =~ ${RULE_REGEXES[i]} ]]; then
            CLASS_ACTION="${RULE_ACTIONS[i]}"
            CLASS_PHASE="${RULE_PHASES[i]}"
            CLASS_TYPE="${RULE_TYPES[i]}"
            CLASS_REASON="${RULE_REASONS[i]}"
            return 0
        else
            regex_status=$?
            ((regex_status == 2)) &&
                die "invalid Bash regex in rule: ${RULE_REGEXES[i]}"
        fi
    done
    return 1
}

has_task12_evidence_signature() {
    local path="$1"

    LC_ALL=C grep -aEq \
        '^(qemu-system-aarch64:|VM Load @PA:|RTBENCH_[A-Z_]+|TASK[0-9]+_[A-Z_]+|RTIPC_[A-Z_]+)' \
        -- "$path"
}

file_date() {
    local base="$1"
    local full_path="$2"
    local tracked="$3"
    local repo="$4"
    local relative_path="$5"
    local candidate git_date remaining token legal_date
    local legal_count=0
    local -a date_tokens=()

    remaining="$base"
    while [[ "$remaining" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; do
        token="${BASH_REMATCH[1]}"
        date_tokens+=("$token")
        remaining="${remaining#*"$token"}"
    done
    for token in "${date_tokens[@]}"; do
        if valid_date "$token"; then
            legal_count=$((legal_count + 1))
            legal_date="$token"
        fi
    done
    if ((legal_count > 1)); then
        die "ambiguous filename dates in $base: ${date_tokens[*]}"
    elif ((legal_count == 1)); then
        printf '%s\tfilename\n' "$legal_date"
        return 0
    fi

    if [[ "$tracked" == true ]]; then
        git_date="$(git -C "$repo" log -1 --format=%cs -- "$relative_path")"
        if valid_date "$git_date"; then
            printf '%s\tgit_commit\n' "$git_date"
            return 0
        fi
    fi

    candidate="$(date -u -r "$full_path" +%F)"
    valid_date "$candidate" || die "invalid filesystem date for $full_path"
    printf '%s\tfilesystem_mtime\n' "$candidate"
}

inventory() {
    local rules_file=""
    local output_file=""
    local spec name requested_path source_root repo_root branch commit
    local tracked_file untracked_file candidates_file rel full_path target_path
    local tracked base phase type date date_source size digest archived
    local selected excluded unmatched skipped tracked_status odd_display
    local output_tmp sidecar_file source_index
    local sidecar_tmp rules_digest rules_repo_root rules_commit
    local -a source_specs=()
    local -a source_names=()
    local -a source_roots=()
    local -a source_branches=()
    local -a source_commits=()
    local -A seen_sources=()
    local -A seen_archived=()
    local tmp_dir

    check_output_outside_sources() {
        local check_index check_root

        for check_index in "${!source_roots[@]}"; do
            check_root="${source_roots[check_index]}"
            if [[ "$check_root" == / || "$output_file" == "$check_root" ||
                "$output_file" == "$check_root/"* || "$sidecar_file" == "$check_root" ||
                "$sidecar_file" == "$check_root/"* ]]; then
                die "output must be outside source root: $output_file (source=${source_names[check_index]} root=$check_root)"
            fi
        done
    }

    check_candidate_snapshots() {
        local check_index check_name check_root
        local final_tracked final_untracked final_candidates

        for check_index in "${!source_names[@]}"; do
            check_name="${source_names[check_index]}"
            check_root="${source_roots[check_index]}"
            final_tracked="$tmp_dir/$check_name.final.tracked"
            final_untracked="$tmp_dir/$check_name.final.untracked"
            final_candidates="$tmp_dir/$check_name.final.candidates"
            capture_candidate_snapshot "$check_root" "$final_tracked" "$final_untracked" "$final_candidates"
            if ! cmp -s "$tmp_dir/$check_name.candidates" "$final_candidates"; then
                die "source=$check_name candidate set changed during inventory"
            fi
        done
    }

    check_selected_records() {
        local record_source record_source_root record_branch record_commit record_tracked
        local record_path record_phase record_type record_date record_date_source
        local record_size record_digest record_archived
        local check_index check_index_candidate check_root selected_path current_size current_digest

        while IFS=$'\t' read -r record_source record_source_root record_branch record_commit \
            record_tracked record_path record_phase record_type record_date record_date_source \
            record_size record_digest record_archived; do
            [[ -n "$record_source" ]] || continue
            check_index=-1
            for check_index_candidate in "${!source_names[@]}"; do
                if [[ "${source_names[check_index_candidate]}" == "$record_source" ]]; then
                    check_index="$check_index_candidate"
                    break
                fi
            done
            [[ "$check_index" != -1 ]] ||
                die "source=$record_source selected record has unknown source during inventory"
            check_root="${source_roots[check_index]}"
            selected_path="$(realpath -e -- "$check_root/$record_path" 2>/dev/null || true)"
            if [[ -z "$selected_path" || "$selected_path" != "$check_root"/* || ! -f "$selected_path" ]]; then
                die "source=$record_source selected file changed during inventory: $record_path"
            fi
            current_size="$(stat -c '%s' -- "$selected_path")"
            current_digest="$(sha256sum -b -- "$selected_path")"
            current_digest="${current_digest%% *}"
            [[ "$current_size" == "$record_size" && "$current_digest" == "$record_digest" ]] ||
                die "source=$record_source selected file changed during inventory: $record_path"
        done < "$tmp_dir/records.tsv"
    }

    check_final_state() {
        local check_index check_root current_root current_branch current_commit current_status
        local check_name

        validate_output_path "$output_file"
        [[ "$VALIDATED_OUTPUT_PATH" == "$output_file" ]] ||
            die "output path changed during inventory: $output_file"
        validate_output_path "$sidecar_file"
        [[ "$VALIDATED_OUTPUT_PATH" == "$sidecar_file" ]] ||
            die "rules sidecar path changed during inventory: $sidecar_file"
        [[ -e "$output_file" && ! -f "$output_file" ]] &&
            die "output path is not a regular file: $output_file"
        [[ -e "$sidecar_file" && ! -f "$sidecar_file" ]] &&
            die "rules sidecar path is not a regular file: $sidecar_file"
        check_output_outside_sources

        check_candidate_snapshots
        check_selected_records
        for check_index in "${!source_roots[@]}"; do
            check_name="${source_names[check_index]}"
            check_root="${source_roots[check_index]}"
            current_root="$(git -C "$check_root" rev-parse --show-toplevel 2>/dev/null)" ||
                die "source=$check_name source root changed during inventory: $check_root"
            current_root="$(canonical_existing_path "$current_root")"
            [[ "$current_root" == "$check_root" ]] ||
                die "source=$check_name source root changed during inventory: $check_root"
            current_branch="$(git -C "$check_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
                die "source=$check_name branch changed during inventory: $check_root"
            [[ "$current_branch" == "${source_branches[check_index]}" ]] ||
                die "source=$check_name branch changed during inventory: $check_root"
            current_commit="$(git -C "$check_root" rev-parse --verify HEAD 2>/dev/null)" ||
                die "source=$check_name HEAD changed during inventory: $check_root"
            [[ "$current_commit" == "${source_commits[check_index]}" ]] ||
                die "source=$check_name HEAD changed during inventory: $check_root"
            current_status="$(git -C "$check_root" status --porcelain=v1 --untracked-files=no)"
            [[ -z "$current_status" ]] ||
                die "source=$check_name tracked worktree changed during inventory: $check_root"
            if ! check_tracked_index_flags "$check_name" "$check_root" "$tmp_dir"; then
                die "source=$check_name index flags changed during inventory: $check_root"
            fi
        done
    }

    while (($#)); do
        case "$1" in
            --rules)
                require_value "$@"
                rules_file="$2"
                shift 2
                ;;
            --source)
                require_value "$@"
                source_specs+=("$2")
                shift 2
                ;;
            --output)
                require_value "$@"
                output_file="$2"
                shift 2
                ;;
            *)
                usage
                ;;
        esac
    done

    [[ -n "$rules_file" && -n "$output_file" && ${#source_specs[@]} -gt 0 ]] || usage
    validate_output_path "$output_file"
    output_file="$VALIDATED_OUTPUT_PATH"
    sidecar_file="$output_file.rules.sha256"
    validate_output_path "$sidecar_file"
    sidecar_file="$VALIDATED_OUTPUT_PATH"
    rules_file="$(canonical_existing_path "$rules_file")"
    load_rules "$rules_file"
    rules_digest="$(sha256sum -b -- "$rules_file")"
    rules_digest="${rules_digest%% *}"
    rules_repo_root="$(git -C "$(dirname -- "$rules_file")" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$rules_repo_root" ]]; then
        rules_repo_root="$(canonical_existing_path "$rules_repo_root")"
        rules_commit="$(git -C "$rules_repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
    else
        rules_repo_root="untracked"
        rules_commit="untracked"
    fi
    validate_tsv_field rules_path "$rules_file" rules
    validate_tsv_field rules_sha256 "$rules_digest" rules
    validate_tsv_field rules_repo_root "$rules_repo_root" rules
    validate_tsv_field rules_commit "$rules_commit" rules

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/archive-history-docs.XXXXXX")"
    ARCHIVE_TMP_DIR="$tmp_dir"

    for spec in "${source_specs[@]}"; do
        [[ "$spec" == *=* ]] || die "source must be NAME=PATH: $spec"
        name="${spec%%=*}"
        requested_path="${spec#*=}"
        validate_path_component source_name "$name" "$name"
        [[ -z "${seen_sources[$name]+set}" ]] || die "duplicate source name: $name"
        seen_sources["$name"]=1

        requested_path="$(canonical_existing_path "$requested_path")"
        [[ -d "$requested_path" ]] || die "source is not a directory: $requested_path"
        repo_root="$(git -C "$requested_path" rev-parse --show-toplevel 2>/dev/null)" ||
            die "source is not a git repository: $requested_path"
        repo_root="$(canonical_existing_path "$repo_root")"
        source_root="$repo_root"
        branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
            die "source has detached HEAD: $source_root"
        commit="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null)" ||
            die "source has no commit: $source_root"

        validate_tsv_field source "$name" "$name"
        validate_tsv_field source_root "$source_root" "$name"
        validate_tsv_field branch "$branch" "$name"
        validate_tsv_field commit "$commit" "$name"

        tracked_status="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=no)"
        if [[ -n "$tracked_status" ]]; then
            echo "archive-history-docs.sh: source=$name has tracked worktree changes: $source_root" >&2
            printf '%s\n' "$tracked_status" >&2
            exit 1
        fi
        check_tracked_index_flags "$name" "$repo_root" "$tmp_dir" || exit 1

        source_names+=("$name")
        source_roots+=("$source_root")
        source_branches+=("$branch")
        source_commits+=("$commit")
    done

    check_output_outside_sources
    [[ -e "$output_file" && ! -f "$output_file" ]] &&
        die "output path is not a regular file: $output_file"

    output_tmp="$tmp_dir/inventory.tsv"
    printf '%s\n' \
        $'source\tsource_root\tbranch\tcommit\ttracked\toriginal_path\tphase\ttype\tdate\tdate_source\tsize\tsha256\tarchived_path' \
        > "$output_tmp"
    : > "$tmp_dir/records.tsv"

    for source_index in "${!source_names[@]}"; do
        name="${source_names[source_index]}"
        source_root="${source_roots[source_index]}"
        repo_root="$source_root"
        branch="${source_branches[source_index]}"
        commit="${source_commits[source_index]}"

        tracked_file="$tmp_dir/$name.tracked"
        untracked_file="$tmp_dir/$name.untracked"
        candidates_file="$tmp_dir/$name.candidates"
        capture_candidate_snapshot "$repo_root" "$tracked_file" "$untracked_file" "$candidates_file"

        declare -A tracked_paths=()
        while IFS= read -r -d '' rel; do
            tracked_paths["$rel"]=1
        done < "$tracked_file"

        selected=0
        excluded=0
        unmatched=0
        skipped=0
        while IFS= read -r -d '' rel; do
            case "$rel" in
                *.md|*.txt|*.log|*.json|*.csv|*.tsv|*.png) ;;
                *)
                    ((skipped += 1))
                    continue
                    ;;
            esac
            case "$rel" in
                *$'\t'*|*$'\r'*|*$'\n'*)
                    odd_display="$(printf '%q' "$rel")"
                    die "source=$name candidate path contains TAB/newline or CR: $odd_display"
                    ;;
            esac

            full_path="$repo_root/$rel"
            target_path="$(realpath -e -- "$full_path" 2>/dev/null || true)"
            if [[ -z "$target_path" || "$target_path" != "$repo_root"/* || ! -f "$target_path" ]]; then
                ((skipped += 1))
                continue
            fi

            if ! classify_path "$rel"; then
                ((unmatched += 1))
                continue
            fi
            if [[ "$CLASS_ACTION" == exclude ]]; then
                ((excluded += 1))
                continue
            fi
            if [[ "$CLASS_PHASE" == task12 && "$CLASS_TYPE" == evidence &&
                "$rel" == docs/docs/build/axvisor/* ]] &&
                ! has_task12_evidence_signature "$target_path"; then
                ((unmatched += 1))
                continue
            fi
            if [[ -n "${tracked_paths[$rel]+set}" ]]; then
                tracked=true
            else
                tracked=false
            fi
            base="${rel##*/}"
            IFS=$'\t' read -r date date_source < <(file_date "$base" "$target_path" "$tracked" "$repo_root" "$rel")
            phase="$CLASS_PHASE"
            type="$CLASS_TYPE"
            size="$(stat -c '%s' -- "$target_path")"
            digest="$(sha256sum -b -- "$target_path")"
            digest="${digest%% *}"
            archived="$phase/$type/$date/$name/$rel"
            [[ -z "${seen_archived[$archived]+set}" ]] ||
                die "archive path collision: $archived"
            seen_archived["$archived"]=1

            validate_tsv_field source "$name" "$name"
            validate_tsv_field source_root "$source_root" "$name"
            validate_tsv_field branch "$branch" "$name"
            validate_tsv_field commit "$commit" "$name"
            validate_tsv_field tracked "$tracked" "$name"
            validate_tsv_field original_path "$rel" "$name"
            validate_tsv_field phase "$phase" "$name"
            validate_tsv_field type "$type" "$name"
            validate_tsv_field date "$date" "$name"
            validate_tsv_field date_source "$date_source" "$name"
            validate_tsv_field size "$size" "$name"
            validate_tsv_field sha256 "$digest" "$name"
            validate_tsv_field archived_path "$archived" "$name"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$name" "$source_root" "$branch" "$commit" "$tracked" "$rel" \
                "$phase" "$type" "$date" "$date_source" "$size" "$digest" "$archived" \
                >> "$tmp_dir/records.tsv"
            ((selected += 1))
        done < "$candidates_file"

        echo "inventory: source=$name selected=$selected excluded=$excluded unmatched=$unmatched skipped=$skipped" >&2
    done

    LC_ALL=C sort -t $'\t' -k13,13 "$tmp_dir/records.tsv" >> "$output_tmp"
    printf 'rules_path\t%s\nrules_sha256\t%s\nrules_repo_root\t%s\nrules_commit\t%s\n' \
        "$rules_file" "$rules_digest" "$rules_repo_root" "$rules_commit" \
        > "$tmp_dir/rules.sidecar"
    check_final_state
    sidecar_tmp="$(mktemp "$(dirname -- "$sidecar_file")/.$(basename -- "$sidecar_file").tmp.XXXXXX")"
    ARCHIVE_SIDECAR_TMP="$sidecar_tmp"
    cp -- "$tmp_dir/rules.sidecar" "$sidecar_tmp"
    output_tmp_target="$(mktemp "$(dirname -- "$output_file")/.$(basename -- "$output_file").tmp.XXXXXX")"
    ARCHIVE_OUTPUT_TMP="$output_tmp_target"
    cp -- "$output_tmp" "$output_tmp_target"
    mv -f -- "$sidecar_tmp" "$sidecar_file"
    ARCHIVE_SIDECAR_TMP=""
    mv -f -- "$output_tmp_target" "$output_file"
    ARCHIVE_OUTPUT_TMP=""
}

archive_init_tmp() {
    [[ -n "$ARCHIVE_TMP_DIR" ]] || ARCHIVE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/archive-history-docs.XXXXXX")"
}

archive_field_error() {
    local line_number="$1"
    local field_name="$2"
    local value="$3"
    die "inventory line $line_number $field_name is invalid: $(printf '%q' "$value")"
}

validate_archive_relative_path() {
    local label="$1"
    local path="$2"
    local component
    local -a components=()

    [[ -n "$path" && "$path" != /* ]] || die "$label is not a safe relative path: $(printf '%q' "$path")"
    IFS='/' read -r -a components <<< "$path"
    ((${#components[@]} > 0)) || die "$label is empty"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] ||
            die "$label contains unsafe path component: $(printf '%q' "$path")"
    done
}

path_has_symlink_component() {
    local root="$1"
    local relative_path="$2"
    local component current="$root"
    local -a components=()

    IFS='/' read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        current="$current/$component"
        [[ ! -L "$current" ]] || return 1
    done
}

validate_archive_source_file() {
    local source_name="$1"
    local source_root="$2"
    local original_path="$3"
    local source_path source_real

    validate_archive_relative_path "source=$source_name original_path" "$original_path"
    path_has_symlink_component "$source_root" "$original_path" ||
        die "source=$source_name original_path traverses a symlink: $original_path"
    source_path="$source_root/$original_path"
    [[ -f "$source_path" && ! -L "$source_path" ]] ||
        die "source=$source_name selected file is not a regular file: $source_path"
    source_real="$(realpath -e -- "$source_path" 2>/dev/null || true)"
    [[ "$source_real" == "$source_root"/* && "$source_real" == "$source_path" ]] ||
        die "source=$source_name selected file is outside source root: $original_path"
    printf '%s\n' "$source_path"
}

validate_archive_destination() {
    local requested="$1"
    local source_name source_root parent

    validate_output_path "$requested"
    ARCHIVE_DESTINATION="$VALIDATED_OUTPUT_PATH"
    [[ "$ARCHIVE_DESTINATION" != / ]] || die "destination must not be /"
    parent="$(dirname -- "$ARCHIVE_DESTINATION")"
    [[ -d "$parent" && ! -L "$parent" ]] ||
        die "destination parent is not a regular directory: $parent"

    for source_name in "${ARCHIVE_SOURCE_NAMES[@]}"; do
        source_root="${ARCHIVE_SOURCE_ROOTS[$source_name]}"
        if [[ "$ARCHIVE_DESTINATION" == "$source_root" ||
            "$ARCHIVE_DESTINATION" == "$source_root/"* ||
            "$source_root" == "$ARCHIVE_DESTINATION" ||
            "$source_root" == "$ARCHIVE_DESTINATION/"* ]]; then
            die "destination must be outside source root: $ARCHIVE_DESTINATION (source=$source_name root=$source_root)"
        fi
    done

    if [[ -e "$ARCHIVE_DESTINATION" || -L "$ARCHIVE_DESTINATION" ]]; then
        [[ -d "$ARCHIVE_DESTINATION" && ! -L "$ARCHIVE_DESTINATION" ]] ||
            die "destination is not a regular directory: $ARCHIVE_DESTINATION"
    fi
}

read_archive_rules_sidecar() {
    local sidecar_file="$1"
    local line key value
    local -A sidecar_values=()

    [[ -f "$sidecar_file" && ! -L "$sidecar_file" ]] ||
        die "rules sidecar is not a regular file: $sidecar_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* ]] || die "rules sidecar line has no TAB: $sidecar_file"
        key="${line%%$'\t'*}"
        value="${line#*$'\t'}"
        [[ "$value" != *$'\t'* && -n "$key" && -n "$value" ]] ||
            die "rules sidecar line is malformed: $sidecar_file"
        validate_tsv_field "rules sidecar $key" "$value" rules
        [[ -z "${sidecar_values[$key]+set}" ]] || die "rules sidecar repeats key: $key"
        case "$key" in
            rules_path|rules_sha256|rules_repo_root|rules_commit) ;;
            *) die "rules sidecar has unknown key: $key" ;;
        esac
        sidecar_values["$key"]="$value"
    done < "$sidecar_file"
    for key in rules_path rules_sha256 rules_repo_root rules_commit; do
        [[ -n "${sidecar_values[$key]+set}" ]] || die "rules sidecar is missing key: $key"
    done

    ARCHIVE_RULES_PATH="${sidecar_values[rules_path]}"
    ARCHIVE_RULES_SHA256="${sidecar_values[rules_sha256]}"
    ARCHIVE_RULES_REPO_ROOT="${sidecar_values[rules_repo_root]}"
    ARCHIVE_RULES_COMMIT="${sidecar_values[rules_commit]}"
    [[ "$ARCHIVE_RULES_PATH" == /* ]] || die "rules_path is not absolute: $ARCHIVE_RULES_PATH"
    [[ "$ARCHIVE_RULES_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "rules_sha256 is not a SHA-256 digest: $ARCHIVE_RULES_SHA256"
    [[ "$ARCHIVE_RULES_COMMIT" == untracked || "$ARCHIVE_RULES_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "rules_commit is not a commit or untracked: $ARCHIVE_RULES_COMMIT"
    [[ "$ARCHIVE_RULES_REPO_ROOT" == untracked || "$ARCHIVE_RULES_REPO_ROOT" == /* ]] ||
        die "rules_repo_root is not absolute or untracked: $ARCHIVE_RULES_REPO_ROOT"
    [[ ! -L "$ARCHIVE_RULES_PATH" ]] || die "rules file is symlink: $ARCHIVE_RULES_PATH"
    ARCHIVE_RULES_PATH="$(canonical_existing_path "$ARCHIVE_RULES_PATH")"
    [[ -f "$ARCHIVE_RULES_PATH" ]] || die "rules path is not a regular file: $ARCHIVE_RULES_PATH"
    local actual_digest
    actual_digest="$(sha256sum -b -- "$ARCHIVE_RULES_PATH")"
    actual_digest="${actual_digest%% *}"
    [[ "$actual_digest" == "$ARCHIVE_RULES_SHA256" ]] ||
        die "rules SHA-256 differs from sidecar: $ARCHIVE_RULES_PATH"
}

load_archive_inventory() {
    local requested_inventory="$1"
    local line line_number=0 field_index source source_root branch commit tracked original_path
    local phase type date date_source size sha256 archived_path expected_archived
    local source_root_real key source_path
    local -a fields=()
    local inventory_sidecar

    archive_init_tmp
    [[ ! -L "$requested_inventory" ]] || die "inventory file is symlink: $requested_inventory"
    ARCHIVE_INVENTORY_FILE="$(canonical_existing_path "$requested_inventory")"
    [[ -f "$ARCHIVE_INVENTORY_FILE" ]] || die "inventory is not a regular file: $ARCHIVE_INVENTORY_FILE"
    if od -An -v -t x1 -- "$ARCHIVE_INVENTORY_FILE" | grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
        die "inventory contains NUL: $ARCHIVE_INVENTORY_FILE"
    fi

    ARCHIVE_RECORDS_RAW="$ARCHIVE_TMP_DIR/inventory.records.raw"
    ARCHIVE_RECORDS_FILE="$ARCHIVE_TMP_DIR/inventory.records"
    : > "$ARCHIVE_RECORDS_RAW"
    ARCHIVE_SOURCE_NAMES=()
    declare -gA ARCHIVE_SOURCE_ROOTS=()
    declare -gA ARCHIVE_SOURCE_BRANCHES=()
    declare -gA ARCHIVE_SOURCE_COMMITS=()
    declare -gA ARCHIVE_SEEN_ARCHIVED=()
    declare -gA ARCHIVE_SEEN_SOURCE_PATHS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if ((line_number == 1)); then
            [[ "$line" == $'source\tsource_root\tbranch\tcommit\ttracked\toriginal_path\tphase\ttype\tdate\tdate_source\tsize\tsha256\tarchived_path' ]] ||
                die "inventory header must contain exactly 13 required columns"
            continue
        fi
        [[ -n "$line" ]] || die "inventory line $line_number is empty"
        IFS=$'\t' read -r -a fields <<< "$line"
        ((${#fields[@]} == 13)) || die "inventory line $line_number has ${#fields[@]} fields; expected 13"
        for field_index in "${!fields[@]}"; do
            [[ -n "${fields[field_index]}" ]] ||
                archive_field_error "$line_number" "field_$((field_index + 1))" "${fields[field_index]}"
            validate_tsv_field "field_$((field_index + 1))" "${fields[field_index]}" "line $line_number"
        done

        source="${fields[0]}"
        source_root="${fields[1]}"
        branch="${fields[2]}"
        commit="${fields[3]}"
        tracked="${fields[4]}"
        original_path="${fields[5]}"
        phase="${fields[6]}"
        type="${fields[7]}"
        date="${fields[8]}"
        date_source="${fields[9]}"
        size="${fields[10]}"
        sha256="${fields[11]}"
        archived_path="${fields[12]}"

        validate_path_component source "$source" "$source"
        [[ "$source_root" == /* ]] || die "source=$source source_root is not absolute: $source_root"
        [[ ! -L "$source_root" ]] || die "source=$source source_root is symlink: $source_root"
        source_root_real="$(canonical_existing_path "$source_root")"
        [[ "$source_root_real" == "$source_root" && -d "$source_root" ]] ||
            die "source=$source source_root is not normalized directory: $source_root"
        [[ "$branch" != *$'\n'* && "$branch" != *$'\r'* && "$branch" != *$'\t'* ]] ||
            die "source=$source branch contains a control byte"
        [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "source=$source commit is invalid: $commit"
        [[ "$tracked" == true || "$tracked" == false ]] || die "source=$source tracked is not true/false: $tracked"
        validate_archive_relative_path "source=$source original_path" "$original_path"
        validate_path_component phase "$phase" "$source"
        validate_path_component type "$type" "$source"
        valid_date "$date" || die "source=$source date is invalid: $date"
        [[ "$date_source" == filename || "$date_source" == git_commit || "$date_source" == filesystem_mtime ]] ||
            die "source=$source date_source is invalid: $date_source"
        [[ "$size" =~ ^(0|[1-9][0-9]*)$ ]] || die "source=$source size is invalid: $size"
        [[ "$sha256" =~ ^[0-9a-fA-F]{64}$ ]] || die "source=$source sha256 is invalid: $sha256"
        validate_archive_relative_path "source=$source archived_path" "$archived_path"
        expected_archived="$phase/$type/$date/$source/$original_path"
        [[ "$archived_path" == "$expected_archived" ]] ||
            die "source=$source archived_path does not match inventory metadata: $archived_path"

        if [[ -z "${ARCHIVE_SOURCE_ROOTS[$source]+set}" ]]; then
            ARCHIVE_SOURCE_NAMES+=("$source")
            ARCHIVE_SOURCE_ROOTS["$source"]="$source_root"
            ARCHIVE_SOURCE_BRANCHES["$source"]="$branch"
            ARCHIVE_SOURCE_COMMITS["$source"]="$commit"
        else
            [[ "${ARCHIVE_SOURCE_ROOTS[$source]}" == "$source_root" &&
                "${ARCHIVE_SOURCE_BRANCHES[$source]}" == "$branch" &&
                "${ARCHIVE_SOURCE_COMMITS[$source]}" == "$commit" ]] ||
                die "source=$source has inconsistent root, branch, or commit"
        fi
        key="$source\t$original_path"
        [[ -z "${ARCHIVE_SEEN_SOURCE_PATHS[$key]+set}" ]] ||
            die "source=$source original_path is duplicated: $original_path"
        [[ -z "${ARCHIVE_SEEN_ARCHIVED[$archived_path]+set}" ]] ||
            die "archived_path is duplicated: $archived_path"
        ARCHIVE_SEEN_SOURCE_PATHS["$key"]=1
        ARCHIVE_SEEN_ARCHIVED["$archived_path"]=1
        source_path="$(validate_archive_source_file "$source" "$source_root" "$original_path")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$source" "$source_root" "$branch" "$commit" "$tracked" "$original_path" \
            "$phase" "$type" "$date" "$date_source" "$size" "$sha256" "$archived_path" \
            >> "$ARCHIVE_RECORDS_RAW"
    done < "$ARCHIVE_INVENTORY_FILE"
    ((line_number >= 1)) || die "inventory is empty"
    LC_ALL=C sort -t $'\t' -k13,13 "$ARCHIVE_RECORDS_RAW" > "$ARCHIVE_RECORDS_FILE"

    inventory_sidecar="${ARCHIVE_INVENTORY_FILE}.rules.sha256"
    [[ ! -L "$inventory_sidecar" ]] || die "rules sidecar is symlink: $inventory_sidecar"
    inventory_sidecar="$(canonical_existing_path "$inventory_sidecar")"
    ARCHIVE_INVENTORY_SIDECAR="$inventory_sidecar"
    read_archive_rules_sidecar "$inventory_sidecar"
}

check_archive_source_states() {
    local source_name source_root expected_branch expected_commit current_root current_branch current_commit
    local status_line candidate_file candidates_file record_source record_path source_path
    local current_size current_sha candidate_present
    local -A candidate_paths=()

    declare -gA ARCHIVE_CANDIDATE_FILES=()
    ARCHIVE_CANDIDATE_FILES=()
    for source_name in "${ARCHIVE_SOURCE_NAMES[@]}"; do
        source_root="${ARCHIVE_SOURCE_ROOTS[$source_name]}"
        expected_branch="${ARCHIVE_SOURCE_BRANCHES[$source_name]}"
        expected_commit="${ARCHIVE_SOURCE_COMMITS[$source_name]}"
        current_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
        current_root="$(realpath -e -- "$current_root" 2>/dev/null || true)"
        [[ "$current_root" == "$source_root" ]] || die "source=$source_name source root changed: $source_root"
        current_branch="$(git -C "$source_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        [[ "$current_branch" == "$expected_branch" ]] || die "source=$source_name branch changed: $source_root"
        current_commit="$(git -C "$source_root" rev-parse --verify HEAD 2>/dev/null || true)"
        [[ "$current_commit" == "$expected_commit" ]] || die "source=$source_name HEAD changed: $source_root"
        status_line="$(git -C "$source_root" status --porcelain=v1 --untracked-files=no)"
        [[ -z "$status_line" ]] || die "source=$source_name tracked worktree changed (dirty): $source_root\n$status_line"
        if ! check_tracked_index_flags "$source_name" "$source_root" "$ARCHIVE_TMP_DIR"; then
            die "source=$source_name has tracked index flags: $source_root"
        fi

        candidate_file="$ARCHIVE_TMP_DIR/$source_name.candidates.before"
        capture_candidate_snapshot "$source_root" \
            "$ARCHIVE_TMP_DIR/$source_name.tracked.before" \
            "$ARCHIVE_TMP_DIR/$source_name.untracked.before" \
            "$candidate_file"
        ARCHIVE_CANDIDATE_FILES["$source_name"]="$candidate_file"
        candidate_paths=()
        while IFS= read -r -d '' candidate_present; do
            candidate_paths["$candidate_present"]=1
        done < "$candidate_file"
        while IFS=$'\t' read -r record_source _ _ _ _ record_path _; do
            [[ "$record_source" == "$source_name" ]] || continue
            [[ -n "${candidate_paths[$record_path]+set}" ]] ||
                die "source=$source_name candidate snapshot is missing: $record_path"
            source_path="$(validate_archive_source_file "$source_name" "$source_root" "$record_path")"
            current_size="$(stat -c '%s' -- "$source_path")"
            current_sha="$(sha256sum -b -- "$source_path")"
            current_sha="${current_sha%% *}"
            local expected_size expected_sha
            IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ expected_size expected_sha _ <<< \
                "$(awk -F '\t' -v source="$source_name" -v path="$record_path" \
                    '$1 == source && $6 == path { print; exit }' "$ARCHIVE_RECORDS_FILE")"
            [[ "$current_size" == "$expected_size" && "$current_sha" == "$expected_sha" ]] ||
                die "source=$source_name selected file changed: $record_path"
        done < "$ARCHIVE_RECORDS_FILE"
    done
}

check_archive_candidate_stability() {
    local source_name source_root after_file
    for source_name in "${ARCHIVE_SOURCE_NAMES[@]}"; do
        source_root="${ARCHIVE_SOURCE_ROOTS[$source_name]}"
        after_file="$ARCHIVE_TMP_DIR/$source_name.candidates.after"
        capture_candidate_snapshot "$source_root" \
            "$ARCHIVE_TMP_DIR/$source_name.tracked.after" \
            "$ARCHIVE_TMP_DIR/$source_name.untracked.after" \
            "$after_file"
        cmp -s "${ARCHIVE_CANDIDATE_FILES[$source_name]}" "$after_file" ||
            die "source=$source_name candidate snapshot changed during stage"
    done
}

build_archive_manifest() {
    local output_file="$1"
    local generated_at="$2"

    jq -Rn \
        --arg generated_at "$generated_at" \
        --arg rules_path "$ARCHIVE_RULES_PATH" \
        --arg rules_sha256 "$ARCHIVE_RULES_SHA256" \
        --arg sidecar rules.sha256 \
        '
        [inputs | split("\t") |
            {source: .[0], source_root: .[1], branch: .[2], commit: .[3],
             tracked: (.[4] == "true"), original_path: .[5], phase: .[6],
             type: .[7], date: .[8], date_source: .[9], size: (.[10] | tonumber),
             sha256: .[11], archived_path: .[12]}] as $raw |
        ($raw | group_by(.sha256) | map(select(length >= 2) |
            {key: .[0].sha256, value: .[0].sha256}) | from_entries) as $duplicates |
        ($raw | map(. + {duplicate_group: ($duplicates[.sha256] // null)})) as $entries |
        {
            schema_version: 1,
            generated_at: $generated_at,
            rules: {path: $rules_path, sha256: $rules_sha256, sidecar: $sidecar},
            sources: ($raw | map({name: .source, root: .source_root, branch: .branch, commit: .commit}) |
                unique_by(.name) | sort_by(.name)),
            entries: $entries
        }
        ' "$ARCHIVE_RECORDS_FILE" > "$output_file"
}

markdown_escape() {
    local value="$1"
    jq -Rn --arg value "$value" '$value | gsub("[\\\\|`\\[\\]]"; "\\\\&")'
}

build_archive_index() {
    local manifest_file="$1"
    local rules_file="$2"
    local output_file="$3"
    local rules_json="$ARCHIVE_TMP_DIR/rules.json"

    jq -Rn --slurpfile manifest "$manifest_file" --rawfile rules "$rules_file" \
        '[$rules | split("\n")[] | select(length > 0 and (startswith("#") | not)) | split("\t") |
          {action: .[0], pattern: .[1], phase: .[2], type: .[3], reason: .[4]}]' \
        > "$rules_json"
    {
        printf '%s\n\n' '# Historical Documentation Archive'
        printf '%s\n\n' 'This archive is byte-identical to the verified source files recorded in `manifest.json`.'
        printf '%s\n\n' '## Sources'
        printf '%s\n' '| Source | Root | Branch | Commit |' '|---|---|---|---|'
        jq -r '.sources[] | "| " + (.name | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.root | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.branch | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.commit | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " |"' "$manifest_file"
        printf '\n%s\n\n' '## Rules Summary'
        printf '%s\n\n' "Rules path: \`$(markdown_escape "$ARCHIVE_RULES_PATH")\`" \
            "Rules SHA-256: \`$ARCHIVE_RULES_SHA256\`" \
            'The ordered rules below are the classification decisions captured by `rules.sha256`.'
        printf '%s\n' '| Action | Pattern | Phase | Type | Reason |' '|---|---|---|---|---|'
        jq -r '.[] | "| " + (.action | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.pattern | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.phase | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.type | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.reason | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " |"' "$rules_json"
        printf '\n%s\n\n' '## Summary'
        printf 'Total entries: %s\n\n' "$(jq -r '.entries | length' "$manifest_file")"
        printf '%s\n' '| Phase | Type | Count |' '|---|---|---|'
        jq -r '.entries | group_by([.phase, .type])[] | [.[0].phase, .[0].type, length] |
            "| " + (.[0] | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.[1] | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.[2] | tostring) + " |"' "$manifest_file"
        printf '\n%s\n\n' '## Entries'
        printf '%s\n' '| Phase | Type | Date | Source | Original Path | Archive Link |' '|---|---|---|---|---|---|'
        jq -r '.entries | sort_by([.phase, .type, .date, .source, .original_path])[] |
            ("| " + (.phase | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.type | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.date | gsub("[\\\\|`\\[\\]]"; "\\\\&")) +
             " | " + (.source | gsub("[\\\\|`\\[\\]]"; "\\\\&")) + " | " + (.original_path | gsub("[\\\\|`\\[\\]]"; "\\\\&")) +
             " | [open]\\(" + (.archived_path | @uri) + "\\) |")' "$manifest_file"
        printf '\n%s\n\n' '## Link Map'
        printf '%s\n' 'Archive links are represented by the relative paths in the Entries table; no archived source file is rewritten.'
    } > "$output_file"
}

stage_destination_precheck() {
    local entry relative
    [[ -e "$ARCHIVE_DESTINATION" ]] || return 0
    while IFS= read -r -d '' entry; do
        [[ ! -L "$entry" ]] || die "existing destination contains symlink: ${entry#"$ARCHIVE_DESTINATION/"}"
        [[ -f "$entry" ]] || continue
        relative="${entry#"$ARCHIVE_DESTINATION/"}"
        if [[ -n "${ARCHIVE_SEEN_ARCHIVED[$relative]+set}" ]]; then
            die "archive path collision: $relative"
        fi
    done < <(find -P "$ARCHIVE_DESTINATION" -mindepth 1 -print0 | LC_ALL=C sort -z)
    while IFS= read -r -d '' entry; do
        relative="${entry#"$ARCHIVE_DESTINATION/"}"
        [[ "$relative" == migration-inventory.tsv ]] ||
            die "existing destination contains unexpected entry: $entry"
        [[ -f "$entry" && ! -L "$entry" ]] ||
            die "existing destination inventory is not a regular file: $entry"
        cmp -s "$ARCHIVE_INVENTORY_FILE" "$entry" ||
            die "existing destination migration-inventory.tsv differs from inventory"
    done < <(find -P "$ARCHIVE_DESTINATION" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
}

verify_archive_tree() {
    local entry relative allowed expected_path
    local expected_paths="$ARCHIVE_TMP_DIR/expected-archive-paths"
    local actual_paths="$ARCHIVE_TMP_DIR/actual-archive-paths"

    [[ -d "$ARCHIVE_DESTINATION" && ! -L "$ARCHIVE_DESTINATION" ]] ||
        die "destination does not exist as a regular directory: $ARCHIVE_DESTINATION"
    while IFS= read -r -d '' entry; do
        [[ ! -L "$entry" ]] || die "archive tree contains symlink: $entry"
    done < <(find -P "$ARCHIVE_DESTINATION" -mindepth 1 -print0 | LC_ALL=C sort -z)
    [[ -f "$ARCHIVE_DESTINATION/migration-inventory.tsv" && ! -L "$ARCHIVE_DESTINATION/migration-inventory.tsv" ]] ||
        die "archive is missing migration-inventory.tsv"
    [[ -f "$ARCHIVE_DESTINATION/rules.sha256" && ! -L "$ARCHIVE_DESTINATION/rules.sha256" ]] ||
        die "archive is missing rules.sha256"
    [[ -f "$ARCHIVE_DESTINATION/manifest.json" && ! -L "$ARCHIVE_DESTINATION/manifest.json" ]] ||
        die "archive is missing manifest.json"
    [[ -f "$ARCHIVE_DESTINATION/INDEX.md" && ! -L "$ARCHIVE_DESTINATION/INDEX.md" ]] ||
        die "archive is missing INDEX.md"
    cmp -s "$ARCHIVE_INVENTORY_FILE" "$ARCHIVE_DESTINATION/migration-inventory.tsv" ||
        die "archive migration-inventory.tsv differs from inventory"
    cmp -s "$ARCHIVE_INVENTORY_SIDECAR" "$ARCHIVE_DESTINATION/rules.sha256" ||
        die "archive rules.sha256 differs from inventory rules sidecar"

    : > "$expected_paths"
    : > "$actual_paths"
    while IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ expected_path; do
        [[ -n "$expected_path" ]] || continue
        path_has_symlink_component "$ARCHIVE_DESTINATION" "$expected_path" ||
            die "archive path traverses a symlink: $expected_path"
        printf '%s\0' "$expected_path" >> "$expected_paths"
    done < "$ARCHIVE_RECORDS_FILE"
    LC_ALL=C sort -z -o "$expected_paths" "$expected_paths"

    while IFS= read -r -d '' entry; do
        relative="${entry#"$ARCHIVE_DESTINATION/"}"
        if [[ -d "$entry" ]]; then
            allowed=0
            while IFS= read -r -d '' expected_path; do
                [[ "$expected_path" == "$relative/"* ]] && { allowed=1; break; }
            done < "$expected_paths"
            ((allowed == 1)) || die "archive tree contains extra directory: $relative"
        elif [[ -f "$entry" ]]; then
            case "$relative" in
                migration-inventory.tsv|manifest.json|INDEX.md|rules.sha256) ;;
                *) grep -Fzxq -- "$relative" "$expected_paths" || die "archive tree contains extra regular file: $relative" ;;
            esac
        else
            die "archive tree contains unsupported entry: $relative"
        fi
    done < <(find -P "$ARCHIVE_DESTINATION" -mindepth 1 -print0 | LC_ALL=C sort -z)

    find -P "$ARCHIVE_DESTINATION" -type f -print0 |
        while IFS= read -r -d '' entry; do
            relative="${entry#"$ARCHIVE_DESTINATION/"}"
            case "$relative" in
                migration-inventory.tsv|manifest.json|INDEX.md|rules.sha256) ;;
                *) printf '%s\0' "$relative" >> "$actual_paths" ;;
            esac
        done
    LC_ALL=C sort -z -o "$actual_paths" "$actual_paths"
    if ! cmp -s "$expected_paths" "$actual_paths"; then
        while IFS= read -r -d '' expected_path; do
            grep -Fzxq -- "$expected_path" "$actual_paths" ||
                die "archive target is missing: $expected_path"
        done < "$expected_paths"
        while IFS= read -r -d '' relative; do
            grep -Fzxq -- "$relative" "$expected_paths" ||
                die "archive tree contains unexpected file: $relative"
        done < "$actual_paths"
        die "archive tree files do not exactly match inventory"
    fi
}

verify_archive_manifest_and_index() {
    local manifest_file="$ARCHIVE_DESTINATION/manifest.json"
    local expected_manifest="$ARCHIVE_TMP_DIR/expected-manifest.json"
    local actual_core="$ARCHIVE_TMP_DIR/actual-manifest-core.json"
    local expected_core="$ARCHIVE_TMP_DIR/expected-manifest-core.json"
    local generated_at source root branch commit tracked original_path phase type date date_source size sha256 archived_path
    local duplicate_count expected_duplicate_group
    local missing_duplicate_path

    missing_duplicate_path="$(jq -r '.entries[] | select(has("duplicate_group") | not) | .archived_path' "$manifest_file" | head -n 1 || true)"
    [[ -z "$missing_duplicate_path" ]] || die "manifest entry missing duplicate_group: $missing_duplicate_path"
    jq -e '
        type == "object" and (keys | sort == ["entries", "generated_at", "rules", "schema_version", "sources"]) and
        .schema_version == 1 and (.generated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        (.rules | type == "object" and (keys | sort == ["path", "sha256", "sidecar"]) and
            (.path | type == "string") and (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")) and (.sidecar == "rules.sha256")) and
        (.sources | type == "array" and all(.[]; (keys | sort == ["branch", "commit", "name", "root"]))) and
        (.entries | type == "array" and all(.[]; (keys | sort == ["archived_path", "branch", "commit", "date", "date_source", "duplicate_group", "original_path", "phase", "sha256", "size", "source", "source_root", "tracked", "type"])))
    ' "$manifest_file" > /dev/null || die "manifest schema or field set is invalid"
    generated_at="$(jq -er '.generated_at' "$manifest_file")"
    date -u -d "$generated_at" '+%Y-%m-%dT%H:%M:%SZ' > /dev/null || die "manifest generated_at is invalid"
    build_archive_manifest "$expected_manifest" '1970-01-01T00:00:00Z'
    while IFS=$'\t' read -r source root branch commit tracked original_path phase type date date_source size sha256 archived_path; do
        [[ -n "$source" ]] || continue
        duplicate_count="$(awk -F '\t' -v expected_sha256="$sha256" \
            'NR > 0 && $12 == expected_sha256 { count++ } END { print count + 0 }' "$ARCHIVE_RECORDS_FILE")"
        if ((duplicate_count >= 2)); then
            expected_duplicate_group="$sha256"
        else
            expected_duplicate_group=""
        fi
        if ! jq -e \
            --arg source "$source" --arg source_root "$root" --arg branch "$branch" --arg commit "$commit" \
            --argjson tracked "$tracked" --arg original_path "$original_path" --arg phase "$phase" --arg type "$type" \
            --arg date "$date" --arg date_source "$date_source" --argjson size "$size" --arg sha256 "$sha256" \
            --arg archived_path "$archived_path" --arg expected_duplicate_group "$expected_duplicate_group" \
            '[.entries[] | select(.archived_path == $archived_path and .source == $source and
                .source_root == $source_root and .branch == $branch and .commit == $commit and
                .tracked == $tracked and .original_path == $original_path and .phase == $phase and
                .type == $type and .date == $date and .date_source == $date_source and
                .size == $size and .sha256 == $sha256 and has("duplicate_group") and
                ((.duplicate_group == null and $expected_duplicate_group == "") or
                 .duplicate_group == $expected_duplicate_group))] | length == 1' \
            "$manifest_file" > /dev/null; then
            die "manifest entry mismatch: $archived_path"
        fi
    done < "$ARCHIVE_RECORDS_FILE"
    jq -cS '{rules, sources, entries}' "$manifest_file" > "$actual_core"
    jq -cS '{rules, sources, entries}' "$expected_manifest" > "$expected_core"
    cmp -s "$actual_core" "$expected_core" || die "manifest fields do not exactly match inventory"

    build_archive_index "$manifest_file" "$ARCHIVE_RULES_PATH" "$ARCHIVE_TMP_DIR/expected-INDEX.md"
    cmp -s "$ARCHIVE_DESTINATION/INDEX.md" "$ARCHIVE_TMP_DIR/expected-INDEX.md" || die "INDEX.md is not deterministic or does not match manifest"
}

verify_archive_contents() {
    local source_name source_root original_path target_path size sha256 actual_size actual_sha

    verify_archive_tree
    verify_archive_manifest_and_index
    while IFS=$'\t' read -r source_name source_root _ _ _ original_path _ _ _ _ size sha256 target_path; do
        [[ -n "$source_name" ]] || continue
        target_path="$ARCHIVE_DESTINATION/$target_path"
        [[ -f "$target_path" && ! -L "$target_path" ]] || die "archive target is missing: $target_path"
        actual_size="$(stat -c '%s' -- "$target_path")"
        [[ "$actual_size" == "$size" ]] || die "archive size differs: $target_path"
        actual_sha="$(sha256sum -b -- "$target_path")"
        actual_sha="${actual_sha%% *}"
        [[ "$actual_sha" == "$sha256" ]] || die "archive SHA-256 differs: $target_path"
    done < "$ARCHIVE_RECORDS_FILE"
}

publish_archive_stage() {
    local parent backup
    parent="$(dirname -- "$ARCHIVE_DESTINATION")"
    if [[ ! -e "$ARCHIVE_DESTINATION" ]]; then
        mv -- "$ARCHIVE_STAGE_TMP" "$ARCHIVE_DESTINATION"
        ARCHIVE_STAGE_TMP=""
        return 0
    fi
    backup="$(mktemp -d "$parent/.$(basename -- "$ARCHIVE_DESTINATION").old.XXXXXX")"
    rmdir -- "$backup"
    mv -- "$ARCHIVE_DESTINATION" "$backup"
    if mv -- "$ARCHIVE_STAGE_TMP" "$ARCHIVE_DESTINATION"; then
        ARCHIVE_STAGE_TMP=""
        rm -rf -- "$backup"
    else
        mv -- "$backup" "$ARCHIVE_DESTINATION"
        die "failed to publish archive destination"
    fi
}

stage_archive() {
    local requested_inventory="$1"
    local requested_destination="$2"
    local source_name source_root original_path archived_path source_path target_path
    local stage_parent stage_manifest stage_index current_size current_sha

    load_archive_inventory "$requested_inventory"
    validate_archive_destination "$requested_destination"
    stage_destination_precheck
    check_archive_source_states

    stage_parent="$(dirname -- "$ARCHIVE_DESTINATION")"
    ARCHIVE_STAGE_TMP="$(mktemp -d "$stage_parent/.$(basename -- "$ARCHIVE_DESTINATION").stage.XXXXXX")"
    while IFS=$'\t' read -r source_name source_root _ _ _ original_path _ _ _ _ _ _ archived_path; do
        [[ -n "$source_name" ]] || continue
        source_path="$(validate_archive_source_file "$source_name" "$source_root" "$original_path")"
        target_path="$ARCHIVE_STAGE_TMP/$archived_path"
        [[ ! -e "$target_path" && ! -L "$target_path" ]] || die "archive path collision: $archived_path"
        mkdir -p -- "$(dirname -- "$target_path")"
        cp -- "$source_path" "$target_path"
        [[ -f "$target_path" && ! -L "$target_path" ]] || die "staged target is not a regular file: $archived_path"
        current_size="$(stat -c '%s' -- "$target_path")"
        current_sha="$(sha256sum -b -- "$target_path")"
        current_sha="${current_sha%% *}"
        IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ expected_size expected_sha _ <<< \
            "$(awk -F '\t' -v source="$source_name" -v path="$original_path" \
                '$1 == source && $6 == path { print; exit }' "$ARCHIVE_RECORDS_FILE")"
        [[ "$current_size" == "$expected_size" && "$current_sha" == "$expected_sha" ]] ||
            die "staged target verification failed: $archived_path"
    done < "$ARCHIVE_RECORDS_FILE"
    cp -- "$ARCHIVE_INVENTORY_FILE" "$ARCHIVE_STAGE_TMP/migration-inventory.tsv"
    cp -- "$ARCHIVE_INVENTORY_SIDECAR" "$ARCHIVE_STAGE_TMP/rules.sha256"
    stage_manifest="$ARCHIVE_STAGE_TMP/manifest.json"
    stage_index="$ARCHIVE_STAGE_TMP/INDEX.md"
    build_archive_manifest "$stage_manifest" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    build_archive_index "$stage_manifest" "$ARCHIVE_RULES_PATH" "$stage_index"
    ARCHIVE_DESTINATION="$ARCHIVE_STAGE_TMP"
    verify_archive_contents
    check_archive_candidate_stability
    ARCHIVE_DESTINATION="$(realpath -m -- "$requested_destination")"
    publish_archive_stage
    echo "stage: published verified archive at $ARCHIVE_DESTINATION" >&2
}

cleanup_known_history_directories() {
    local source_root="$1"
    local original_path="$2"
    local cleanup_root current

    cleanup_root=""
    case "$original_path" in
        docs/superpowers/specs/*) cleanup_root="$source_root/docs/superpowers/specs" ;;
        docs/superpowers/plans/*) cleanup_root="$source_root/docs/superpowers/plans" ;;
        docs/docs/build/axvisor/*) cleanup_root="$source_root/docs/docs/build/axvisor" ;;
        docs/reports/*) cleanup_root="$source_root/docs/reports" ;;
        os/axvisor/guests/*/docs/results/*) cleanup_root="${source_root}/${original_path%%/docs/results/*}/docs/results" ;;
    esac
    [[ -n "$cleanup_root" && -d "$cleanup_root" && ! -L "$cleanup_root" ]] || return 0
    current="$(dirname -- "$source_root/$original_path")"
    while [[ "$current" != "$cleanup_root" && "$current" == "$cleanup_root/"* ]]; do
        [[ -d "$current" && ! -L "$current" ]] || break
        rmdir -- "$current" 2>/dev/null || break
        current="$(dirname -- "$current")"
    done
}

delete_archive_sources() {
    local source_name source_root branch commit tracked original_path phase type date date_source size sha256 archived_path
    local source_path target_path actual_size actual_sha
    local -A deleted_paths=()

    verify_archive_contents
    check_archive_source_states
    while IFS=$'\t' read -r source_name source_root branch commit tracked original_path phase type date date_source size sha256 archived_path; do
        [[ -n "$source_name" ]] || continue
        source_path="$(validate_archive_source_file "$source_name" "$source_root" "$original_path")"
        target_path="$ARCHIVE_DESTINATION/$archived_path"
        [[ -f "$target_path" && ! -L "$target_path" ]] || die "archive target is not a regular file: $target_path"
        actual_size="$(stat -c '%s' -- "$source_path")"
        actual_sha="$(sha256sum -b -- "$source_path")"
        actual_sha="${actual_sha%% *}"
        [[ "$actual_size" == "$size" && "$actual_sha" == "$sha256" ]] ||
            die "source and archive differ before delete: $source_path"
        [[ -z "${deleted_paths[$source_path]+set}" ]] || die "source path is duplicated before delete: $source_path"
        deleted_paths["$source_path"]=1
    done < "$ARCHIVE_RECORDS_FILE"

    while IFS=$'\t' read -r source_name source_root _ _ _ original_path _ _ _ _ _ _; do
        [[ -n "$source_name" ]] || continue
        source_path="$(validate_archive_source_file "$source_name" "$source_root" "$original_path")"
        [[ -f "$source_path" && ! -L "$source_path" ]] || die "source path changed before delete: $source_path"
        rm -- "$source_path"
    done < "$ARCHIVE_RECORDS_FILE"
    verify_archive_contents
    echo "delete: removed only verified inventory files from source worktrees" >&2
}

archive_command_context() {
    local requested_inventory="$1"
    local requested_destination="$2"
    load_archive_inventory "$requested_inventory"
    validate_archive_destination "$requested_destination"
}

verify_archive() {
    archive_command_context "$1" "$2"
    verify_archive_contents
    echo "verify: archive, manifest, INDEX, rules sidecar, and tree are valid" >&2
}

main() {
    (($# >= 1)) || usage
    case "$1" in
        inventory)
            shift
            inventory "$@"
            ;;
        stage)
            (($# == 5)) || usage
            [[ "$2" == --inventory && "$4" == --destination ]] || usage
            stage_archive "$3" "$5"
            ;;
        verify)
            (($# == 5)) || usage
            [[ "$2" == --inventory && "$4" == --destination ]] || usage
            verify_archive "$3" "$5"
            ;;
        delete)
            (($# == 5)) || usage
            [[ "$2" == --inventory && "$4" == --destination ]] || usage
            archive_command_context "$3" "$5"
            delete_archive_sources
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
