#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
BIN="$TASK3_ROOT/build/tests/task3-linux-host"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

make -C "$SCRIPT_DIR" linux_cli

help=$($BIN --help)
for option in --video --truth --peer --port --frames --csv --drop-tx-seq \
    --duplicate-frame-once --malformed-once; do
    printf '%s\n' "$help" | grep -F -- "$option" >/dev/null
done
grep -F '\"success_rate\":' "$TASK3_ROOT/src/linux/main.c" >/dev/null

if "$BIN" --peer not-an-ip --video missing --truth missing --csv out.csv \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
    echo 'invalid IP unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'invalid peer IPv4 address' "$TMP_DIR/err" >/dev/null

if "$BIN" --peer 192.0.2.1 --video "$TMP_DIR/missing.y4m" \
    --truth "$TMP_DIR/missing.csv" --csv "$TMP_DIR/out.csv" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
    echo 'missing video unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'cannot open video' "$TMP_DIR/err" >/dev/null

python3 "$TASK3_ROOT/model/generate_video.py" --frames 2 --seed 3103 --fps 10 \
    --output "$TMP_DIR/two.y4m" --truth "$TMP_DIR/two.csv"
sed '$d' "$TMP_DIR/two.csv" >"$TMP_DIR/one.csv"
if "$BIN" --peer 192.0.2.1 --video "$TMP_DIR/two.y4m" \
    --truth "$TMP_DIR/one.csv" --frames 2 --csv "$TMP_DIR/out.csv" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
    echo 'mismatched truth unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'truth row count does not match frames' "$TMP_DIR/err" >/dev/null

python3 "$TASK3_ROOT/model/generate_video.py" --frames 3 --seed 3103 --fps 10 \
    --output "$TMP_DIR/three.y4m" --truth "$TMP_DIR/three.csv"
if timeout 2 "$BIN" --peer 127.0.0.1 --port 9 --video "$TMP_DIR/three.y4m" \
    --truth "$TMP_DIR/three.csv" --frames 2 --csv "$TMP_DIR/out.csv" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
    echo 'unreachable RT-IPC peer unexpectedly connected' >&2
    exit 1
fi
if grep -F 'truth row count does not match frames' "$TMP_DIR/err" >/dev/null; then
    echo 'truth reader rejected valid trailing rows' >&2
    exit 1
fi

for arguments in \
    "--frames 0" \
    "--frames 601" \
    "--port 0" \
    "--port 65536" \
    "--drop-tx-seq nope"; do
    # shellcheck disable=SC2086
    if "$BIN" $arguments --video "$TMP_DIR/two.y4m" \
        --truth "$TMP_DIR/two.csv" --csv "$TMP_DIR/out.csv" \
        >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
        echo "invalid arguments unexpectedly succeeded: $arguments" >&2
        exit 1
    fi
    grep -F 'invalid command line' "$TMP_DIR/err" >/dev/null
done

printf '%s\n' 'frame_id,target_q15,class' '0,0,2' 'bad,row' \
    >"$TMP_DIR/malformed.csv"
if "$BIN" --peer 192.0.2.1 --video "$TMP_DIR/two.y4m" \
    --truth "$TMP_DIR/malformed.csv" --frames 2 --csv "$TMP_DIR/out.csv" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
    echo 'malformed truth unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'invalid truth row' "$TMP_DIR/err" >/dev/null

printf '%s\n' 'test_linux_cli: PASS'
