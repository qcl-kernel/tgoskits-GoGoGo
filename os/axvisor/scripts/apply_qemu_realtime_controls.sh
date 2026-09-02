#!/bin/bash

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 QEMU_PID UCLAMP_MIN" >&2
    exit 2
fi

qemu_pid=$1
uclamp_min=$2
qemu_cpu_affinity=${QEMU_CPU_AFFINITY:-}
qemu_vcpu_affinity=${QEMU_VCPU_AFFINITY:-}
vcpu_affinity_wait_s=${QEMU_VCPU_AFFINITY_WAIT_S:-30}
qemu_sched_policy=${QEMU_SCHED_POLICY:-}
qemu_sched_priority=${QEMU_SCHED_PRIORITY:-0}

case "$qemu_pid" in
    ''|*[!0-9]*|0)
        echo "invalid QEMU PID: $qemu_pid" >&2
        exit 2
        ;;
esac
case "$uclamp_min" in
    ''|*[!0-9]*)
        echo "QEMU uclamp.min must be an integer from 0 to 1024" >&2
        exit 2
        ;;
esac
if [ "$uclamp_min" -gt 1024 ]; then
    echo "QEMU uclamp.min must be an integer from 0 to 1024" >&2
    exit 2
fi
case "$qemu_cpu_affinity" in
    '') ;;
    *[!0-9,-]*)
        echo "QEMU_CPU_AFFINITY must be a taskset CPU list" >&2
        exit 2
        ;;
esac
case "$qemu_vcpu_affinity" in
    '') ;;
    *[!0-9=,]*)
        echo "QEMU_VCPU_AFFINITY must be a comma-separated guest=host CPU map" >&2
        exit 2
        ;;
esac
case "$vcpu_affinity_wait_s" in
    ''|*[!0-9]*)
        echo "QEMU_VCPU_AFFINITY_WAIT_S must be a positive integer" >&2
        exit 2
        ;;
esac
[ "$vcpu_affinity_wait_s" -ge 1 ] || {
    echo "QEMU_VCPU_AFFINITY_WAIT_S must be a positive integer" >&2
    exit 2
}
case "$qemu_sched_policy" in
    ''|other|batch|idle|rr|fifo) ;;
    *)
        echo "QEMU_SCHED_POLICY must be empty, other, batch, idle, rr, or fifo" >&2
        exit 2
        ;;
esac
case "$qemu_sched_priority" in
    ''|*[!0-9]*)
        echo "QEMU_SCHED_PRIORITY must be an integer from 0 to 99" >&2
        exit 2
        ;;
esac
if [ "$qemu_sched_priority" -gt 99 ]; then
    echo "QEMU_SCHED_PRIORITY must be an integer from 0 to 99" >&2
    exit 2
fi
case "$qemu_sched_policy" in
    ''|other|batch|idle)
        [ "$qemu_sched_priority" -eq 0 ] || {
            echo "QEMU_SCHED_PRIORITY must be 0 for $qemu_sched_policy" >&2
            exit 2
        }
        ;;
    rr|fifo)
        [ "$qemu_sched_priority" -ge 1 ] || {
            echo "QEMU_SCHED_PRIORITY must be between 1 and 99 for $qemu_sched_policy" >&2
            exit 2
        }
        ;;
esac
if ! command -v uclampset >/dev/null 2>&1; then
    echo "QEMU realtime runs require uclampset" >&2
    exit 1
fi

uclampset -m "$uclamp_min" -a -p "$qemu_pid"
if [ -n "$qemu_cpu_affinity" ]; then
    command -v taskset >/dev/null 2>&1 || {
        echo "QEMU_CPU_AFFINITY requires taskset" >&2
        exit 1
    }
    taskset -apc "$qemu_cpu_affinity" "$qemu_pid"
    echo "QEMU CPU affinity applied: pid=$qemu_pid cpus=$qemu_cpu_affinity"
fi
if [ -n "$qemu_vcpu_affinity" ]; then
    command -v taskset >/dev/null 2>&1 || {
        echo "QEMU_VCPU_AFFINITY requires taskset" >&2
        exit 1
    }
    IFS=',' read -r -a vcpu_bindings <<EOF
$qemu_vcpu_affinity
EOF
    for binding in "${vcpu_bindings[@]}"; do
        guest_cpu=${binding%%=*}
        host_cpu=${binding#*=}
        [ "$binding" != "$guest_cpu" ] || {
            echo "QEMU_VCPU_AFFINITY entry must be guest=host: $binding" >&2
            exit 2
        }
        [ -n "$guest_cpu" ] && [ -n "$host_cpu" ] || {
            echo "QEMU_VCPU_AFFINITY entry must be guest=host: $binding" >&2
            exit 2
        }
        vcpu_tid=
        vcpu_deadline=$(( $(date +%s) + vcpu_affinity_wait_s ))
        while :; do
            for tid_path in /proc/"$qemu_pid"/task/*/comm; do
                [ -r "$tid_path" ] || continue
                thread_name=$(<"$tid_path")
                case "$thread_name" in
                    "CPU $guest_cpu/TCG"|"CPU $guest_cpu/KVM")
                        vcpu_tid=${tid_path%/comm}
                        vcpu_tid=${vcpu_tid##*/}
                        break 2
                        ;;
                    esac
            done
            [ -n "$vcpu_tid" ] && break
            [ "$(date +%s)" -lt "$vcpu_deadline" ] || break
            sleep 0.01
        done
        [ -n "$vcpu_tid" ] || {
            echo "QEMU vCPU thread not found: guest=$guest_cpu pid=$qemu_pid" >&2
            exit 1
        }
        taskset -pc "$host_cpu" "$vcpu_tid"
        echo "QEMU vCPU affinity applied: guest=$guest_cpu tid=$vcpu_tid host_cpu=$host_cpu"
    done
fi
if [ -n "$qemu_sched_policy" ]; then
    command -v chrt >/dev/null 2>&1 || {
        echo "QEMU_SCHED_POLICY requires chrt" >&2
        exit 1
    }
    case "$qemu_sched_policy" in
        other) chrt -o -p 0 -a "$qemu_pid" ;;
        batch) chrt -b -p 0 -a "$qemu_pid" ;;
        idle) chrt -i -p 0 -a "$qemu_pid" ;;
        rr) chrt -r -p "$qemu_sched_priority" -a "$qemu_pid" ;;
        fifo) chrt -f -p "$qemu_sched_priority" -a "$qemu_pid" ;;
    esac
    echo "QEMU scheduling applied: pid=$qemu_pid policy=$qemu_sched_policy priority=$qemu_sched_priority"
fi
echo "QEMU realtime control applied: pid=$qemu_pid uclamp.min=$uclamp_min"
