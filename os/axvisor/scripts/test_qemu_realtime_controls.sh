#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONTROL="$SCRIPT_DIR/apply_qemu_realtime_controls.sh"
RUNNER="$SCRIPT_DIR/run_rtipc_test.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/uclampset" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$QEMU_UCLAMP_TEST_OUTPUT"
EOF
chmod +x "$TMP_DIR/bin/uclampset"

output="$TMP_DIR/uclampset.args"
QEMU_UCLAMP_TEST_OUTPUT="$output" \
PATH="$TMP_DIR/bin:$PATH" \
    "$CONTROL" 4321 1024

if [ "$(cat "$output")" != "-m 1024 -a -p 4321" ]; then
    echo "QEMU realtime control did not apply uclamp.min to all QEMU threads" >&2
    exit 1
fi

for invalid in not-a-number -1 1025; do
    if QEMU_UCLAMP_TEST_OUTPUT="$output" PATH="$TMP_DIR/bin:$PATH" \
        "$CONTROL" 4321 "$invalid" >/dev/null 2>&1; then
        echo "QEMU realtime control accepted invalid uclamp.min: $invalid" >&2
        exit 1
    fi
done

rg -qF 'QEMU_UCLAMP_MIN="${QEMU_UCLAMP_MIN:-1024}"' "$RUNNER" || {
    echo "RT benchmark runner does not default QEMU uclamp.min to 1024" >&2
    exit 1
}
rg -qF '"$QEMU_REALTIME_CONTROL" "$qemu_pid" "$QEMU_UCLAMP_MIN"' "$RUNNER" || {
    echo "RT benchmark runner does not apply the QEMU realtime control" >&2
    exit 1
}
rg -qF 'printf '\''%s\n'\'' "$qemu_realtime_control_status"' "$RUNNER" || {
    echo "RT benchmark runner does not retain the applied realtime control status" >&2
    exit 1
}

echo "PASS: QEMU realtime runtime controls"
