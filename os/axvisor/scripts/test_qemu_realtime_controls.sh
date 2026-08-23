#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONTROL="$SCRIPT_DIR/apply_qemu_realtime_controls.sh"
RUNNER="$SCRIPT_DIR/run_rtipc_test.sh"
TASK123_RUNNER="$SCRIPT_DIR/run_task123.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/uclampset" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$QEMU_UCLAMP_TEST_OUTPUT"
EOF
chmod +x "$TMP_DIR/bin/uclampset"

cat > "$TMP_DIR/bin/taskset" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$QEMU_CPU_AFFINITY_TEST_OUTPUT"
EOF
chmod +x "$TMP_DIR/bin/taskset"

cat > "$TMP_DIR/bin/chrt" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$QEMU_SCHEDULING_TEST_OUTPUT"
EOF
chmod +x "$TMP_DIR/bin/chrt"

output="$TMP_DIR/uclampset.args"
QEMU_UCLAMP_TEST_OUTPUT="$output" \
PATH="$TMP_DIR/bin:$PATH" \
    "$CONTROL" 4321 1024

if [ "$(cat "$output")" != "-m 1024 -a -p 4321" ]; then
    echo "QEMU realtime control did not apply uclamp.min to all QEMU threads" >&2
    exit 1
fi

affinity_output="$TMP_DIR/taskset.args"
scheduling_output="$TMP_DIR/chrt.args"
QEMU_UCLAMP_TEST_OUTPUT="$output" \
QEMU_CPU_AFFINITY_TEST_OUTPUT="$affinity_output" \
QEMU_SCHEDULING_TEST_OUTPUT="$scheduling_output" \
QEMU_CPU_AFFINITY=2-5 \
QEMU_SCHED_POLICY=other \
QEMU_SCHED_PRIORITY=0 \
PATH="$TMP_DIR/bin:$PATH" \
    "$CONTROL" 4321 1024

[ "$(cat "$affinity_output")" = "-apc 2-5 4321" ] || {
    echo "QEMU realtime control did not apply CPU affinity to all QEMU threads" >&2
    exit 1
}
[ "$(cat "$scheduling_output")" = "-o -p 0 -a 4321" ] || {
    echo "QEMU realtime control did not apply the requested scheduling policy" >&2
    exit 1
}

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
rg -qF 'QEMU_CPU_AFFINITY' "$CONTROL" || {
    echo "QEMU realtime control does not expose CPU affinity" >&2
    exit 1
}
rg -qF 'QEMU_VCPU_AFFINITY' "$CONTROL" || {
    echo "QEMU realtime control does not expose vCPU affinity" >&2
    exit 1
}
rg -qF 'vcpu_affinity_wait_s=${QEMU_VCPU_AFFINITY_WAIT_S:-30}' "$CONTROL" || {
    echo "QEMU realtime control does not allow vCPU threads to appear after guest boot" >&2
    exit 1
}
rg -qF 'QEMU_SCHED_POLICY' "$CONTROL" || {
    echo "QEMU realtime control does not expose scheduling policy" >&2
    exit 1
}
rg -qF 'QEMU_TCG_THREAD' "$RUNNER" || {
    echo "RT benchmark runner does not expose the TCG thread mode" >&2
    exit 1
}
rg -qF 'QEMU_ICOUNT="${QEMU_ICOUNT:-}"' "$TASK123_RUNNER" || {
    echo "Task123 runner must default to wall-clock QEMU timing" >&2
    exit 1
}
rg -qF 'if [[ -n "$QEMU_ICOUNT" ]]; then' "$TASK123_RUNNER" || {
    echo "Task123 runner must make icount opt-in" >&2
    exit 1
}
rg -qF 'qemu_tcg_thread="${QEMU_TCG_THREAD:-multi}"' "$TASK123_RUNNER" || {
    echo "Task123 runner must preserve multi-threaded TCG by default" >&2
    exit 1
}
rg -qF 'qemu_cpu_affinity=' "$TASK123_RUNNER" || {
    echo "Task123 manifest does not record QEMU CPU affinity" >&2
    exit 1
}
rg -qF 'qemu_vcpu_affinity=' "$TASK123_RUNNER" || {
    echo "Task123 manifest does not record QEMU vCPU affinity" >&2
    exit 1
}
! rg -qF 'debug-threads=on' "$TASK123_RUNNER" || {
    echo "Task123 runner still enables QEMU debug thread naming" >&2
    exit 1
}

echo "PASS: QEMU realtime runtime controls"
