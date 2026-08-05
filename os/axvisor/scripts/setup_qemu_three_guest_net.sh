#!/usr/bin/env bash
set -euo pipefail

# Prepare two Linux guests and one Zephyr guest for the QEMU three-NIC Axvisor
# experiment. The generated VM configs intentionally live under tmp/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXVISOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${AXVISOR_ROOT}/../.." && pwd)"
IMAGE_ROOT="${AXVISOR_THREE_GUEST_IMAGE_ROOT:-/tmp/.axvisor-images}"
GUEST_REGISTRY="${AXVISOR_THREE_GUEST_REGISTRY:-https://raw.githubusercontent.com/arceos-hypervisor/axvisor-guest/504cabb5e07e506e2692b010e01204d20587f030/registry/v0.0.26.toml}"
LINUX_IMAGE_NAME="qemu_aarch64_linux"
GENERATED_BASE="${REPO_ROOT}/tmp/vmconfigs/three-guest-net"
GENERATED_ROOT="${GENERATED_BASE}/current"
QEMU_CONFIG="${AXVISOR_ROOT}/configs/qemu/qemu-aarch64-three-guest-net.toml"
ROOTFS_TARGET="${REPO_ROOT}/tmp/rootfs.img"
RTOS_ENTRY_POINT="${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-}"
RTOS_PCPU="${AXVISOR_THREE_GUEST_RTOS_PCPU:-2}"
HOST_TIMER_POLICY="${AXVISOR_THREE_GUEST_HOST_TIMER_POLICY:-periodic}"
HOST_VCPU_YIELD="${AXVISOR_THREE_GUEST_HOST_VCPU_YIELD:-false}"
HOST_VCPU_IDLE_POLICY="${AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY:-halt}"
PREPARED_RTOS_KERNEL=""

die() {
  echo "[three-guest-net] ERROR: $*" >&2
  exit 1
}

case "$HOST_TIMER_POLICY" in
  periodic|tickless) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_TIMER_POLICY must be periodic or tickless" ;;
esac

case "$HOST_VCPU_YIELD" in
  true|false) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_VCPU_YIELD must be true or false" ;;
esac

case "$HOST_VCPU_IDLE_POLICY" in
  halt|busy) ;;
  *) die "AXVISOR_THREE_GUEST_HOST_VCPU_IDLE_POLICY must be halt or busy" ;;
esac

preflight_common() {
  local command_name description
  while IFS=$'\t' read -r command_name description; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "${command_name} is required ${description}"
  done <<'EOF'
python3	to patch and validate three-guest TOML configs
rg	to validate the three-guest network inputs
cpio	to build deterministic Linux guest initramfs archives
file	to validate the selected static BusyBox
mktemp	to isolate and atomically publish generated artifacts
sort	to order deterministic Linux guest initramfs members
touch	to normalize deterministic Linux guest initramfs metadata
find	to enumerate Linux guest initramfs members and image artifacts
readlink	to compare rootfs source and destination paths before publication
cp	to stage selected guest artifacts
chmod	to set guest initramfs executable modes
mv	to atomically publish generated artifacts
rm	to clean private temporary staging
mkdir	to create private artifact directories
ln	to create the BusyBox shell link
EOF
  python3 -c 'import tomllib' >/dev/null 2>&1 \
    || die "python3 tomllib is required to patch and validate three-guest TOML configs"
}

preflight_rtos_build() {
  command -v cmake >/dev/null 2>&1 \
    || die "cmake is required to configure the checked-in Zephyr network guest"
  command -v ninja >/dev/null 2>&1 \
    || die "ninja is required to build the checked-in Zephyr network guest"
  command -v readelf >/dev/null 2>&1 \
    || die "readelf is required to determine the Zephyr guest entry point"
  command -v awk >/dev/null 2>&1 \
    || die "awk is required to parse the Zephyr guest entry point"
}

find_kernel() {
  local image_dir="$1"
  local candidate
  for candidate in \
    "${image_dir}/qemu-aarch64" \
    "${image_dir}/qemu-aarch64.bin" \
    "${image_dir}/linux-qemu" \
    "${image_dir}/zephyr-qemu" \
    "${image_dir}/zephyr-qemu.bin"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  find "$image_dir" -maxdepth 2 -type f \( -name 'qemu-aarch64*' -o -name 'linux-qemu*' -o -name 'zephyr-qemu*' \) -print -quit
}

pull_guest_image() {
  local image_name="$1"
  local image_dir="${IMAGE_ROOT}/${image_name}"

  command -v cargo >/dev/null 2>&1 || die "cargo is required to pull ${image_name}"
  mkdir -p "$IMAGE_ROOT"
  echo "[three-guest-net] pulling ${image_name} from ${GUEST_REGISTRY}" >&2
  if ! (cd "$REPO_ROOT" && \
    TGOS_IMAGE_LOCAL_STORAGE="${IMAGE_ROOT}/managed" \
    TGOS_IMAGE_REGISTRY_FALLBACK_URL="$GUEST_REGISTRY" \
    cargo xtask image pull \
      --registry "$GUEST_REGISTRY" \
      --output-dir "$IMAGE_ROOT" \
      "$image_name" >&2); then
    die "unable to pull ${image_name}; provide a local kernel with AXVISOR_THREE_GUEST_LINUX_IMAGE or AXVISOR_THREE_GUEST_RTOS_IMAGE"
  fi
  [ -d "$image_dir" ] || die "image pull did not create ${image_dir}"
  printf '%s\n' "$image_dir"
}

prepare_linux_kernel() {
  if [ -n "${AXVISOR_THREE_GUEST_LINUX_IMAGE:-}" ]; then
    [ -f "$AXVISOR_THREE_GUEST_LINUX_IMAGE" ] || die "Linux image does not exist: ${AXVISOR_THREE_GUEST_LINUX_IMAGE}"
    printf '%s\n' "$AXVISOR_THREE_GUEST_LINUX_IMAGE"
    return 0
  fi

  local image_dir
  image_dir="$(pull_guest_image "$LINUX_IMAGE_NAME")"
  local kernel
  kernel="$(find_kernel "$image_dir")"
  [ -n "$kernel" ] && [ -f "$kernel" ] || die "no QEMU AArch64 Linux kernel found under ${image_dir}"
  printf '%s\n' "$kernel"
}

prepare_rtos_kernel() {
  if [ -n "${AXVISOR_THREE_GUEST_RTOS_IMAGE:-}" ]; then
    [ -n "$RTOS_ENTRY_POINT" ] || die "AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT is required with a prebuilt RTOS .bin image"
    if [ -f "$AXVISOR_THREE_GUEST_RTOS_IMAGE" ]; then
      PREPARED_RTOS_KERNEL="$AXVISOR_THREE_GUEST_RTOS_IMAGE"
      return 0
    fi
    if [ -d "$AXVISOR_THREE_GUEST_RTOS_IMAGE" ]; then
      local explicit_kernel
      explicit_kernel="$(find_kernel "$AXVISOR_THREE_GUEST_RTOS_IMAGE")"
      [ -n "$explicit_kernel" ] && [ -f "$explicit_kernel" ] || die "no Zephyr QEMU kernel found under ${AXVISOR_THREE_GUEST_RTOS_IMAGE}"
      PREPARED_RTOS_KERNEL="$explicit_kernel"
      return 0
    fi
    die "RTOS image does not exist: ${AXVISOR_THREE_GUEST_RTOS_IMAGE}"
  fi

  local zephyr_base="${ZEPHYR_BASE:-}"
  local cross_compile="${CROSS_COMPILE:-}"
  local zephyr_build="${IMAGE_ROOT}/zephyr-net-build"
  local zephyr_app="${AXVISOR_ROOT}/guests/zephyr-net"
  local zephyr_overlay="${zephyr_app}/virtnet.overlay"
  local extra_cflags="${AXVISOR_THREE_GUEST_ZEPHYR_EXTRA_CFLAGS:--Did_aa64isar2_el1=S3_0_C0_C6_2}"

  [ -d "$zephyr_base" ] || die "ZEPHYR_BASE is required to build the checked-in network guest; set ZEPHYR_BASE or provide AXVISOR_THREE_GUEST_RTOS_IMAGE"
  [ -f "${zephyr_app}/CMakeLists.txt" ] || die "missing checked-in Zephyr guest at ${zephyr_app}"
  preflight_rtos_build

  local -a cmake_args=(
    -S "$zephyr_app"
    -B "$zephyr_build"
    -GNinja
    -DBOARD=qemu_cortex_a53
    -DDTC_OVERLAY_FILE="$zephyr_overlay"
    -DEXTRA_CFLAGS="$extra_cflags"
  )
  if [ -n "$cross_compile" ]; then
    cmake_args+=("-DCROSS_COMPILE=${cross_compile}")
    if [ -x "${cross_compile}gcc" ]; then
      cmake_args+=("-DCMAKE_C_COMPILER=${cross_compile}gcc")
    fi
  fi
  if [ "${AXVISOR_THREE_GUEST_RT_IRQ_TRACE:-0}" = "1" ]; then
    cmake_args+=("-DAXVISOR_RT_IRQ_TRACE=ON")
  fi

  echo "[three-guest-net] building the checked-in Zephyr virtio-net guest" >&2
  ZEPHYR_BASE="$zephyr_base" \
    ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-cross-compile}" \
    cmake "${cmake_args[@]}" >&2
  cmake --build "$zephyr_build" >&2

  local kernel="${zephyr_build}/zephyr/zephyr.bin"
  local elf="${zephyr_build}/zephyr/zephyr.elf"
  [ -f "$kernel" ] && [ -f "$elf" ] || die "Zephyr build did not produce ${kernel}"
  RTOS_ENTRY_POINT="$(readelf -h "$elf" | awk '/Entry point address:/ { print $NF }')"
  [ -n "$RTOS_ENTRY_POINT" ] || die "unable to read Zephyr entry point from ${elf}"
  PREPARED_RTOS_KERNEL="$kernel"
}

prepare_rootfs() {
  local source="${AXVISOR_THREE_GUEST_ROOTFS:-}"

  if [ -z "$source" ]; then
    command -v cargo >/dev/null 2>&1 || die "cargo is required to prepare the QEMU rootfs"
    local rootfs_store="${IMAGE_ROOT}/rootfs-managed"
    echo "[three-guest-net] pulling the AArch64 QEMU rootfs"
    (cd "$REPO_ROOT" && \
      TGOS_IMAGE_LOCAL_STORAGE="$rootfs_store" \
      cargo xtask image pull --arch aarch64)
    source="$(find "$rootfs_store" -type f -name 'rootfs-aarch64-alpine.img' -print -quit)"
  fi

  [ -f "$source" ] || die "QEMU rootfs image does not exist: ${source}"
  mkdir -p "$(dirname "$ROOTFS_TARGET")"
  if [ "$(readlink -f "$source")" != "$(readlink -f "$ROOTFS_TARGET")" ]; then
    local rootfs_tmp
    rootfs_tmp="$(mktemp "$(dirname "$ROOTFS_TARGET")/.${ROOTFS_TARGET##*/}.tmp.XXXXXX")"
    if ! cp -- "$source" "$rootfs_tmp"; then
      rm -f -- "$rootfs_tmp"
      die "unable to copy QEMU rootfs image to destination staging: ${ROOTFS_TARGET}"
    fi
    if ! mv -f -- "$rootfs_tmp" "$ROOTFS_TARGET"; then
      rm -f -- "$rootfs_tmp"
      die "unable to atomically publish QEMU rootfs image: ${ROOTFS_TARGET}"
    fi
  fi
  printf '%s\n' "$ROOTFS_TARGET"
}

prepare_linux_initramfs() (
  command -v cpio >/dev/null 2>&1 || die "cpio is required to build the Linux guest initramfs"
  command -v file >/dev/null 2>&1 || die "file is required to validate the Linux initramfs busybox"
  command -v mktemp >/dev/null 2>&1 || die "mktemp is required to isolate initramfs staging"
  command -v sort >/dev/null 2>&1 || die "sort is required for deterministic initramfs ordering"
  command -v touch >/dev/null 2>&1 || die "touch is required for deterministic initramfs metadata"
  mkdir -p "$IMAGE_ROOT"

  local staging_root
  staging_root="$(mktemp -d "${IMAGE_ROOT}/linux-net-initramfs.XXXXXX")"
  local -a temporary_directories=("$staging_root")
  local -a temporary_outputs=()
  cleanup_initramfs() {
    rm -rf -- "${temporary_directories[@]}"
    if [ "${#temporary_outputs[@]}" -gt 0 ]; then
      rm -f -- "${temporary_outputs[@]}"
    fi
  }
  trap cleanup_initramfs EXIT INT TERM
  mkdir -p "$staging_root/bin"

  local busybox="${staging_root}/rootfs-busybox"
  if [ -n "${AXVISOR_THREE_GUEST_BUSYBOX:-}" ]; then
    busybox="${AXVISOR_THREE_GUEST_BUSYBOX}"
    [ -f "$busybox" ] || die "static BusyBox does not exist: ${busybox}"
  else
    command -v debugfs >/dev/null 2>&1 \
      || die "debugfs is required to extract BusyBox from the Linux rootfs"
    local debugfs_log="${IMAGE_ROOT}/debugfs-busybox.log"
    if ! debugfs -R "dump /bin/busybox ${busybox}" "$ROOTFS_TARGET" >"$debugfs_log" 2>&1; then
      die "unable to extract /bin/busybox from ${ROOTFS_TARGET}; see ${debugfs_log}"
    fi
  fi
  [ -s "$busybox" ] || die "Linux BusyBox is empty: ${busybox}"

  # The rootfs BusyBox is commonly dynamic, while the tiny initramfs has no
  # loader. Prefer the static binary shipped in the downloaded guest image.
  if ! file -L "$busybox" | rg -q "statically linked"; then
    command -v gzip >/dev/null 2>&1 \
      || die "gzip is required to extract static BusyBox from the guest initramfs"
    local guest_initramfs="${IMAGE_ROOT}/${LINUX_IMAGE_NAME}/initramfs.cpio.gz"
    local static_root
    static_root="$(mktemp -d "${IMAGE_ROOT}/linux-net-static-busybox.XXXXXX")"
    temporary_directories+=("$static_root")
    [ -f "$guest_initramfs" ] || die "dynamic BusyBox requires a static guest initramfs: ${guest_initramfs}"
    mkdir -p "${static_root}/bin"
    gzip -dc "$guest_initramfs" | (cd "$static_root" && cpio --quiet -id bin/busybox) \
      || die "unable to extract static BusyBox from ${guest_initramfs}"
    busybox="${static_root}/bin/busybox"
  fi
  file -L "$busybox" | rg -q "statically linked" \
    || die "Linux initramfs BusyBox must be statically linked: ${busybox}"

  local busybox_snapshot="${IMAGE_ROOT}/linux-net-busybox.selected"
  local busybox_tmp
  busybox_tmp="$(mktemp "${IMAGE_ROOT}/.linux-net-busybox.selected.tmp.XXXXXX")"
  temporary_outputs+=("$busybox_tmp")
  cp "$busybox" "$busybox_tmp"
  chmod 0755 "$busybox_tmp"
  mv -f -- "$busybox_tmp" "$busybox_snapshot"
  temporary_outputs=("${temporary_outputs[@]:0:${#temporary_outputs[@]}-1}")
  busybox="$busybox_snapshot"

  cp "$busybox" "$staging_root/bin/busybox"
  ln -sfn busybox "$staging_root/bin/sh"
  printf '%s\n' "$busybox"

  local init_name init_src output output_tmp
  for init_name in 1 2; do
    init_src="${AXVISOR_ROOT}/guests/linux-net/init-linux-${init_name}"
    output="${IMAGE_ROOT}/linux-net-${init_name}-initramfs.cpio"
    [ -f "$init_src" ] || die "missing Linux guest init script: ${init_src}"
    cp "$init_src" "$staging_root/init"
    chmod 0755 "$staging_root/init" "$staging_root/bin/busybox"
    find "$staging_root" -exec touch -h -d @0 {} +
    output_tmp="$(mktemp "${IMAGE_ROOT}/.linux-net-${init_name}-initramfs.cpio.tmp.XXXXXX")"
    temporary_outputs+=("$output_tmp")
    (cd "$staging_root" && \
      find . -print0 | LC_ALL=C sort -z \
        | cpio --null --quiet --reproducible --owner=0:0 -o -H newc >"$output_tmp") \
      || die "unable to build Linux guest initramfs: ${output}"
    mv -f -- "$output_tmp" "$output"
    temporary_outputs=("${temporary_outputs[@]:0:${#temporary_outputs[@]}-1}")
    printf '%s\n' "$output"
  done
)

patch_vm_config() {
  local template="$1"
  local output="$2"
  local kernel="$3"
  local entry_point="${4:-}"
  local ramdisk="${5:-}"
  local ramdisk_load_addr="${6:-}"
  local phys_cpu="${7:-}"
  local host_timer_policy="${8:-}"
  local host_vcpu_yield="${9:-}"
  local host_vcpu_idle_policy="${10:-}"
  local -a patches=(
    kernel.image_location string memory
    kernel.kernel_path string "$kernel"
  )
  if [ -n "$entry_point" ]; then
    patches+=(kernel.entry_point integer "$entry_point")
  fi
  if [ -n "$ramdisk" ]; then
    patches+=(kernel.ramdisk_path string "$ramdisk")
  fi
  if [ -n "$ramdisk_load_addr" ]; then
    patches+=(kernel.ramdisk_load_addr integer "$ramdisk_load_addr")
  fi
  if [ -n "$phys_cpu" ]; then
    patches+=(base.phys_cpu_ids cpu-array "$phys_cpu")
    patches+=(devices.emu_devices gicr-cpu "$phys_cpu")
  fi
  if [ -n "$host_timer_policy" ]; then
    patches+=(base.host_timer_policy string "$host_timer_policy")
  fi
  if [ -n "$host_vcpu_yield" ]; then
    patches+=(base.host_vcpu_yield boolean "$host_vcpu_yield")
  fi
  if [ -n "$host_vcpu_idle_policy" ]; then
    patches+=(base.host_vcpu_idle_policy string "$host_vcpu_idle_policy")
  fi

  command -v python3 >/dev/null 2>&1 \
    || die "python3 with tomllib is required to patch VM configs"
  [ -f "$template" ] || die "VM config template does not exist: ${template}"
  mkdir -p "$(dirname "$output")"
  python3 - "$template" "$output" "${patches[@]}" <<'PY'
import json
import os
import pathlib
import re
import stat
import sys
import tempfile
import tomllib


class PatchError(Exception):
    pass


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise PatchError(f"unsupported TOML value type: {type(value).__name__}")


def parse_integer(raw, target):
    try:
        value = tomllib.loads(f"value = {raw}\n")["value"]
    except tomllib.TOMLDecodeError as exc:
        raise PatchError(f"invalid integer for {target}: {raw}: {exc}") from exc
    if isinstance(value, bool) or not isinstance(value, int):
        raise PatchError(f"invalid integer for {target}: {raw}")
    return value


def replacement_value(kind, raw, target, document):
    if kind == "string":
        return raw
    if kind == "integer":
        return parse_integer(raw, target)
    if kind == "boolean":
        if raw not in ("true", "false"):
            raise PatchError(f"invalid boolean for {target}: {raw}")
        return raw == "true"
    if kind == "cpu-array":
        return [parse_integer(raw, target)]
    if kind == "gicr-cpu":
        pcpu = parse_integer(raw, target)
        rows = document["devices"]["emu_devices"]
        matches = [row for row in rows if isinstance(row, list) and row and row[0] == "gppt-gicr"]
        if len(matches) != 1:
            raise PatchError(
                f"requested TOML target devices.emu_devices must contain exactly one gppt-gicr row; found {len(matches)}"
            )
        if not isinstance(matches[0][-1], list) or len(matches[0][-1]) != 3:
            raise PatchError("gppt-gicr affinity must be a three-element array")
        matches[0][-1][-1] = pcpu
        return rows
    raise PatchError(f"unsupported patch type for {target}: {kind}")


def key_span(lines, section, key):
    current_section = None
    starts = []
    table_re = re.compile(r"^\s*\[([^]]+)]\s*(?:#.*)?$")
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index, line in enumerate(lines):
        table = table_re.match(line)
        if table:
            current_section = table.group(1).strip()
            continue
        if current_section == section and key_re.match(line):
            starts.append(index)
    if len(starts) != 1:
        raise PatchError(
            f"requested TOML key {section}.{key} must occur exactly once; found {len(starts)}"
        )

    start = starts[0]
    for end in range(start, len(lines)):
        fragment = f"[{section}]\n" + "".join(lines[start : end + 1])
        try:
            parsed = tomllib.loads(fragment)
        except tomllib.TOMLDecodeError:
            continue
        if key in parsed.get(section, {}):
            return start, end
    raise PatchError(f"unable to determine TOML value span for {section}.{key}")


def main():
    template_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    raw_specs = sys.argv[3:]
    if len(raw_specs) % 3:
        raise PatchError("internal patch specification is incomplete")

    template_text = template_path.read_text()
    try:
        document = tomllib.loads(template_text)
    except tomllib.TOMLDecodeError as exc:
        raise PatchError(f"invalid VM config template {template_path}: {exc}") from exc

    lines = template_text.splitlines(keepends=True)
    replacements = []
    for target, kind, raw in zip(raw_specs[0::3], raw_specs[1::3], raw_specs[2::3]):
        section, key = target.split(".", 1)
        table = document.get(section)
        if not isinstance(table, dict) or key not in table:
            raise PatchError(f"requested TOML key {target} is absent from {template_path}")
        value = replacement_value(kind, raw, target, document)
        start, end = key_span(lines, section, key)
        indentation = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
        replacements.append((start, end, f"{indentation}{key} = {toml_value(value)}\n"))
        table[key] = value

    for start, end, replacement in sorted(replacements, reverse=True):
        lines[start : end + 1] = [replacement]
    output_text = "".join(lines)
    try:
        tomllib.loads(output_text)
    except tomllib.TOMLDecodeError as exc:
        raise PatchError(f"patched VM config is invalid TOML: {exc}") from exc

    output_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.tmp.", dir=output_path.parent
    )
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, stat.S_IMODE(template_path.stat().st_mode))
        with os.fdopen(descriptor, "w") as temporary:
            temporary.write(output_text)
            temporary.flush()
            os.fsync(temporary.fileno())
        with temporary_path.open("rb") as generated:
            tomllib.load(generated)
        os.replace(temporary_path, output_path)
        directory_fd = os.open(output_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary_path.unlink(missing_ok=True)


try:
    main()
except (OSError, PatchError) as exc:
    print(f"[three-guest-net] ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

write_artifact_manifest() {
  local manifest_path="$1"
  shift
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to write the artifact manifest"
  mkdir -p "$(dirname "$manifest_path")"
  python3 - "$manifest_path" "$@" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys
import tempfile


class ManifestError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    manifest_path = pathlib.Path(sys.argv[1])
    raw_artifacts = sys.argv[2:]
    if len(raw_artifacts) % 2:
        raise ManifestError("internal artifact manifest specification is incomplete")

    published_root = os.environ.get("AXVISOR_THREE_GUEST_MANIFEST_PUBLISHED_ROOT")
    published_config_labels = {
        "linux-1-vm-config",
        "linux-2-vm-config",
        "zephyr-vm-config",
    }
    records = []
    labels = set()
    for label, raw_path in zip(raw_artifacts[0::2], raw_artifacts[1::2]):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", label):
            raise ManifestError(f"invalid artifact label: {label!r}")
        if label in labels:
            raise ManifestError(f"duplicate artifact label: {label}")
        labels.add(label)
        path = pathlib.Path(raw_path)
        if not path.is_file():
            raise ManifestError(f"artifact does not exist: {label}: {path}")
        canonical = path.resolve()
        if "\t" in str(canonical) or "\n" in str(canonical):
            raise ManifestError(f"artifact path contains TAB or newline: {label}: {canonical}")
        recorded_path = canonical
        if published_root and label in published_config_labels:
            recorded_path = pathlib.Path(published_root).absolute() / path.name
        records.append((label, recorded_path, sha256(canonical)))

    content = "version\t1\n" + "".join(
        f"{label}\t{path}\t{digest}\n" for label, path, digest in records
    )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{manifest_path.name}.tmp.", dir=manifest_path.parent
    )
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
        with os.fdopen(descriptor, "w") as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, manifest_path)
        directory_fd = os.open(manifest_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary_path.unlink(missing_ok=True)


try:
    main()
except (ManifestError, OSError) as exc:
    print(f"[three-guest-net] ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_staged_manifest() {
  local manifest_path="$1"
  local staged_root="$2"
  python3 - "$manifest_path" "$staged_root" <<'PY'
import hashlib
import pathlib
import sys


class ManifestError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


manifest_path = pathlib.Path(sys.argv[1])
staged_root = pathlib.Path(sys.argv[2])
config_labels = {
    "linux-1-vm-config",
    "linux-2-vm-config",
    "zephyr-vm-config",
}
try:
    lines = manifest_path.read_text().splitlines()
    if not lines or lines[0] != "version\t1" or len(lines) != 10:
        raise ManifestError("artifact manifest must contain version plus exactly nine records")
    for line in lines[1:]:
        label, raw_path, expected = line.split("\t")
        path = staged_root / pathlib.Path(raw_path).name if label in config_labels else pathlib.Path(raw_path)
        if not path.is_file():
            raise ManifestError(f"manifest validation artifact does not exist: {label}: {path}")
        actual = sha256(path)
        if actual != expected:
            raise ManifestError(f"manifest checksum mismatch: {label}: expected {expected}, got {actual}")
except (OSError, ValueError, ManifestError) as exc:
    print(f"[three-guest-net] ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_generated_set() {
  local vm_root="$1"
  AXVISOR_THREE_GUEST_VERIFY_VM_ROOT="$vm_root" \
  AXVISOR_THREE_GUEST_VERIFY_QEMU_CONFIG="$QEMU_CONFIG" \
  AXVISOR_THREE_GUEST_VERIFY_EXPECTED_IDLE_POLICY="$HOST_VCPU_IDLE_POLICY" \
  AXVISOR_THREE_GUEST_VERIFY_TOPOLOGY_ONLY=0 \
    bash "${SCRIPT_DIR}/verify_three_guest_net.sh"
}

publish_generated_set() {
  local staged_root="$1"
  python3 - "$GENERATED_BASE" "$GENERATED_ROOT" "$staged_root" <<'PY'
import os
import pathlib
import sys
import tempfile


base = pathlib.Path(sys.argv[1])
current = pathlib.Path(sys.argv[2])
staged = pathlib.Path(sys.argv[3])
temporary_dir = None
try:
    if staged.parent.resolve() != base.resolve():
        raise ValueError(f"staged set must be a direct child of {base}: {staged}")
    if current.exists() and not current.is_symlink():
        raise ValueError(f"published generated root must be a symlink: {current}")
    temporary_dir = pathlib.Path(tempfile.mkdtemp(prefix=".publish.", dir=base))
    temporary_link = temporary_dir / "current"
    temporary_link.symlink_to(staged.name)
    os.replace(temporary_link, current)
    directory_fd = os.open(base, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except (OSError, ValueError) as exc:
    print(f"[three-guest-net] ERROR: unable to atomically publish generated set: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    if temporary_dir is not None:
        try:
            temporary_dir.rmdir()
        except OSError:
            pass
PY
}

main() (
preflight_common
linux_kernel="$(prepare_linux_kernel)"
prepare_rtos_kernel
rtos_kernel="$PREPARED_RTOS_KERNEL"
prepare_rootfs >/dev/null
mapfile -t prepared_initramfs < <(prepare_linux_initramfs)
[ "${#prepared_initramfs[@]}" -eq 3 ] \
  || die "expected one selected BusyBox and two Linux initramfs images"
selected_busybox="${prepared_initramfs[0]}"
linux_initramfs=("${prepared_initramfs[@]:1}")

mkdir -p "$GENERATED_BASE"
staged_root="$(mktemp -d "${GENERATED_BASE}/run.XXXXXX")"
published=false
cleanup_generated_set() {
  if [ "$published" = false ]; then
    if [ -L "$GENERATED_ROOT" ] \
      && [ "$(readlink "$GENERATED_ROOT")" = "${staged_root##*/}" ]; then
      return
    fi
    rm -rf -- "$staged_root"
  fi
}
trap cleanup_generated_set EXIT INT TERM

patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/linux-net-1.toml" \
  "${staged_root}/linux-net-1.toml" \
  "$linux_kernel" \
  "" \
  "${linux_initramfs[0]}" \
  "0x8c00_0000"
patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/linux-net-2.toml" \
  "${staged_root}/linux-net-2.toml" \
  "$linux_kernel" \
  "" \
  "${linux_initramfs[1]}" \
  "0x9c00_0000"
patch_vm_config \
  "${AXVISOR_ROOT}/configs/vms/qemu/aarch64/zephyr-net.toml" \
  "${staged_root}/zephyr-net.toml" \
  "$rtos_kernel" \
  "${RTOS_ENTRY_POINT:-${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-}}" \
  "" \
  "" \
  "$RTOS_PCPU" \
  "$HOST_TIMER_POLICY" \
  "$HOST_VCPU_YIELD" \
  "$HOST_VCPU_IDLE_POLICY"

verify_generated_set "$staged_root"

staged_manifest="${staged_root}/artifacts.tsv"
AXVISOR_THREE_GUEST_MANIFEST_PUBLISHED_ROOT="$GENERATED_ROOT" \
write_artifact_manifest \
  "$staged_manifest" \
  linux-kernel "$linux_kernel" \
  rtos-kernel "$rtos_kernel" \
  rootfs "$ROOTFS_TARGET" \
  busybox "$selected_busybox" \
  linux-1-initramfs "${linux_initramfs[0]}" \
  linux-2-initramfs "${linux_initramfs[1]}" \
  linux-1-vm-config "${staged_root}/linux-net-1.toml" \
  linux-2-vm-config "${staged_root}/linux-net-2.toml" \
  zephyr-vm-config "${staged_root}/zephyr-net.toml"
validate_staged_manifest "$staged_manifest" "$staged_root"
publish_generated_set "$staged_root"
published=true
manifest_path="${GENERATED_ROOT}/artifacts.tsv"

cat <<EOF

[three-guest-net] prepared successfully
  Linux kernel: ${linux_kernel}
  RTOS kernel:  ${rtos_kernel}
  RTOS entry:   ${RTOS_ENTRY_POINT:-${AXVISOR_THREE_GUEST_RTOS_ENTRY_POINT:-template}}
  RTOS pCPU:    ${RTOS_PCPU}
  Host timer:  ${HOST_TIMER_POLICY}
  vCPU yield:  ${HOST_VCPU_YIELD}
  vCPU idle:   ${HOST_VCPU_IDLE_POLICY}
  Rootfs:       ${ROOTFS_TARGET}
  VM configs:   ${GENERATED_ROOT}
  Manifest:     ${manifest_path}

Run:
  cd ${REPO_ROOT}
  cargo xtask axvisor qemu \\
    --config os/axvisor/configs/board/qemu-aarch64.toml \\
    --qemu-config os/axvisor/configs/qemu/qemu-aarch64-three-guest-net.toml \\
    --rootfs ${ROOTFS_TARGET} \\
    --vmconfigs ${GENERATED_ROOT}/linux-net-1.toml \\
    --vmconfigs ${GENERATED_ROOT}/linux-net-2.toml \\
    --vmconfigs ${GENERATED_ROOT}/zephyr-net.toml

Guest network:
  Linux-1: 192.168.77.11/24, MAC 52:54:00:77:00:01
  Linux-2: 192.168.77.12/24, MAC 52:54:00:77:00:02
  Zephyr:  192.168.77.13/24, MAC 52:54:00:77:00:03
EOF
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
