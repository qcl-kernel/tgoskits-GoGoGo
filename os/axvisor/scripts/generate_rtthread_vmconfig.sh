#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "usage: $0 ROOT TEMPLATE RTTHREAD_KERNEL RUNTIME_DIR [GUEST_CMDLINE]" >&2
    exit 2
fi

root="$(realpath -e -- "$1")"
template="$(realpath -e -- "$2")"
kernel="$(realpath -e -- "$3")"
runtime_dir="$(realpath -e -- "$4")"

case "$runtime_dir" in
    "$root"/tmp/rtthread-runtime.*) ;;
    *)
        echo "runtime directory must be ROOT/tmp/rtthread-runtime.*: $runtime_dir" >&2
        exit 2
        ;;
esac

runtime_rel="${runtime_dir#"$root"/}"
if [[ ! "$runtime_rel" =~ ^tmp/rtthread-runtime\.[A-Za-z0-9]+$ ]]; then
    echo "unsafe runtime directory name: $runtime_rel" >&2
    exit 2
fi

kernel_path_count="$(grep -c '^kernel_path[[:space:]]*=' "$template" || true)"
if [[ "$kernel_path_count" -ne 1 ]]; then
    echo "template must contain exactly one kernel_path: $template" >&2
    exit 2
fi

replace_cmdline=false
guest_cmdline=""
if [[ $# -eq 5 ]]; then
    replace_cmdline=true
    guest_cmdline="$5"
    if [[ -z "$guest_cmdline" ]] ||
       printf '%s' "$guest_cmdline" | LC_ALL=C grep -q '[^[:print:]]' ||
       printf '%s' "$guest_cmdline" | grep -Fq '"' ||
       printf '%s' "$guest_cmdline" | grep -Fq '\'; then
        echo "GUEST_CMDLINE must be a non-empty, printable TOML basic string without quotes or backslashes" >&2
        exit 2
    fi
fi

runtime_kernel="$runtime_dir/rtthread.bin"
output="$runtime_dir/rtthread-net.toml"
output_tmp="$runtime_dir/.rtthread-net.toml.tmp"
trap 'rm -f -- "$output_tmp"' EXIT

ln -s -- "$kernel" "$runtime_kernel"
if ! python3 - "$template" "$output_tmp" "$replace_cmdline" "$guest_cmdline" <<'PY'
import copy
import re
import sys
import tomllib
from pathlib import Path


template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
replace_cmdline = sys.argv[3] == "true"
guest_cmdline = sys.argv[4]
text = template_path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)


def assignment(key: str, value: str, line: str) -> str:
    newline = "\n" if line.endswith("\n") else ""
    return f'{key} = "{value}"{newline}'


try:
    original = tomllib.loads(text)
    expected = copy.deepcopy(original)
    kernel = expected["kernel"]
    kernel["kernel_path"] = "rtthread.bin"
    if replace_cmdline:
        if not isinstance(kernel.get("cmdline"), str):
            raise ValueError("[kernel].cmdline must exist exactly once and be a string")
        kernel["cmdline"] = guest_cmdline

    generated = []
    for line in lines:
        if re.match(r"^kernel_path\s*=", line):
            generated.append(assignment("kernel_path", "rtthread.bin", line))
        else:
            generated.append(line)

    candidates = [None]
    if replace_cmdline:
        candidates = [
            index
            for index, line in enumerate(generated)
            if re.match(r"^\s*cmdline\s*=", line)
        ]

    matches = []
    for candidate in candidates:
        candidate_lines = generated.copy()
        if candidate is not None:
            candidate_lines[candidate] = assignment(
                "cmdline", guest_cmdline, candidate_lines[candidate]
            )
        candidate_text = "".join(candidate_lines)
        try:
            if tomllib.loads(candidate_text) == expected:
                matches.append(candidate_text)
        except tomllib.TOMLDecodeError:
            continue

    if len(matches) != 1:
        raise ValueError(
            "template must provide one unambiguous [kernel].cmdline assignment"
        )
    output_path.write_text(matches[0], encoding="utf-8")
except (KeyError, TypeError, ValueError, tomllib.TOMLDecodeError) as error:
    print(f"invalid RT-Thread VM template: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 2
fi
mv -- "$output_tmp" "$output"
trap - EXIT

printf '%s\n' "$output"
