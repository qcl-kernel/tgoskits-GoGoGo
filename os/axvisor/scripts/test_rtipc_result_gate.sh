#!/bin/bash

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
VERIFY="$SCRIPT_DIR/verify_rtipc_results.sh"
RUNNER="$SCRIPT_DIR/run_rtipc_test.sh"
RUN_UNTIL="$SCRIPT_DIR/run_until_log_marker.sh"
CLIENT="$SCRIPT_DIR/../guests/rt-ipc/linux/rtipc_client.c"
INIT_LINUX="$ROOT/os/axvisor/guests/linux-net/init-linux-1"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_complete_log() {
    log=$1
    count=$2
    cat >"$log" <<EOF
[VM 1] LINUX_SMP_READY configured=2 online=0-1 nproc=2
[VM 1] --- Payload 64B ---
[VM 1] [progress] size=64 idx=49 sent=50 recv=49 state=3
[VM 1]   sent=$count  recv=$count  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 256B ---
[VM 1] [progress] size=256 idx=49 sent=50 recv=49 state=3
[VM 1]   sent=$count  recv=$count  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] --- Payload 1024B ---
[VM 1] [progress] size=1024 idx=49 sent=50 recv=49 state=3
[VM 1]   sent=$count  recv=$count  loss=0%
[VM 1]   request_timeouts=0 protocol_errors=0 reconnects=0
[VM 1]   transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0
[VM 1] ALL TESTS COMPLETE
[VM 1] RT-IPC client exited with rc=0
EOF
}

expect_pass() {
    name=$1
    shift
    if ! "$@" >"$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should pass"
        cat "$TMP_DIR/$name.out"
        exit 1
    fi
}

expect_fail() {
    name=$1
    shift
    if "$@" >"$TMP_DIR/$name.out" 2>&1; then
        echo "FAIL: $name should fail"
        cat "$TMP_DIR/$name.out"
        exit 1
    fi
}

complete="$TMP_DIR/complete.log"
write_complete_log "$complete" 100
expect_pass complete "$VERIFY" "$complete" 100 0
expect_fail qemu_timeout "$VERIFY" "$complete" 100 124

interleaved_linux_smp="$TMP_DIR/interleaved-linux-smp.log"
cp "$complete" "$interleaved_linux_smp"
sed -i 's/nproc=2$/nproc=2[    0.743142] TCP: Hash tables configured/' \
    "$interleaved_linux_smp"
expect_pass interleaved_linux_smp \
    "$VERIFY" "$interleaved_linux_smp" 100 0

missing_linux_smp="$TMP_DIR/missing-linux-smp.log"
cp "$complete" "$missing_linux_smp"
sed -i '/LINUX_SMP_READY/d' "$missing_linux_smp"
expect_fail missing_linux_smp "$VERIFY" "$missing_linux_smp" 100 0

wrong_linux_smp="$TMP_DIR/wrong-linux-smp.log"
cp "$complete" "$wrong_linux_smp"
sed -i 's/online=0-1 nproc=2/online=0 nproc=1/' "$wrong_linux_smp"
expect_fail wrong_linux_smp "$VERIFY" "$wrong_linux_smp" 100 0

duplicate_linux_smp="$TMP_DIR/duplicate-linux-smp.log"
cp "$complete" "$duplicate_linux_smp"
sed -n '/LINUX_SMP_READY/p' "$complete" >> "$duplicate_linux_smp"
expect_fail duplicate_linux_smp "$VERIFY" "$duplicate_linux_smp" 100 0

crlf="$TMP_DIR/complete-crlf.log"
sed 's/$/\r/' "$complete" > "$crlf"
expect_pass complete_crlf "$VERIFY" "$crlf" 100 0

recovered_transport="$TMP_DIR/recovered-transport.log"
write_complete_log "$recovered_transport" 100
sed -i '0,/transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0/{
    s//transport: retrans=3 timeouts=0 dup=2 reorder=1 errors=0/
}' "$recovered_transport"
expect_pass recovered_transport_anomalies \
    "$VERIFY" "$recovered_transport" 100 0

write_reliability_log() {
    log=$1
    count=$2
    write_complete_log "$log" "$count"
    sed -i '1a [VM 1] [client] fault profile: reliability' "$log"
    sed -i '/Payload 64B/a [VM 1] [client] fault injection: force disconnect at request=50\n[VM 1] [client] reconnect complete recovery_ms=200 attempts=1\n[VM 1] [client] fault injection: drop tx payload=64 seq=0' "$log"
    sed -i '0,/reconnects=0/s//reconnects=1/; 0,/transport: retrans=0/s//transport: retrans=1/' "$log"
    sed -i '/Payload 256B/a [VM 1] [client] fault injection: duplicate rx payload=256 seq=0' "$log"
    sed -i '0,/transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0/s//transport: retrans=0 timeouts=0 dup=1 reorder=0 errors=0/' "$log"
    sed -i '/Payload 1024B/a [VM 1] [client] fault injection: reorder rx payload=1024 first_seq=0 second_seq=1' "$log"
    sed -i '0,/transport: retrans=0 timeouts=0 dup=0 reorder=0 errors=0/s//transport: retrans=0 timeouts=0 dup=0 reorder=1 errors=0/' "$log"
    sed -i '/ALL TESTS COMPLETE/i [VM 1] [client] fault profile complete: drop=1 duplicate=1 reorder=1' "$log"
}

reliability="$TMP_DIR/reliability.log"
write_reliability_log "$reliability" 100
expect_pass reliability_profile \
    "$VERIFY" "$reliability" 100 0 reliability

missing_drop="$TMP_DIR/missing-drop.log"
cp "$reliability" "$missing_drop"
sed -i '/fault injection: drop tx/d' "$missing_drop"
expect_fail reliability_missing_drop \
    "$VERIFY" "$missing_drop" 100 0 reliability

zero_duplicate="$TMP_DIR/zero-duplicate.log"
cp "$reliability" "$zero_duplicate"
sed -i 's/dup=1 reorder=0/dup=0 reorder=0/' "$zero_duplicate"
expect_fail reliability_zero_duplicate \
    "$VERIFY" "$zero_duplicate" 100 0 reliability

zero_reorder="$TMP_DIR/zero-reorder.log"
cp "$reliability" "$zero_reorder"
sed -i 's/dup=0 reorder=1/dup=0 reorder=0/' "$zero_reorder"
expect_fail reliability_zero_reorder \
    "$VERIFY" "$zero_reorder" 100 0 reliability

missing="$TMP_DIR/missing.log"
write_complete_log "$missing" 100
sed -i '/Payload 1024B/,+1d' "$missing"
expect_fail missing_payload "$VERIFY" "$missing" 100 0

incomplete="$TMP_DIR/incomplete.log"
write_complete_log "$incomplete" 100
sed -i 's/sent=100  recv=100  loss=0%/sent=100  recv=99  loss=1%/' "$incomplete"
expect_fail incomplete_payload "$VERIFY" "$incomplete" 100 0

no_recovery="$TMP_DIR/no-recovery.log"
write_reliability_log "$no_recovery" 100
sed -i '/fault injection:/d; /reconnect complete/d' "$no_recovery"
expect_fail missing_recovery "$VERIFY" "$no_recovery" 100 0 reliability

bad_recovery_count="$TMP_DIR/bad-recovery-count.log"
write_reliability_log "$bad_recovery_count" 100
sed -i '0,/reconnects=1/s//reconnects=0/' "$bad_recovery_count"
expect_fail missing_reconnect_count "$VERIFY" "$bad_recovery_count" 100 0 reliability

client_failed="$TMP_DIR/client-failed.log"
write_complete_log "$client_failed" 100
sed -i 's/client exited with rc=0/client exited with rc=1/' "$client_failed"
expect_fail client_failure "$VERIFY" "$client_failed" 100 0 reliability

conflicting_client_status="$TMP_DIR/conflicting-client-status.log"
write_complete_log "$conflicting_client_status" 100
printf '%s\n' '[VM 1] RT-IPC client exited with rc=9' >> "$conflicting_client_status"
expect_fail conflicting_client_status \
    "$VERIFY" "$conflicting_client_status" 100 0 reliability

conflicting_test_status="$TMP_DIR/conflicting-test-status.log"
write_complete_log "$conflicting_test_status" 100
printf '%s\n' '[VM 1] TESTS FAILED' >> "$conflicting_test_status"
expect_fail conflicting_test_status \
    "$VERIFY" "$conflicting_test_status" 100 0 reliability

panic_log="$TMP_DIR/panic.log"
write_complete_log "$panic_log" 100
printf '%s\n' 'panicked at virtualization/axvm/src/runtime/vcpus.rs' >>"$panic_log"
expect_fail panic "$VERIFY" "$panic_log" 100 0 reliability

expect_fail qemu_failure "$VERIFY" "$complete" 100 1 reliability
for invalid_qemu_rc in '' abc 999999999999999999999; do
    set +e
    "$VERIFY" "$complete" 100 "$invalid_qemu_rc" reliability \
        >"$TMP_DIR/invalid-qemu-rc.out" 2>&1
    invalid_status=$?
    set -e
    if [ "$invalid_status" -ne 2 ]; then
        echo "FAIL: invalid QEMU exit code '$invalid_qemu_rc' returned $invalid_status instead of 2"
        exit 1
    fi
    set +e
    "$VERIFY" "$TMP_DIR/missing-invalid.log" 100 "$invalid_qemu_rc" reliability \
        >"$TMP_DIR/missing-invalid-qemu-rc.out" 2>&1
    missing_invalid_status=$?
    set -e
    if [ "$missing_invalid_status" -ne 2 ]; then
        echo "FAIL: missing log with invalid QEMU exit code '$invalid_qemu_rc' returned $missing_invalid_status instead of 2"
        exit 1
    fi
done

extract_linux_success_path() {
    source_file=$1
    awk '
        BEGIN {
            failure_blocks = 0
            failure_depth = 0
            parse_failed = 0
        }
        function parse_error(message) {
            print "Linux guest init structure error: " message > "/dev/stderr"
            parse_failed = 1
            exit 2
        }
        {
            line = $0
            if (failure_depth == 0 &&
                line ~ /^[[:space:]]*if[[:space:]]+\[[[:space:]]*"\$ping_ok"[[:space:]]+-ne[[:space:]]+1[[:space:]]*\][[:space:]]*;[[:space:]]*then[[:space:]]*(#.*)?$/) {
                failure_blocks++
                if (failure_blocks != 1) {
                    parse_error("duplicate ping-failure diagnostic block")
                }
                failure_depth = 1
                next
            }
            if (failure_depth > 0) {
                if (line ~ /^[[:space:]]*if([[:space:]]|$)/ &&
                    line ~ /;[[:space:]]*then[[:space:]]*(#.*)?$/) {
                    failure_depth++
                }
                if (line ~ /^[[:space:]]*fi([[:space:];]|$)/) {
                    failure_depth--
                }
                next
            }
            if (line !~ /^[[:space:]]*(#|$)/) {
                print line
            }
        }
        END {
            if (parse_failed) {
                exit 2
            }
            if (failure_blocks != 1) {
                parse_error("expected exactly one ping-failure diagnostic block")
            }
            if (failure_depth != 0) {
                parse_error("unterminated ping-failure diagnostic block")
            }
        }
    ' "$source_file"
}

check_linux_success_dump_contract() {
    source_file=$1
    success_source="$TMP_DIR/linux-success-source"
    if ! extract_linux_success_path "$source_file" >"$success_source"; then
        echo "Linux guest init success path could not be isolated" >&2
        return 1
    fi

    forbidden_dump_ere='(/proc/net/(snmp|udp))|(^|[;&|()[:space:]])([^;&|()[:space:]]*/)?ifconfig([;&|()[:space:]>]|$)'
    if forbidden_lines=$(grep -En -- "$forbidden_dump_ere" "$success_source"); then
        echo "Linux guest init success path contains forbidden network dump:" >&2
        echo "$forbidden_lines" >&2
        return 1
    else
        grep_rc=$?
        if [ "$grep_rc" -ne 1 ]; then
            echo "could not scan Linux guest init success path" >&2
            return 1
        fi
    fi
}

failure_diagnostic_fixture="$TMP_DIR/linux-failure-diagnostics.sh"
cat >"$failure_diagnostic_fixture" <<'EOF'
#!/bin/busybox sh
if   [  "$ping_ok"   -ne   1  ] ;  then
  /bin/busybox ifconfig eth0 > /dev/console 2>&1
  /bin/busybox ip neigh > /dev/console 2>&1 || true
fi
EOF
expect_pass linux_failure_branch_diagnostics \
    check_linux_success_dump_contract "$failure_diagnostic_fixture"

unrecognized_failure_fixture="$TMP_DIR/linux-unrecognized-failure-block.sh"
cat >"$unrecognized_failure_fixture" <<'EOF'
#!/bin/busybox sh
if [ "$ping_ok" = 0 ]; then
  /bin/busybox ifconfig eth0 > /dev/console 2>&1
fi
EOF
expect_fail linux_unrecognized_failure_block \
    check_linux_success_dump_contract "$unrecognized_failure_fixture"

success_path_snmp="$TMP_DIR/linux-success-path-snmp.sh"
cp "$failure_diagnostic_fixture" "$success_path_snmp"
printf '%s\n' '/bin/busybox cat     /proc/net/snmp > /dev/console' >>"$success_path_snmp"
expect_fail linux_success_path_snmp \
    check_linux_success_dump_contract "$success_path_snmp"

success_path_udp="$TMP_DIR/linux-success-path-udp.sh"
cp "$failure_diagnostic_fixture" "$success_path_udp"
printf '%s\n' '/bin/busybox cat /proc/net/udp     > /dev/console' >>"$success_path_udp"
expect_fail linux_success_path_udp \
    check_linux_success_dump_contract "$success_path_udp"

success_path_ifconfig="$TMP_DIR/linux-success-path-ifconfig.sh"
cp "$failure_diagnostic_fixture" "$success_path_ifconfig"
printf '%s\n' '/bin/busybox ifconfig     eth0 > /dev/console 2>&1' >>"$success_path_ifconfig"
expect_fail linux_success_path_ifconfig \
    check_linux_success_dump_contract "$success_path_ifconfig"

success_path_bare_ifconfig="$TMP_DIR/linux-success-path-bare-ifconfig.sh"
cp "$failure_diagnostic_fixture" "$success_path_bare_ifconfig"
printf '%s\n' '/bin/busybox ifconfig > /dev/console 2>&1' >>"$success_path_bare_ifconfig"
expect_fail linux_success_path_bare_ifconfig \
    check_linux_success_dump_contract "$success_path_bare_ifconfig"

if ! check_linux_success_dump_contract "$INIT_LINUX"; then
    fail "Linux guest init violates the success-path debug dump contract"
fi

if grep -Eq '(^|[[:space:]])pkill([[:space:]]|$)' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must not terminate unrelated QEMU processes"
    exit 1
fi
if ! grep -Fq 'ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must derive the repository root from its location"
    exit 1
fi
if ! grep -Fq 'grep -aE' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must treat serial logs containing NUL as text"
    exit 1
fi
if grep -Eq '(^|[[:space:]])-nographic([[:space:]]|$)' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must not multiplex the guest serial with an EOF-prone stdio monitor"
    exit 1
fi
if ! grep -Fq -- '-display none' "$RUNNER" ||
   ! grep -Fq -- '-monitor none' "$RUNNER" ||
   ! grep -Fq -- '-serial "file:$LOG"' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must capture guest serial through a file chardev"
    exit 1
fi
if ! grep -Fq -- '-snapshot' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must not take an exclusive writable lock on the shared rootfs"
    exit 1
fi
if ! grep -Fq 'run_until_log_marker.sh' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must stop its own QEMU after the final client marker" >&2
    exit 1
fi
if ! grep -Fq 'RT-IPC client exited with rc=0' "$RUNNER"; then
    echo "FAIL: RT-IPC runner must wait for the final client status, not an early marker" >&2
    exit 1
fi
for token in RTBENCH_STABILITY_SECONDS RTBENCH_START_MODE \
    'unix:$serial_socket,server=on,wait=on' 'socat - "UNIX-CONNECT:$serial_socket"' \
    RTBENCH_STABILITY_DONE verify_rtbench_stability.sh \
    CPU_LOAD_LOG RUN_UNTIL_CHILD_PID_FILE 'pidstat -h -t -p'; do
    if ! grep -Fq -- "$token" "$RUNNER"; then
        echo "FAIL: RT-IPC runner is missing RT benchmark integration token: $token" >&2
        exit 1
    fi
done
for token in RTBENCH_SUITE_SAMPLES RTBENCH_MODE RTBENCH_DONE_MARKER \
    'benchmark $RTBENCH_SUITE_SAMPLES' 'RTBENCH_END status=' \
    verify_rtbench_suite.sh; do
    if ! grep -Fq -- "$token" "$RUNNER"; then
        echo "FAIL: RT-IPC runner is missing benchmark-suite token: $token" >&2
        exit 1
    fi
done
if ! grep -Fq \
    '[ -n "$RTBENCH_STABILITY_SECONDS" ] && [ -n "$RTBENCH_SUITE_SAMPLES" ]' \
    "$RUNNER"; then
    echo "FAIL: runner must reject simultaneous stability and suite benchmarks" >&2
    exit 1
fi
for token in RTIPC_FAULT_PROFILE '--fault-profile $RTIPC_FAULT_PROFILE' \
    'verify_rtipc_results.sh "$LOG" "$RTIPC_COUNT" "$qemu_rc" "$RTIPC_FAULT_PROFILE"'; do
    if ! grep -Fq -- "$token" "$RUNNER"; then
        echo "FAIL: RT-IPC runner is missing fault-profile integration token: $token" >&2
        exit 1
    fi
done
if ! grep -Fq \
    'completion_markers+=("$RTBENCH_DONE_MARKER")' \
    "$RUNNER"; then
    echo "FAIL: RT benchmark completion marker must use the selected mode marker" >&2
    exit 1
fi
if ! grep -Fq \
    'while ! grep -aFq -- "$RTBENCH_DONE_MARKER" "$LOG"; do' \
    "$RUNNER"; then
    echo "FAIL: RT benchmark feeder must wait for the selected done marker before leaving VM 3" >&2
    exit 1
fi
if ! grep -Fq "printf '\\030['" "$RUNNER"; then
    echo "FAIL: RT benchmark feeder must return the console to VM 1 after completion" >&2
    exit 1
fi
if [ ! -x "$RUN_UNTIL" ]; then
    echo "FAIL: run-until-log-marker helper must be executable" >&2
    exit 1
fi
if grep -Fq 'result->received % 100' "$CLIENT"; then
    echo "FAIL: long RT-IPC runs must not flood the bounded console log by request count" >&2
    exit 1
fi
if ! grep -Fq 'progress_now - last_progress >= 5000' "$CLIENT"; then
    echo "FAIL: long RT-IPC runs must retain bounded time-based progress output" >&2
    exit 1
fi

echo "PASS: RT-IPC result gate"
