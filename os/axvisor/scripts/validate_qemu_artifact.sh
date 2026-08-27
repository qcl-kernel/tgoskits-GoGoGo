#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <manifest.tsv> <axvisor-elf> <axvisor-raw.bin> <vm-config.toml>..." >&2
  exit 2
fi

MANIFEST_PATH="$1"
ELF_PATH="$2"
RAW_PATH="$3"
shift 3
VM_CONFIG_PATHS=("$@")
GENERATED_RAW=""
MANIFEST_TMP=""

die() {
  echo "[axvisor-qemu-artifact] ERROR: $*" >&2
  exit 1
}

cleanup() {
  [ -z "$GENERATED_RAW" ] || rm -f -- "$GENERATED_RAW"
  [ -z "$MANIFEST_TMP" ] || rm -f -- "$MANIFEST_TMP"
}
trap cleanup EXIT INT TERM

for tool in realpath sha256sum cmp mktemp mv rm dirname python3 rust-objcopy; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: ${tool}"
done

sha256() {
  local output
  output="$(sha256sum -- "$1")"
  printf '%s' "${output%% *}"
}

[ -f "$ELF_PATH" ] || die "required ELF does not exist: ${ELF_PATH}"
[ -f "$RAW_PATH" ] || die "required raw binary does not exist: ${RAW_PATH}"
for config in "${VM_CONFIG_PATHS[@]}"; do
  [ -f "$config" ] || die "required VM config does not exist: ${config}"
  [ -s "$config" ] || die "VM config is empty: ${config}"
done

ELF_PATH="$(realpath -- "$ELF_PATH")"
RAW_PATH="$(realpath -- "$RAW_PATH")"
for index in "${!VM_CONFIG_PATHS[@]}"; do
  VM_CONFIG_PATHS[$index]="$(realpath -- "${VM_CONFIG_PATHS[$index]}")"
done

reject_tsv_unsafe_path() {
  local role="$1"
  local path="$2"
  local quoted_path
  case "$path" in
    *$'\t'*|*$'\n'*)
      printf -v quoted_path '%q' "$path"
      die "canonical path contains TAB or newline: ${role}: ${quoted_path}"
      ;;
  esac
}

reject_tsv_unsafe_path "elf" "$ELF_PATH"
reject_tsv_unsafe_path "raw" "$RAW_PATH"
for config in "${VM_CONFIG_PATHS[@]}"; do
  reject_tsv_unsafe_path "vm-config" "$config"
done

ELF_SHA256="$(sha256 "$ELF_PATH")"
RAW_SHA256="$(sha256 "$RAW_PATH")"
VM_CONFIG_SHA256S=()
for config in "${VM_CONFIG_PATHS[@]}"; do
  VM_CONFIG_SHA256S+=("$(sha256 "$config")")
done

MANIFEST_DIR="$(dirname -- "$MANIFEST_PATH")"
[ -d "$MANIFEST_DIR" ] || die "manifest directory does not exist: ${MANIFEST_DIR}"
MANIFEST_BASENAME="${MANIFEST_PATH##*/}"
GENERATED_RAW="$(mktemp "${TMPDIR:-/tmp}/axvisor-qemu-raw.XXXXXX")"
MANIFEST_TMP="$(mktemp "${MANIFEST_DIR}/.${MANIFEST_BASENAME}.tmp.XXXXXX")"

rust-objcopy -O binary "$ELF_PATH" "$GENERATED_RAW" \
  || die "failed to regenerate raw binary from ELF: ${ELF_PATH}"
cmp -s -- "$GENERATED_RAW" "$RAW_PATH" \
  || die "regenerated raw binary does not match supplied raw binary: ${RAW_PATH}"

python3 - "$ELF_PATH" "$RAW_PATH" "${VM_CONFIG_PATHS[@]}" <<'PY' \
  || die "required VM config bytes are absent from Axvisor artifacts"
import pathlib
import sys

elf_path, raw_path, *config_paths = map(pathlib.Path, sys.argv[1:])
elf_bytes = elf_path.read_bytes()
raw_bytes = raw_path.read_bytes()
for config_path in config_paths:
    config_bytes = config_path.read_bytes()
    missing_from = []
    if config_bytes not in elf_bytes:
        missing_from.append("ELF")
    if config_bytes not in raw_bytes:
        missing_from.append("raw binary")
    if missing_from:
        print(
            f"VM config bytes are not embedded in {' and '.join(missing_from)}: {config_path}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY

verify_input_unchanged() {
  local role="$1"
  local path="$2"
  local expected_sha256="$3"
  local current_sha256
  [ -f "$path" ] || die "input changed during validation: ${role}: ${path}"
  current_sha256="$(sha256 "$path")"
  [ "$current_sha256" = "$expected_sha256" ] \
    || die "input changed during validation: ${role}: ${path}"
}

verify_input_unchanged "elf" "$ELF_PATH" "$ELF_SHA256"
verify_input_unchanged "raw" "$RAW_PATH" "$RAW_SHA256"
for index in "${!VM_CONFIG_PATHS[@]}"; do
  verify_input_unchanged \
    "vm-config" "${VM_CONFIG_PATHS[$index]}" "${VM_CONFIG_SHA256S[$index]}"
done

{
  printf 'version\t1\n'
  printf 'elf\t%s\t%s\n' "$ELF_PATH" "$ELF_SHA256"
  printf 'raw\t%s\t%s\n' "$RAW_PATH" "$RAW_SHA256"
  for index in "${!VM_CONFIG_PATHS[@]}"; do
    printf 'vm-config\t%s\t%s\n' \
      "${VM_CONFIG_PATHS[$index]}" "${VM_CONFIG_SHA256S[$index]}"
  done
} >"$MANIFEST_TMP"

mv -f -- "$MANIFEST_TMP" "$MANIFEST_PATH"
MANIFEST_TMP=""
echo "[axvisor-qemu-artifact] manifest=${MANIFEST_PATH}"
