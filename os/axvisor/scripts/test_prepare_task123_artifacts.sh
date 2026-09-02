#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
RESOLVER="$ROOT/os/axvisor/scripts/task123_artifacts.py"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

expect_failure() {
    local description=$1
    shift
    if "$@" > "$tmp/failure.out" 2>&1; then
        fail "$description"
    fi
}

expect_resolver_error() {
    local description=$1
    shift
    local status

    set +e
    "$@" > "$tmp/failure.out" 2>&1
    status=$?
    set -e
    [[ $status -eq 2 ]] || fail "$description returned $status instead of 2"
    rg -q '^task123 artifacts:' "$tmp/failure.out" ||
        fail "$description omitted the required diagnostic prefix"
}

artifact_line() {
    local name=$1
    local path=$2
    printf 'ARTIFACT name=%s path=%s sha256=%s\n' \
        "$name" "$path" "$(sha256sum "$path" | awk '{print $1}')"
}

fixture="$tmp/fixture"
evidence="$fixture/tmp/task123-results/accepted"
cache="$fixture/tmp/task123-cache"
mkdir -p -- "$evidence" "$cache/artifacts/cache-key" "$fixture/config"
printf 'lock=v1\n' > "$fixture/config/dependencies.lock"

for name in qemu linux-kernel linux-initramfs model rootfs \
    rtthread-normal rtthread-drop-status rtthread-delayed-server; do
    printf 'evidence-%s\n' "$name" > "$evidence/$name.bin"
done

{
    printf 'schema=1\nresult_gate=PASS\n'
    artifact_line qemu "$evidence/qemu.bin"
    artifact_line linux-kernel "$evidence/linux-kernel.bin"
    artifact_line linux-initramfs "$evidence/linux-initramfs.bin"
    artifact_line model "$evidence/model.bin"
    artifact_line rootfs "$evidence/rootfs.bin"
    artifact_line rtthread-normal "$evidence/rtthread-normal.bin"
    artifact_line rtthread-drop-status "$evidence/rtthread-drop-status.bin"
    artifact_line rtthread-delayed-server "$evidence/rtthread-delayed-server.bin"
} > "$evidence/manifest.txt"

rt_repo="$fixture/tmp/local-rt-thread"
git init -q "$rt_repo"
git -C "$rt_repo" config user.email task123@example.invalid
git -C "$rt_repo" config user.name task123-test
mkdir -p "$rt_repo/bsp/qemu-virt64-aarch64" "$rt_repo/components" "$rt_repo/src"
printf 'fixture\n' > "$rt_repo/bsp/qemu-virt64-aarch64/Kconfig"
printf 'fixture\n' > "$rt_repo/components/Kconfig"
printf 'fixture\n' > "$rt_repo/src/Kconfig"
git -C "$rt_repo" add .
git -C "$rt_repo" commit -qm fixture
rt_commit="$(git -C "$rt_repo" rev-parse HEAD)"

common_args=(
    resolve
    --root "$fixture"
    --cache "$cache"
    --evidence-root "$fixture/tmp/task123-results"
    --lock-file "$fixture/config/dependencies.lock"
    --rtthread-commit "$rt_commit"
)

[[ -f "$RESOLVER" ]] || fail "task123_artifacts.py is missing"

expect_resolver_error "argument parsing failure" \
    python3 "$RESOLVER" resolve

python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/evidence.json"
python3 - "$tmp/evidence.json" "$rt_repo" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
assert data["schema"] == 1
assert len(data["fingerprint"]) == 64
assert set(data["artifacts"]) == {
    "qemu", "linux_kernel", "linux_initramfs", "model", "rootfs",
    "rtthread_normal", "rtthread_drop_status", "rtthread_delayed_server",
}
assert all(item["origin"] == "evidence" for item in data["artifacts"].values())
assert data["missing"] == []
assert data["rtthread_repository"]["origin"] == "local_git"
assert data["rtthread_repository"]["path"] == str(Path(sys.argv[2]).resolve())
PY

real_git="$(command -v git)"
fake_bin="$tmp/fake-bin"
git_env_log="$tmp/git-env.log"
mkdir -p "$fake_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${REAL_GIT:?}" "${GIT_ENV_LOG:?}"' \
    'printf "%s\n" "${GIT_NO_LAZY_FETCH-}" >> "$GIT_ENV_LOG"' \
    '[[ ${GIT_NO_LAZY_FETCH-} == 1 ]] || exit 96' \
    'exec "$REAL_GIT" "$@"' > "$fake_bin/git"
chmod +x "$fake_bin/git"
PATH="$fake_bin:$PATH" REAL_GIT="$real_git" GIT_ENV_LOG="$git_env_log" \
    python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/git-env.json"
[[ -s "$git_env_log" ]] || fail "resolver made no checked Git calls"
if rg -n -v '^1$' "$git_env_log"; then
    fail "resolver Git subprocess omitted GIT_NO_LAZY_FETCH=1"
fi

invalid_repo="$tmp/invalid-rt-thread"
git init -q "$invalid_repo"
git -C "$invalid_repo" config user.email task123@example.invalid
git -C "$invalid_repo" config user.name task123-test
printf 'unrelated\n' > "$invalid_repo/README"
git -C "$invalid_repo" add README
git -C "$invalid_repo" commit -qm unrelated
expect_resolver_error "invalid explicit RT-Thread repository" \
    python3 "$RESOLVER" "${common_args[@]}" \
        --rtthread-repository "$invalid_repo" \
        --output "$tmp/invalid-repository.json"
[[ ! -e "$tmp/invalid-repository.json" ]] ||
    fail "invalid explicit RT-Thread repository fell back to local discovery"

explicit="$tmp/explicit-kernel"
printf 'explicit\n' > "$explicit"
python3 "$RESOLVER" "${common_args[@]}" \
    --linux-kernel "$explicit" --output "$tmp/explicit.json"
python3 - "$tmp/explicit.json" "$explicit" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
item = data["artifacts"]["linux_kernel"]
assert item["origin"] == "explicit"
assert item["path"] == str(Path(sys.argv[2]).resolve())
PY

expect_failure "missing explicit input fell through to evidence" \
    python3 "$RESOLVER" "${common_args[@]}" \
        --linux-kernel "$tmp/does-not-exist" --output "$tmp/missing-explicit.json"

cache_kernel="$cache/artifacts/cache-key/linux-kernel.bin"
printf 'cache-kernel\n' > "$cache_kernel"
{
    printf 'schema=1\ncache_status=VALID\n'
    artifact_line linux-kernel "$cache_kernel"
} > "$cache/artifacts/cache-key/manifest.txt"
python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/cache.json"
python3 - "$tmp/cache.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
assert data["artifacts"]["linux_kernel"]["origin"] == "cache"
PY

sed -i 's/sha256=[0-9a-f]\{64\}/sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$cache/artifacts/cache-key/manifest.txt"
python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/bad-cache.json"
python3 - "$tmp/bad-cache.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
assert data["artifacts"]["linux_kernel"]["origin"] == "evidence"
PY

python3 - "$cache/artifacts/cache-key/manifest.txt" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(
    b"schema=1\ncache_status=VALID\n"
    b"ARTIFACT name=linux-kernel path=bad\0path "
    b"sha256=0000000000000000000000000000000000000000000000000000000000000000\n"
)
PY
python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/pathological-cache.json"
python3 - "$tmp/pathological-cache.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
assert data["artifacts"]["linux_kernel"]["origin"] == "evidence"
PY

sed -i 's/result_gate=PASS/result_gate=FAIL/' "$evidence/manifest.txt"
python3 "$RESOLVER" "${common_args[@]}" --output "$tmp/no-evidence.json"
python3 - "$tmp/no-evidence.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
assert "qemu" in data["missing"]
assert "linux_kernel" in data["missing"]
PY

if rg -n '/home/|yfblock|tgoskits/tmp' "$RESOLVER"; then
    fail "resolver contains a workstation-specific path"
fi
if rg -n '/home/|yfblock|tgoskits/tmp' "$tmp/evidence.json"; then
    fail "resolver emitted a workstation-specific path"
fi

echo "task123 artifact resolver tests: PASS"
