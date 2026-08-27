#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
README="$TASK3_ROOT/README.md"
PROTOCOL="$TASK3_ROOT/docs/protocol.md"
REPORT="$TASK3_ROOT/docs/results/task3-report.md"

for document in "$README" "$PROTOCOL" "$REPORT"; do
    test -s "$document" || { echo "missing document: $document" >&2; exit 1; }
    if grep -Ei 'TBD|PLACEHOLDER|待补充|伪造' "$document" >/dev/null; then
        echo "placeholder text in $document" >&2
        exit 1
    fi
done

for text in feat/task3-ai-control ddf52e2cdd977f14fc04035c88672ac204aec713 \
    3815d578c5759fa824322ea3d95ad51b55ab888e 14.2.Rel1 \
    'make doctor' 'make model' 'make test' 'make images' 'make demo' \
    'make fault-test' 'make report' 'git rev-parse HEAD' \
    '-smp 2' '-m 256M' '-smp 1' '-m 128M' virtio-net-device \
    52:54:00:77:00:11 52:54:00:77:00:30 192.168.77.11/24 \
    192.168.77.30/24 UDP/9877 '60 秒' 'FIXED' 'AI' \
    build/runs build/fault-runs 'CPU 负载' '自有 PID' '无 NAT' '防火墙'; do
    grep -F -- "$text" "$README" >/dev/null || {
        echo "README missing: $text" >&2
        exit 1
    }
done

for text in 'RT-IPC header' 'offset 0' 'offset 1' 'offset 2' 'offset 4' \
    'offset 8' 'offset 16' 'offset 18' session_id CTRL_CMD STATUS_REP ERROR_NOTIFY ACK SYN SYNACK \
    HEARTBEAT 'CRC16-CCITT' 'big-endian' '50 ms' '5 次' '500 ms' \
    '30 s' '1 s' '5 s' '乱序' '重复' '幂等' '不使用 vsock'; do
    grep -F -- "$text" "$PROTOCOL" >/dev/null || {
        echo "protocol document missing: $text" >&2
        exit 1
    }
done

for text in '每种模式 600 帧' '120.0 秒' 'fault-summary.json' \
    'drop-control' 'drop-status' 'duplicate-frame' 'delayed-server' malformed \
    'frames.csv' 'summary.json' 'linux.log' 'rtthread.log'; do
    grep -F -- "$text" "$REPORT" >/dev/null || {
        echo "report missing: $text" >&2
        exit 1
    }
done

for document in "$README" "$REPORT"; do
    for text in '双 QEMU 迁移基线' '不属于 AxVisor 最终证据' 'run_task123.sh'; do
        grep -F -- "$text" "$document" >/dev/null || {
            echo "migration evidence label missing from $document: $text" >&2
            exit 1
        }
    done
done

normal_source=$(sed -n 's/^本报告由 \([^ ]*\) 中的原始数据生成.*/\1/p' "$REPORT")
fault_source=$(sed -n 's/^故障证据来自 \([^ ]*\) .*/\1/p' "$REPORT")
case "$normal_source" in
    /*) ;;
    *) normal_source="$TASK3_ROOT/$normal_source" ;;
esac
case "$fault_source" in
    /*) ;;
    *) fault_source="$TASK3_ROOT/$fault_source" ;;
esac
test -d "$normal_source" || { echo 'report normal source does not exist' >&2; exit 1; }
test -f "$fault_source" || { echo 'report fault source does not exist' >&2; exit 1; }

echo 'test_docs_contract: PASS'
