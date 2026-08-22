#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ENTRYPOINT="$ROOT/run-task123.sh"

grep -Fq 'cargo xtask axvisor task123' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not delegate to cargo xtask" >&2
    exit 1
}
grep -Fq 'exec "$@"' "$ENTRYPOINT" || {
    echo "FAIL: direct task123 entrypoint does not preserve foreground signal handling" >&2
    exit 1
}

echo "PASS: direct task123 entrypoint delegates to cargo xtask axvisor task123"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ENTRYPOINT_ARGUMENTS"
EOF
chmod +x "$tmp/bin/cargo"

PATH="$tmp/bin:$PATH" ENTRYPOINT_ARGUMENTS="$tmp/no-arguments" "$ENTRYPOINT"
diff -u --label expected --label actual - <<'EOF' "$tmp/no-arguments"
xtask
axvisor
task123
--quick
--allow-qemu-timer-limit
EOF

PATH="$tmp/bin:$PATH" ENTRYPOINT_ARGUMENTS="$tmp/full-arguments" "$ENTRYPOINT" --full
diff -u --label expected --label actual - <<'EOF' "$tmp/full-arguments"
xtask
axvisor
task123
--full
--allow-qemu-timer-limit
EOF

PATH="$tmp/bin:$PATH" ENTRYPOINT_ARGUMENTS="$tmp/explicit-arguments" \
    "$ENTRYPOINT" --full --allow-qemu-timer-limit
diff -u --label expected --label actual - <<'EOF' "$tmp/explicit-arguments"
xtask
axvisor
task123
--full
--allow-qemu-timer-limit
EOF

echo "PASS: direct task123 entrypoint preserves task123 arguments"
