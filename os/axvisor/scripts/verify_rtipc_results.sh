#!/bin/bash

set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    echo "usage: $0 LOG EXPECTED_COUNT QEMU_EXIT_CODE [FAULT_PROFILE] [APP_GUEST]" >&2
    exit 2
fi

log=$1
expected_count=$2
qemu_rc=$3
fault_profile=${4:-none}
app_guest=${5:-linux}

case "$fault_profile" in
    none|reliability) ;;
    *)
        echo "invalid RT-IPC fault profile: $fault_profile" >&2
        exit 2
        ;;
esac

case "$app_guest" in
    linux)
        app_smp_marker='LINUX_SMP_READY configured=2 online=0-1 nproc=2'
        ;;
    starryos)
        app_smp_marker='STARRY_SMP_READY configured=2 online=0-1 nproc=2'
        ;;
    *)
        echo "invalid application guest: $app_guest" >&2
        exit 2
        ;;
esac

case "$expected_count" in
    ''|*[!0-9]*|0)
        echo "invalid expected request count: $expected_count" >&2
        exit 2
        ;;
esac

case "$qemu_rc" in
    ''|*[!0-9]*)
        echo "invalid QEMU exit code: $qemu_rc" >&2
        exit 2
        ;;
esac
if [ "${#qemu_rc}" -gt 3 ] || [ "$qemu_rc" -gt 255 ]; then
    echo "invalid QEMU exit code: $qemu_rc" >&2
    exit 2
fi

if [ ! -f "$log" ]; then
    echo "RT-IPC result log does not exist: $log" >&2
    exit 1
fi

if [ "$qemu_rc" -ne 0 ]; then
    echo "QEMU failed with exit code $qemu_rc" >&2
    exit 1
fi

if grep -Eiq \
    'panicked at|kernel panic|assertion failed|RT-Thread.*assert|TESTS FAILED|RT-IPC client exited with rc=(-[0-9]+|[1-9][0-9]*)' \
    "$log"; then
    echo "panic or assertion failure found in RT-IPC log" >&2
    exit 1
fi

app_smp_count=$(grep -aFo -- "$app_smp_marker" "$log" | wc -l)
if [ "$app_smp_count" -ne 1 ]; then
    echo "$app_guest 2-vCPU online marker is missing, duplicated, or invalid" >&2
    exit 1
fi

if [ "$(grep -c 'RT-IPC client exited with rc=0[[:space:]]*$' "$log")" -ne 1 ]; then
    echo "RT-IPC client success status is missing or duplicated" >&2
    exit 1
fi

if [ "$(grep -c 'ALL TESTS COMPLETE[[:space:]]*$' "$log")" -ne 1 ]; then
    echo "RT-IPC completion marker is missing or duplicated" >&2
    exit 1
fi

if [ "$fault_profile" = reliability ]; then
    fault_request=$((expected_count / 2))
    if [ "$(grep -Ec "\[client\] fault injection: force disconnect at request=${fault_request}[[:space:]]*$" "$log")" -ne 1 ]; then
        echo "missing or duplicate forced-disconnect marker at request $fault_request" >&2
        exit 1
    fi
    if [ "$(grep -Ec '\[client\] reconnect complete recovery_ms=[1-9][0-9]* attempts=1[[:space:]]*$' "$log")" -ne 1 ]; then
        echo "missing, duplicate, or invalid reconnect-completion marker" >&2
        exit 1
    fi
else
    if grep -Eq '\[client\] (fault injection: force disconnect|reconnect complete)' "$log"; then
        echo "unexpected fault-injection or reconnect marker for fault profile none" >&2
        exit 1
    fi
fi

for payload_size in 64 256 1024; do
    section=$(awk -v marker="--- Payload ${payload_size}B ---" '
        index($0, marker) { waiting = 1; next }
        waiting && $0 ~ /--- Payload [0-9]+B ---/ { exit }
        waiting && $0 ~ /ALL TESTS COMPLETE/ { exit }
        waiting { print }
    ' "$log")

    # Serial output from multiple guests may splice the final summary onto a
    # progress line. Keep the last sent/recv record in the payload section;
    # the final record is the authenticated per-payload result.
    summary=$(printf '%s\n' "$section" | awk '
        $0 ~ /sent=[0-9]+[[:space:]]+recv=[0-9]+/ { last = $0 }
        END { print last }
    ')

    if [ -z "$summary" ]; then
        echo "missing result for ${payload_size}B payload" >&2
        exit 1
    fi

    counts=$(printf '%s\n' "$summary" |
        sed -E 's/.*sent=([0-9]+)[[:space:]]+recv=([0-9]+).*/\1 \2/')
    set -- $counts
    sent=$1
    received=$2

    if [ "$sent" -ne "$expected_count" ] || [ "$received" -ne "$expected_count" ]; then
        echo "${payload_size}B incomplete: expected=$expected_count sent=$sent recv=$received" >&2
        exit 1
    fi

    reconnects=0
    if [ "$fault_profile" = reliability ] && [ "$payload_size" -eq 64 ]; then
        reconnects=1
    fi
    if ! printf '%s\n' "$section" | grep -Eq \
        "request_timeouts=0 protocol_errors=0 reconnects=${reconnects}[[:space:]]*$"; then
        echo "${payload_size}B application reliability counters are invalid" >&2
        exit 1
    fi
    transport=$(printf '%s\n' "$section" | awk '
        /transport: retrans=[0-9]+/ { print; exit }
    ')
    if ! printf '%s\n' "$transport" | grep -Eq \
        'transport: retrans=[0-9]+ timeouts=0 dup=[0-9]+ reorder=[0-9]+ errors=0[[:space:]]*$'; then
        echo "${payload_size}B transport reliability counters are invalid" >&2
        exit 1
    fi

    if [ "$fault_profile" = reliability ]; then
        case "$payload_size" in
            64)
                marker='fault injection: drop tx payload=64 seq=[0-9]+'
                counter='transport: retrans=[1-9][0-9]* timeouts=0'
                ;;
            256)
                marker='fault injection: duplicate rx payload=256 seq=[0-9]+'
                counter='dup=[1-9][0-9]* reorder=[0-9]+ errors=0'
                ;;
            1024)
                marker='fault injection: reorder rx payload=1024 first_seq=[0-9]+ second_seq=[0-9]+'
                counter='reorder=[1-9][0-9]* errors=0'
                ;;
        esac
        if [ "$(printf '%s\n' "$section" | grep -Ec "$marker")" -ne 1 ]; then
            echo "${payload_size}B fault injection marker is missing or duplicated" >&2
            exit 1
        fi
        if ! printf '%s\n' "$transport" | grep -Eq "$counter"; then
            echo "${payload_size}B expected fault counter did not increase" >&2
            exit 1
        fi
    fi
done

if [ "$fault_profile" = reliability ]; then
    if [ "$(grep -Ec '\[client\] fault profile: reliability[[:space:]]*$' "$log")" -ne 1 ]; then
        echo "reliability fault profile start marker is missing or duplicated" >&2
        exit 1
    fi
    if [ "$(grep -Ec '\[client\] fault profile complete: drop=1 duplicate=1 reorder=1[[:space:]]*$' "$log")" -ne 1 ]; then
        echo "reliability fault profile completion marker is missing or duplicated" >&2
        exit 1
    fi
fi

echo "PASS: all RT-IPC payload tests completed ($expected_count requests each)"
