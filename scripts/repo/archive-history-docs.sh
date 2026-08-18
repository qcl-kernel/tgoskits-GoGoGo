#!/usr/bin/env bash

set -euo pipefail

ARCHIVE_TMP_DIR=""
ARCHIVE_OUTPUT_TMP=""

cleanup() {
    [[ -z "$ARCHIVE_TMP_DIR" ]] || rm -rf -- "$ARCHIVE_TMP_DIR"
    [[ -z "$ARCHIVE_OUTPUT_TMP" ]] || rm -f -- "$ARCHIVE_OUTPUT_TMP"
}

trap cleanup EXIT

usage() {
    cat >&2 <<'EOF'
usage: archive-history-docs.sh inventory --rules FILE --source NAME=PATH... --output FILE
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

valid_date() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$(date -u -d "$candidate" +%F 2>/dev/null || true)" == "$candidate" ]]
}

load_rules() {
    local rules_file="$1"
    local line action regex phase type reason rest

    [[ -f "$rules_file" ]] || die "rules file does not exist: $rules_file"
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
        [[ "$action" == include || "$action" == exclude ]] ||
            die "invalid rule action: $action"
        [[ -n "$regex" && -n "$reason" ]] || die "rule has an empty pattern or reason"
        if [[ "$action" == include ]]; then
            [[ -n "$phase" && -n "$type" ]] || die "include rule has an empty phase or type"
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
    local i

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
        fi
    done
    return 1
}

file_date() {
    local base="$1"
    local full_path="$2"
    local tracked="$3"
    local repo="$4"
    local relative_path="$5"
    local candidate git_date

    if [[ "$base" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        candidate="${BASH_REMATCH[1]}"
        if valid_date "$candidate"; then
            printf '%s\tfilename\n' "$candidate"
            return 0
        fi
    fi

    if [[ "$tracked" == true ]]; then
        git_date="$(git -C "$repo" log -1 --format=%cs -- "$relative_path")"
        if valid_date "$git_date"; then
            printf '%s\tgit_commit\n' "$git_date"
            return 0
        fi
    fi

    candidate="$(date -r "$full_path" +%F)"
    valid_date "$candidate" || die "invalid filesystem date for $full_path"
    printf '%s\tfilesystem_mtime\n' "$candidate"
}

inventory() {
    local rules_file=""
    local output_file=""
    local spec name requested_path source_root repo_root branch commit
    local tracked_file untracked_file candidates_file rel full_path target_path
    local tracked flag base extension phase type date date_source size digest archived
    local selected excluded unmatched skipped i
    local output_tmp
    local -a source_specs=()
    local -A seen_sources=()
    local -A seen_archived=()
    local tmp_dir

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
    rules_file="$(canonical_existing_path "$rules_file")"
    load_rules "$rules_file"

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/archive-history-docs.XXXXXX")"
    ARCHIVE_TMP_DIR="$tmp_dir"
    output_tmp="$tmp_dir/inventory.tsv"
    printf '%s\n' \
        $'source\tsource_root\tbranch\tcommit\ttracked\toriginal_path\tphase\ttype\tdate\tdate_source\tsize\tsha256\tarchived_path' \
        > "$output_tmp"
    : > "$tmp_dir/records.tsv"

    for spec in "${source_specs[@]}"; do
        [[ "$spec" == *=* ]] || die "source must be NAME=PATH: $spec"
        name="${spec%%=*}"
        requested_path="${spec#*=}"
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid source name: $name"
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

        tracked_file="$tmp_dir/$name.tracked"
        untracked_file="$tmp_dir/$name.untracked"
        candidates_file="$tmp_dir/$name.candidates"
        git -C "$repo_root" ls-files -z > "$tracked_file"
        git -C "$repo_root" ls-files --others --exclude-standard -z > "$untracked_file"
        sort -z -u "$tracked_file" "$untracked_file" > "$candidates_file"

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
                *$'\t'*|*$'\n'*)
                    ((skipped += 1))
                    continue
                    ;;
            esac

            full_path="$repo_root/$rel"
            target_path="$(realpath -e -- "$full_path" 2>/dev/null || true)"
            if [[ -z "$target_path" || "$target_path" != "$repo_root"/* || ! -f "$target_path" ]]; then
                ((skipped += 1))
                continue
            fi

            if ! classify_path "$name/$rel" && ! classify_path "$rel"; then
                ((unmatched += 1))
                continue
            fi
            if [[ "$CLASS_ACTION" == exclude ]]; then
                ((excluded += 1))
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
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$name" "$source_root" "$branch" "$commit" "$tracked" "$rel" \
                "$phase" "$type" "$date" "$date_source" "$size" "$digest" "$archived" \
                >> "$tmp_dir/records.tsv"
            ((selected += 1))
        done < "$candidates_file"

        echo "inventory: source=$name selected=$selected excluded=$excluded unmatched=$unmatched skipped=$skipped" >&2
    done

    LC_ALL=C sort -t $'\t' -k13,13 "$tmp_dir/records.tsv" >> "$output_tmp"
    output_file="$(realpath -m -- "$output_file")"
    output_tmp_target="$(mktemp "$(dirname -- "$output_file")/.$(basename -- "$output_file").tmp.XXXXXX")"
    ARCHIVE_OUTPUT_TMP="$output_tmp_target"
    cp -- "$output_tmp" "$output_tmp_target"
    mv -f -- "$output_tmp_target" "$output_file"
    ARCHIVE_OUTPUT_TMP=""
}

main() {
    (($# >= 1)) || usage
    case "$1" in
        inventory)
            shift
            inventory "$@"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
