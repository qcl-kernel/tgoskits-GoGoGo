#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK3_ROOT=${TASK3_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
export TASK3_ROOT
. "$SCRIPT_DIR/common.sh"

MODEL_DIR=${TASK3_MODEL_DIR:-"$BUILD_DIR/model"}
mkdir -p "$MODEL_DIR"
python3 "$TASK3_ROOT/model/train.py" --output "$MODEL_DIR"
python3 "$TASK3_ROOT/model/quantize.py" --output "$MODEL_DIR"
python3 "$TASK3_ROOT/model/generate_video.py" \
    --frames 600 --seed 3103 --fps 10 \
    --output "$MODEL_DIR/line-follow.y4m" \
    --truth "$MODEL_DIR/truth.csv"
printf 'model_dir=%s\n' "$MODEL_DIR"
