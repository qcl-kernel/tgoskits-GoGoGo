#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
GENERATOR="$ROOT/os/axvisor/scripts/generate_starryos_vmconfig.sh"
TEMPLATE="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[[ -x "$GENERATOR" ]] || fail "StarryOS VM config generator is missing"

mkdir -p "$ROOT/tmp"
test_root="$(mktemp -d "$ROOT/tmp/test-starryos-vmconfig.XXXXXX")"
runtime="$(mktemp -d "$ROOT/tmp/starryos-runtime.XXXXXX")"
trap 'rm -rf -- "$test_root" "$runtime"' EXIT

kernel="$test_root/starryos-task123.bin"
printf 'starryos image\n' > "$kernel"
template_hash="$(sha256sum "$TEMPLATE")"
cmdline='task2.count=30000 task2.fault=none task3.frames=3 task3.fault=normal'

output="$($GENERATOR "$ROOT" "$TEMPLATE" "$kernel" "$runtime" "$cmdline")"
[[ "$output" == "$runtime/starryos-task123.toml" ]] ||
    fail "generator returned an unexpected output path"
[[ -L "$runtime/starryos-task123.bin" ]] || fail "runtime image is not a symlink"
[[ "$(realpath -e "$runtime/starryos-task123.bin")" == "$(realpath -e "$kernel")" ]] ||
    fail "runtime image does not reference the selected StarryOS image"

python3 - "$TEMPLATE" "$output" "$cmdline" <<'PY'
import copy
import sys
import tomllib
from pathlib import Path

template = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
generated = tomllib.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = copy.deepcopy(template)
expected["kernel"]["kernel_path"] = "starryos-task123.bin"
expected["kernel"]["cmdline"] = sys.argv[3]
if generated != expected:
    raise SystemExit("generated StarryOS VM config changed unrelated semantics")
PY

[[ "$(sha256sum "$TEMPLATE")" == "$template_hash" ]] ||
    fail "generator modified the template"

bad_runtime="$test_root/not-runtime"
mkdir "$bad_runtime"
if "$GENERATOR" "$ROOT" "$TEMPLATE" "$kernel" "$bad_runtime" "$cmdline" \
    >/dev/null 2>&1; then
    fail "generator accepted a runtime directory outside ROOT/tmp/starryos-runtime.*"
fi
if "$GENERATOR" "$ROOT" "$TEMPLATE" "$kernel" "$runtime" $'bad\ncmdline' \
    >/dev/null 2>&1; then
    fail "generator accepted a non-printable cmdline"
fi
if "$GENERATOR" "$ROOT" "$TEMPLATE" "$kernel" "$runtime" 'bad"cmdline' \
    >/dev/null 2>&1; then
    fail "generator accepted an unsafe TOML cmdline"
fi

echo "PASS: StarryOS runtime VM config generator"
