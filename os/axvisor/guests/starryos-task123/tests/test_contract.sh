#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)"
VM_CONFIG="$ROOT/os/axvisor/configs/vms/qemu/aarch64/starryos-task123.toml"
BUILD_CONFIG="$ROOT/os/StarryOS/configs/axvisor/task123-aarch64.toml"
STARRY_MANIFEST="$ROOT/os/StarryOS/starryos/Cargo.toml"
KERNEL_MANIFEST="$ROOT/os/StarryOS/kernel/Cargo.toml"
AXSTD_MANIFEST="$ROOT/os/arceos/ulib/axstd/Cargo.toml"
RUNTIME_MANIFEST="$ROOT/os/arceos/modules/axruntime/Cargo.toml"
RUNTIME_FS="$ROOT/os/arceos/modules/axruntime/src/fs/mod.rs"
STARRY_PROCFS="$ROOT/os/StarryOS/kernel/src/pseudofs/proc.rs"
GUEST_ROOT="$ROOT/os/axvisor/guests/starryos-task123"
ROOTFS_BUILDER="$GUEST_ROOT/build_rootfs.sh"
GUEST_BUILDER="$GUEST_ROOT/build.sh"
GUEST_INIT="$GUEST_ROOT/rootfs/init"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$VM_CONFIG" ]] || fail "StarryOS AxVisor VM config is missing"
[[ -f "$BUILD_CONFIG" ]] || fail "StarryOS Task 1/2/3 build config is missing"
[[ -x "$ROOTFS_BUILDER" ]] || fail "deterministic StarryOS rootfs builder is missing"
[[ -x "$GUEST_BUILDER" ]] || fail "one-shot StarryOS guest builder is missing"
[[ -f "$GUEST_INIT" ]] || fail "StarryOS guest init is missing"

grep -Fxq 'guest_type = "virtualized"' "$VM_CONFIG" ||
    fail "StarryOS guest must use virtualized mode"
grep -Fxq 'cpu_num = 2' "$VM_CONFIG" ||
    fail "StarryOS guest must expose two vCPUs"
grep -Fq 'model = "virtio-net"' "$VM_CONFIG" ||
    fail "StarryOS guest must expose virtio-net"
grep -Fq 'starryos-task123' "$VM_CONFIG" ||
    fail "StarryOS VM config must identify the replacement guest"
! grep -Eq 'linux(-kernel|[-_])|linux-net|Image' "$VM_CONFIG" ||
    fail "StarryOS VM config must not reference the Linux guest"
grep -Fq 'axvisor-guest' "$BUILD_CONFIG" ||
    fail "StarryOS build config must enable the explicit AxVisor guest path"
grep -Fq 'aarch64-unknown-none-softfloat' "$BUILD_CONFIG" ||
    fail "StarryOS build target must be AArch64"

python3 - "$STARRY_MANIFEST" "$KERNEL_MANIFEST" "$AXSTD_MANIFEST" "$RUNTIME_MANIFEST" <<'PY'
import sys
import tomllib

starry_path, kernel_path, axstd_path, runtime_path = sys.argv[1:]

def load(path):
    with open(path, "rb") as stream:
        return tomllib.load(stream)

starry = load(starry_path)
kernel = load(kernel_path)
axstd = load(axstd_path)
runtime = load(runtime_path)

guest = set(starry.get("features", {}).get("axvisor-guest", []))
required = {
    "ax-std/embedded-rootfs",
    "ax-std/net",
    "starry-kernel/embedded-rootfs",
}
if not required <= guest:
    raise SystemExit("FAIL: axvisor-guest does not propagate embedded rootfs and networking")

starry_deps = starry.get("dependencies", {})
if "fs" in starry_deps.get("ax-std", {}).get("features", []):
    raise SystemExit("FAIL: StarryOS unconditionally enables block-backed ax-std/fs")
if "ext4" in starry_deps.get("starry-kernel", {}).get("features", []):
    raise SystemExit("FAIL: StarryOS unconditionally enables ext4")

embedded = set(axstd.get("features", {}).get("embedded-rootfs", []))
if "ax-runtime/embedded-rootfs" not in embedded:
    raise SystemExit("FAIL: ax-std embedded-rootfs does not select the runtime path")
if any("nvme" in feature or "ext4" in feature for feature in embedded):
    raise SystemExit("FAIL: embedded-rootfs must not depend on NVMe or ext4")

if "embedded-rootfs" not in kernel.get("features", {}):
    raise SystemExit("FAIL: starry-kernel has no embedded-rootfs feature")
if "embedded-rootfs" not in runtime.get("features", {}):
    raise SystemExit("FAIL: ax-runtime has no embedded-rootfs feature")
PY

python3 - "$RUNTIME_FS" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
embedded = re.search(
    r'if #\[cfg\(feature = "embedded-rootfs"\)\] \{(?P<body>.*?)'
    r'\} else if #\[cfg\(feature = "fs"\)\]',
    source,
    re.DOTALL,
)
if embedded is None:
    raise SystemExit("FAIL: embedded-rootfs runtime branch is missing")
if "block::online_smp()" in embedded.group("body"):
    raise SystemExit(
        "FAIL: embedded-rootfs must not expand the uninstalled block runtime after SMP online"
    )
PY

python3 - "$STARRY_PROCFS" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
builder = re.search(
    r"fn builder\(fs: Arc<SimpleFs>\) -> DirMaker \{(?P<body>.*)\n\}",
    source,
    re.DOTALL,
)
if builder is None:
    raise SystemExit("FAIL: StarryOS procfs builder is missing")
body = builder.group("body")
if not re.search(r'root\.add\(\s*"cmdline"', body):
    raise SystemExit("FAIL: StarryOS procfs must expose root /proc/cmdline")
if "ax_runtime::hal::boot::bootargs()" not in body:
    raise SystemExit("FAIL: /proc/cmdline must read the guest bootargs")
PY

grep -Fq 'STARRY_SMP_READY' "$GUEST_INIT" ||
    fail "StarryOS init must report the two-vCPU gate"
grep -Fq 'STARRY_NET_READY' "$GUEST_INIT" ||
    fail "StarryOS init must report the network gate"
grep -Fq 'TASK2_STARRY_BEGIN' "$GUEST_INIT" ||
    fail "StarryOS init must launch Task 2"
grep -Fq 'RT-IPC client exited with rc=%s' "$GUEST_INIT" ||
    fail "StarryOS init must authenticate the RT-IPC client exit status"
grep -Fq 'TASK3_STARRY_END' "$GUEST_INIT" ||
    fail "StarryOS init must launch Task 3"
grep -Fq 'rtbench.net.count=' "$GUEST_INIT" ||
    fail "StarryOS init must accept the RTBench network sample count"
grep -Fq '/usr/bin/rtbench-net-probe' "$GUEST_INIT" ||
    fail "StarryOS init must launch the RTBench network probe"
grep -Fq 'usr/bin/rtbench-net-probe' "$ROOTFS_BUILDER" ||
    fail "StarryOS rootfs must include the RTBench network probe"
grep -Fq 'STARRY_EMBEDDED_ROOTFS=' "$GUEST_BUILDER" ||
    fail "StarryOS build must pass the generated CPIO explicitly"
grep -Fq -- '--reproducible' "$ROOTFS_BUILDER" ||
    fail "StarryOS rootfs generation must be reproducible"
for mountpoint in dev proc sys tmp; do
    grep -Fq "mkdir -p \"\$stage/\$mountpoint\"" "$ROOTFS_BUILDER" ||
        fail "StarryOS rootfs must pre-create /$mountpoint for pseudofs mounting"
done
! grep -Eq '(curl|wget|git clone)' "$ROOTFS_BUILDER" ||
    fail "StarryOS rootfs builder must not download sources"

printf 'starryos task123 contract: PASS\n'
