#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 ROOT TEMPLATE STARRYOS_KERNEL RUNTIME_DIR GUEST_CMDLINE" >&2
    exit 2
fi

if ! root="$(realpath -e -- "$1")" ||
   ! template="$(realpath -e -- "$2")" ||
   ! kernel="$(realpath -e -- "$3")" ||
   ! runtime_dir="$(realpath -e -- "$4")"; then
    echo "ROOT, TEMPLATE, STARRYOS_KERNEL, and RUNTIME_DIR must exist" >&2
    exit 2
fi

case "$runtime_dir" in
    "$root"/tmp/starryos-runtime.*) ;;
    *)
        echo "runtime directory must be ROOT/tmp/starryos-runtime.*: $runtime_dir" >&2
        exit 2
        ;;
esac

runtime_rel="${runtime_dir#"$root"/}"
if [[ ! "$runtime_rel" =~ ^tmp/starryos-runtime\.[A-Za-z0-9]+$ ]]; then
    echo "unsafe runtime directory name: $runtime_rel" >&2
    exit 2
fi

guest_cmdline="$5"
if [[ -z "$guest_cmdline" ]] ||
   printf '%s' "$guest_cmdline" | LC_ALL=C grep -q '[^[:print:]]' ||
   [[ "$guest_cmdline" == *'"'* ]] ||
   [[ "$guest_cmdline" == *'\'* ]]; then
    echo "GUEST_CMDLINE must be a non-empty, printable TOML basic string without quotes or backslashes" >&2
    exit 2
fi

runtime_kernel="$runtime_dir/starryos-task123.bin"
output="$runtime_dir/starryos-task123.toml"
output_tmp="$runtime_dir/.starryos-task123.toml.tmp"
trap 'rm -f -- "$output_tmp"' EXIT

ln -s -- "$kernel" "$runtime_kernel"
if ! python3 - "$template" "$output_tmp" "$guest_cmdline" <<'PY'
import copy
import re
import sys
import tomllib
from pathlib import Path


template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
guest_cmdline = sys.argv[3]
text = template_path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)


def assignment(key: str, value: str, line: str) -> str:
    newline = "\n" if line.endswith("\n") else ""
    prefix = line[: len(line) - len(line.lstrip())]
    return f'{prefix}{key} = "{value}"{newline}'


try:
    original = tomllib.loads(text)
    expected = copy.deepcopy(original)
    kernel = expected["kernel"]
    if not isinstance(kernel, dict):
        raise ValueError("[kernel] must be a table")
    kernel["kernel_path"] = "starryos-task123.bin"
    kernel["cmdline"] = guest_cmdline

    generated = []
    kernel_paths = 0
    cmdlines = 0
    for line in lines:
        if re.match(r"^\s*kernel_path\s*=", line):
            generated.append(assignment("kernel_path", "starryos-task123.bin", line))
            kernel_paths += 1
        elif re.match(r"^\s*cmdline\s*=", line):
            generated.append(assignment("cmdline", guest_cmdline, line))
            cmdlines += 1
        else:
            generated.append(line)

    if kernel_paths != 1 or cmdlines != 1:
        raise ValueError("template must provide exactly one [kernel].kernel_path and cmdline")

    candidate_text = "".join(generated)
    if tomllib.loads(candidate_text) != expected:
        raise ValueError("generated config changed unrelated TOML semantics")
    output_path.write_text(candidate_text, encoding="utf-8")
except (KeyError, TypeError, ValueError, tomllib.TOMLDecodeError) as error:
    print(f"invalid StarryOS VM template: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 2
fi
mv -- "$output_tmp" "$output"
trap - EXIT

printf '%s\n' "$output"
