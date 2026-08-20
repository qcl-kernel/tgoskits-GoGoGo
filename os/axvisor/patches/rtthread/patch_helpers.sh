#!/usr/bin/env bash

apply_patch_exactly() {
    local repository="$1"
    local patch_file="$2"
    local label="$3"

    if [[ "${TGOSKITS_SKIP_PATCH_APPLICATION:-0}" == 1 ]]; then
        echo "$label is already applied (validated patch-set state)"
        return 0
    fi

    if git -C "$repository" apply --check "$patch_file" >/dev/null 2>&1; then
        if ! git -C "$repository" apply "$patch_file"; then
            echo "Failed to apply $label" >&2
            return 1
        fi
        echo "Applied $label"
    elif git -C "$repository" apply --check --reverse "$patch_file" \
        >/dev/null 2>&1; then
        echo "$label is already applied"
    else
        echo "$label is partially applied or source has drifted" >&2
        return 1
    fi
}
