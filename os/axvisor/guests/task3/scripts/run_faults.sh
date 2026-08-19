#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
frames=3
multicast_port_base=10120
suite_dir=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --frames) frames=$2; shift 2 ;;
        --multicast-port-base) multicast_port_base=$2; shift 2 ;;
        --suite-dir) suite_dir=$2; shift 2 ;;
        *)
            echo "usage: $0 [--frames N] [--multicast-port-base PORT] [--suite-dir DIR]" >&2
            exit 2
            ;;
    esac
done
case "$frames:$multicast_port_base" in
    *[!0-9:]*|0:*|*:0) echo 'invalid frames or multicast port base' >&2; exit 2 ;;
esac
[ "$frames" -le 600 ] || { echo 'frames must be <= 600' >&2; exit 2; }
[ $((multicast_port_base + 4)) -le 65535 ] || {
    echo 'multicast port range exceeds 65535' >&2
    exit 2
}

if [ -z "$suite_dir" ]; then
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    suite_dir="$TASK3_ROOT/build/fault-runs/$timestamp-$$"
fi
mkdir -p "$suite_dir"

case_index=0
for case_name in drop-control drop-status duplicate-frame delayed-server malformed; do
    case_dir="$suite_dir/$case_name"
    port=$((multicast_port_base + case_index))
    echo "fault_case=$case_name port=$port"
    "$SCRIPT_DIR/run_demo.sh" --frames "$frames" --multicast-port "$port" \
        --smoke --fault-case "$case_name" --run-dir "$case_dir"
    case_index=$((case_index + 1))
done

python3 "$SCRIPT_DIR/summarize_faults.py" --suite-dir "$suite_dir"
[ -s "$suite_dir/fault-summary.json" ] || {
    echo 'fault-summary.json was not generated' >&2
    exit 1
}
printf 'fault_suite_dir=%s\n' "$suite_dir"
