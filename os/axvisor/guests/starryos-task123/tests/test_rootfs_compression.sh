#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)"
BUILDER="$ROOT/os/axvisor/guests/starryos-task123/build_rootfs.sh"
TEST_ROOT="$(mktemp -d "$ROOT/tmp/starryos-rootfs-compression-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/source" "$TEST_ROOT/fake-bin"
printf 'busybox\n' > "$TEST_ROOT/source/bin.busybox"
printf 'rtipc\n' > "$TEST_ROOT/source/bin.rtipic-client"
printf 'task3\n' > "$TEST_ROOT/source/usr.bin.task3-linux"
printf 'video\n' > "$TEST_ROOT/source/line-follow.y4m"
printf 'truth\n' > "$TEST_ROOT/source/truth.csv"
mkdir -p "$TEST_ROOT/archive/bin" "$TEST_ROOT/archive/usr/bin" "$TEST_ROOT/archive/opt/task3"
cp -- "$TEST_ROOT/source/bin.busybox" "$TEST_ROOT/archive/bin/busybox"
cp -- "$TEST_ROOT/source/bin.rtipic-client" "$TEST_ROOT/archive/bin/rtipic-client"
cp -- "$TEST_ROOT/source/usr.bin.task3-linux" "$TEST_ROOT/archive/usr/bin/task3-linux"
cp -- "$TEST_ROOT/source/line-follow.y4m" "$TEST_ROOT/archive/opt/task3/line-follow.y4m"
cp -- "$TEST_ROOT/source/truth.csv" "$TEST_ROOT/archive/opt/task3/truth.csv"

cat > "$TEST_ROOT/fake-bin/readelf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-h" ]]; then
    printf '  Machine:                           AArch64\n'
fi
EOF
chmod +x "$TEST_ROOT/fake-bin/readelf"

(cd "$TEST_ROOT/archive" && find . -print0 | cpio --null --create --format=newc --quiet > "$TEST_ROOT/raw.cpio")
gzip -n -c "$TEST_ROOT/raw.cpio" > "$TEST_ROOT/compressed.cpio.gz"

for input in "$TEST_ROOT/raw.cpio" "$TEST_ROOT/compressed.cpio.gz"; do
    output="$TEST_ROOT/$(basename "$input").output.cpio"
    PATH="$TEST_ROOT/fake-bin:$PATH" "$BUILDER" --source-cpio "$input" --output "$output" >/dev/null
    cpio -it --quiet < "$output" | grep -Fxq 'bin/rtipic-client'
done

printf 'starryos rootfs compression compatibility: PASS\n'
