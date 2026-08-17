#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
SOURCE_RUNNER="$ROOT/run-native.sh"
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

[[ -x "$SOURCE_RUNNER" ]] || fail "run-native.sh is missing or not executable"

fixture="$tmp/project"
tools="$tmp/tools"
mkdir -p "$fixture/os/axvisor/scripts" "$fixture/tmp/task123-native-inputs" "$tools"
cp "$SOURCE_RUNNER" "$fixture/run-native.sh"
cp "$ROOT/os/axvisor/scripts/task123_artifacts.py" \
    "$fixture/os/axvisor/scripts/task123_artifacts.py"
chmod +x "$fixture/run-native.sh"
mkdir -p "$fixture/os/axvisor/guests/task3/configs"
printf 'fixture-lock=1\n' > \
    "$fixture/os/axvisor/guests/task3/configs/dependencies.lock"

cat > "$tools/qemu-system-aarch64" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tools/qemu-system-aarch64"

cat > "$fixture/os/axvisor/scripts/run_task123.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

{
    printf 'ARGS='
    printf '%q ' "$@"
    printf '\n'
    for name in LINUX_KERNEL_IMAGE LINUX_INITRAMFS_IMAGE TASK123_MODEL_IMAGE \
        ROOTFS_IMAGE RTTHREAD_REPOSITORY; do
        printf '%s=%s\n' "$name" "${!name-}"
    done
    printf 'QEMU=%s\n' "${QEMU-}"
} > "$FAKE_CALL_LOG"

output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$output" ]]
mkdir -p -- "$output"
printf 'result_gate=PASS\n' > "$output/manifest.txt"
EOF
chmod +x "$fixture/os/axvisor/scripts/run_task123.sh"

inputs="$fixture/tmp/task123-native-inputs"
for artifact in linux-kernel linux-initramfs.cpio model_weights.h rootfs.img; do
    printf 'fixture-%s\n' "$artifact" > "$inputs/$artifact"
done

rtthread="$fixture/tmp/rt-thread-5.2.2"
git init -q "$rtthread"
git -C "$rtthread" config user.email task123@example.invalid
git -C "$rtthread" config user.name task123-test
mkdir -p "$rtthread/bsp/qemu-virt64-aarch64" \
    "$rtthread/components" "$rtthread/src"
printf 'fixture\n' > "$rtthread/bsp/qemu-virt64-aarch64/Kconfig"
printf 'fixture\n' > "$rtthread/components/Kconfig"
printf 'fixture\n' > "$rtthread/src/Kconfig"
git -C "$rtthread" add .
git -C "$rtthread" commit -qm fixture
rtthread_commit="$(git -C "$rtthread" rev-parse HEAD)"

dirty_rtthread="$fixture/tmp/aa-dirty-rt-thread"
git clone -q --no-hardlinks "$rtthread" "$dirty_rtthread"
printf 'dirty\n' >> "$dirty_rtthread/src/Kconfig"

wrong_rtthread="$fixture/tmp/ab-wrong-rt-thread"
git init -q "$wrong_rtthread"
git -C "$wrong_rtthread" config user.email task123@example.invalid
git -C "$wrong_rtthread" config user.name task123-test
mkdir -p "$wrong_rtthread/bsp/qemu-virt64-aarch64" \
    "$wrong_rtthread/components" "$wrong_rtthread/src"
printf 'wrong\n' > "$wrong_rtthread/bsp/qemu-virt64-aarch64/Kconfig"
printf 'wrong\n' > "$wrong_rtthread/components/Kconfig"
printf 'wrong\n' > "$wrong_rtthread/src/Kconfig"
git -C "$wrong_rtthread" add .
git -C "$wrong_rtthread" commit -qm wrong

incomplete_rtthread="$fixture/tmp/ac-incomplete-rt-thread"
git init -q "$incomplete_rtthread"
git -C "$incomplete_rtthread" config user.email task123@example.invalid
git -C "$incomplete_rtthread" config user.name task123-test
mkdir -p "$incomplete_rtthread/bsp/qemu-virt64-aarch64" \
    "$incomplete_rtthread/components" "$incomplete_rtthread/src"
printf 'missing-object\n' > "$incomplete_rtthread/bsp/qemu-virt64-aarch64/Kconfig"
printf 'fixture\n' > "$incomplete_rtthread/components/Kconfig"
printf 'fixture\n' > "$incomplete_rtthread/src/Kconfig"
git -C "$incomplete_rtthread" add .
git -C "$incomplete_rtthread" commit -qm fixture
missing_object="$(git -C "$incomplete_rtthread" rev-parse \
    HEAD:bsp/qemu-virt64-aarch64/Kconfig)"
rm -- "$incomplete_rtthread/.git/objects/${missing_object:0:2}/${missing_object:2}"

run_native() {
    local mode=$1
    local output=$2
    FAKE_CALL_LOG="$tmp/$mode.call" \
    PATH="$tools:$PATH" \
    NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
        "$fixture/run-native.sh" "$mode" --output "$output"
}

assert_mode() {
    local mode=$1
    local expected=$2
    local output="$tmp/output-$mode"
    run_native "$mode" "$output" > "$tmp/$mode.stdout"
    grep -Fxq "ARGS=$expected --output $output " "$tmp/$mode.call" || {
        cat "$tmp/$mode.call" >&2
        fail "$mode mapped to incorrect runner arguments"
    }
    grep -Fxq 'QEMU=' "$tmp/$mode.call" ||
        fail "$mode wrapper exported QEMU"
    grep -Fxq "Native mode: $mode" "$tmp/$mode.stdout" ||
        fail "$mode was not announced"
}

assert_mode smoke '--mode smoke --task2-count 100 --task3-frames 3'
assert_mode suite '--mode realtime-suite --rtbench-samples 1000 --task2-count 1000'
assert_mode stability '--mode stability --seconds 300 --task2-count 30000'

for mode in smoke suite stability; do
    call="$tmp/$mode.call"
    grep -Fxq "LINUX_KERNEL_IMAGE=$inputs/linux-kernel" "$call" ||
        fail "$mode did not discover the Linux kernel"
    grep -Fxq "LINUX_INITRAMFS_IMAGE=$inputs/linux-initramfs.cpio" "$call" ||
        fail "$mode did not discover the initramfs"
    grep -Fxq "TASK123_MODEL_IMAGE=$inputs/model_weights.h" "$call" ||
        fail "$mode did not discover the model"
    grep -Fxq "ROOTFS_IMAGE=$inputs/rootfs.img" "$call" ||
        fail "$mode did not discover rootfs"
    grep -Fxq "RTTHREAD_REPOSITORY=$rtthread" "$call" ||
        fail "$mode did not discover complete RT-Thread source"
done

evidence="$fixture/tmp/task123-results/accepted"
mkdir -p "$evidence"
for artifact in qemu linux-kernel linux-initramfs model rootfs \
    rtthread-normal rtthread-drop-status rtthread-delayed-server; do
    printf 'evidence-%s\n' "$artifact" > "$evidence/$artifact"
done
{
    printf 'schema=1\nresult_gate=PASS\n'
    for artifact in qemu linux-kernel linux-initramfs model rootfs \
        rtthread-normal rtthread-drop-status rtthread-delayed-server; do
        printf 'ARTIFACT name=%s path=%s sha256=%s\n' \
            "$artifact" "$evidence/$artifact" \
            "$(sha256sum "$evidence/$artifact" | awk '{print $1}')"
    done
} > "$evidence/manifest.txt"
mv "$inputs" "$fixture/tmp/task123-native-inputs.hidden"
FAKE_CALL_LOG="$tmp/evidence.call" PATH="$tools:$PATH" \
NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    "$fixture/run-native.sh" smoke --output "$tmp/output-evidence" >/dev/null
grep -Fxq "LINUX_KERNEL_IMAGE=$evidence/linux-kernel" "$tmp/evidence.call" ||
    fail "accepted evidence was not used after conventional inputs were absent"
grep -Fxq "ROOTFS_IMAGE=$evidence/rootfs" "$tmp/evidence.call" ||
    fail "accepted evidence rootfs was not selected"
mv "$fixture/tmp/task123-native-inputs.hidden" "$inputs"

explicit="$tmp/explicit-inputs"
mkdir -p "$explicit"
for artifact in linux-kernel linux-initramfs.cpio model_weights.h rootfs.img; do
    printf 'explicit-%s\n' "$artifact" > "$explicit/$artifact"
done
FAKE_CALL_LOG="$tmp/explicit.call" PATH="$tools:$PATH" \
NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    "$fixture/run-native.sh" smoke --input-dir "$explicit" \
    --output "$tmp/output-explicit" >/dev/null
grep -Fxq "LINUX_KERNEL_IMAGE=$explicit/linux-kernel" "$tmp/explicit.call" ||
    fail "explicit input directory did not take precedence"

mkdir -p "$tmp/nonempty"
printf 'owned\n' > "$tmp/nonempty/file"
expect_failure "nonempty output was accepted" env \
    FAKE_CALL_LOG="$tmp/nonempty.call" PATH="$tools:$PATH" \
    NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    "$fixture/run-native.sh" smoke --output "$tmp/nonempty"
expect_failure "duplicate modes were accepted" \
    "$fixture/run-native.sh" smoke suite
expect_failure "unknown option was accepted" \
    "$fixture/run-native.sh" --unknown
expect_failure "missing explicit input directory was accepted" env \
    PATH="$tools:$PATH" NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    "$fixture/run-native.sh" smoke --input-dir "$tmp/missing"
expect_failure "dirty explicit RT-Thread source was accepted" env \
    PATH="$tools:$PATH" NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    RTTHREAD_SRC="$dirty_rtthread" \
    "$fixture/run-native.sh" smoke --output "$tmp/output-dirty-source"
expect_failure "wrong-commit explicit RT-Thread source was accepted" env \
    PATH="$tools:$PATH" NATIVE_RTTHREAD_COMMIT="$rtthread_commit" \
    RTTHREAD_SRC="$wrong_rtthread" \
    "$fixture/run-native.sh" smoke --output "$tmp/output-wrong-source"
expect_failure "incomplete explicit RT-Thread source was accepted" env \
    PATH="$tools:$PATH" \
    NATIVE_RTTHREAD_COMMIT="$(git -C "$incomplete_rtthread" rev-parse HEAD)" \
    RTTHREAD_SRC="$incomplete_rtthread" \
    "$fixture/run-native.sh" smoke --output "$tmp/output-incomplete-source"

if rg -n '/home/|yfblock|tgoskits/tmp' "$SOURCE_RUNNER"; then
    fail "run-native.sh contains a workstation-specific path"
fi

echo "native task123 runner contract tests: PASS"
