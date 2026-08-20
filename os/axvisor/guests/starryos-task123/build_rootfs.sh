#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
DEFAULT_SOURCE="$REPO_ROOT/os/axvisor/guests/task3/build/images/linux/rootfs.cpio"
DEFAULT_OUTPUT="$SCRIPT_DIR/build/starryos-task123-rootfs.cpio"

source_cpio=${TASK123_LINUX_ROOTFS:-$DEFAULT_SOURCE}
output=$DEFAULT_OUTPUT

usage() {
    cat <<EOF
Usage: $0 [--source-cpio PATH] [--output PATH]

Repackages an existing Task123 Linux rootfs as a deterministic StarryOS CPIO.
The source archive must already contain the AArch64 Task 2/3 applications.
EOF
}

while (($#)); do
    case "$1" in
        --source-cpio)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            source_cpio=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            output=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for command in cpio find sort touch install readelf sha256sum realpath gzip; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command" >&2
        exit 1
    }
done

[[ -s "$source_cpio" ]] || {
    printf 'Task123 source CPIO not found: %s\n' "$source_cpio" >&2
    printf 'build it first or pass --source-cpio PATH\n' >&2
    exit 1
}
source_cpio=$(realpath -e -- "$source_cpio")
output=$(realpath -m -- "$output")

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir"
stage=$(mktemp -d "$output_dir/.starryos-rootfs.XXXXXX")
archive_tmp="$output.tmp.$$"
patterns="$stage/../.starryos-patterns.$$"
trap 'rm -rf -- "$stage"; rm -f -- "$archive_tmp" "$patterns"' EXIT

source_archive="$source_cpio"
if [[ "$source_cpio" == *.gz ]] || gzip -t -- "$source_cpio" >/dev/null 2>&1; then
    gzip -t -- "$source_cpio" || {
        printf 'Task123 source CPIO gzip archive is invalid: %s\n' "$source_cpio" >&2
        exit 1
    }
    source_archive="$stage/source.cpio"
    gzip -dc -- "$source_cpio" > "$source_archive"
fi

cpio --list --quiet < "$source_archive" |
    sed -e '/^dev\(\/\|$\)/d' -e '/^proc\(\/\|$\)/d' -e '/^sys\(\/\|$\)/d' > "$patterns"
(
    cd "$stage"
    cpio --extract --make-directories --no-absolute-filenames --no-preserve-owner \
        --pattern-file="$patterns" --quiet < "$source_archive"
)
for mountpoint in dev proc sys tmp; do
    mkdir -p "$stage/$mountpoint"
done

install -m 0755 "$SCRIPT_DIR/rootfs/init" "$stage/init"

required_files=(
    bin/busybox
    bin/rtipic-client
    usr/bin/task3-linux
    opt/task3/line-follow.y4m
    opt/task3/truth.csv
    init
)
for path in "${required_files[@]}"; do
    [[ -s "$stage/$path" ]] || {
        printf 'source CPIO is missing required file: /%s\n' "$path" >&2
        exit 1
    }
done

for path in bin/busybox bin/rtipic-client usr/bin/task3-linux; do
    readelf -h "$stage/$path" | grep -Fq 'Machine:                           AArch64' || {
        printf 'required executable is not AArch64: /%s\n' "$path" >&2
        exit 1
    }
    interpreter=$(readelf -l "$stage/$path" |
        sed -n 's@.*Requesting program interpreter: \([^]]*\).*@\1@p')
    if [[ -n "$interpreter" && ! -e "$stage$interpreter" ]]; then
        printf 'missing ELF interpreter %s for /%s\n' "$interpreter" "$path" >&2
        exit 1
    fi
done

find "$stage" -exec touch -h -d '@0' {} +
(
    cd "$stage"
    find . -mindepth 1 -print0 |
        LC_ALL=C sort -z |
        cpio --null --create --format=newc --reproducible --owner=0:0 --quiet > "$archive_tmp"
)

mv -f -- "$archive_tmp" "$output"
sha256sum "$output" > "$output.sha256"
{
    printf 'source=%s\n' "$source_cpio"
    printf 'archive=%s\n' "$output"
    printf 'sha256=%s\n' "$(sha256sum "$output" | awk '{print $1}')"
    printf 'size_bytes=%s\n' "$(stat -c %s "$output")"
    printf 'members_begin\n'
    cpio -it < "$output" 2>/dev/null
    printf 'members_end\n'
} > "$output.manifest"

printf 'starryos_rootfs=%s\n' "$output"
printf 'starryos_rootfs_sha256=%s\n' "$(awk '{print $1}' "$output.sha256")"
