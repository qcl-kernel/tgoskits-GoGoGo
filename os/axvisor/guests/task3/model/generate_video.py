#!/usr/bin/env python3
"""Generate the deterministic task-three Y4M video and private truth CSV."""

from __future__ import annotations

import argparse
import csv
import math
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from model.dataset import TARGET_MAX, TARGET_MIN, classify_target, render_frame


def trajectory(frame_id: int) -> int:
    primary = 15000.0 * math.sin(2.0 * math.pi * frame_id / 120.0)
    secondary = 4000.0 * math.sin(2.0 * math.pi * frame_id / 37.0)
    return int(round(max(TARGET_MIN, min(TARGET_MAX, primary + secondary))))


def generate_video(
    video_path: Path, truth_path: Path, *, frames: int, seed: int, fps: int
) -> None:
    if frames <= 0 or fps <= 0:
        raise ValueError("frames and fps must be positive")
    video_path.parent.mkdir(parents=True, exist_ok=True)
    truth_path.parent.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)

    video_fd, video_name = tempfile.mkstemp(dir=video_path.parent, prefix=".video-")
    truth_fd, truth_name = tempfile.mkstemp(dir=truth_path.parent, prefix=".truth-")
    try:
        with os.fdopen(video_fd, "wb") as video, os.fdopen(
            truth_fd, "w", newline="", encoding="ascii"
        ) as truth:
            video.write(
                f"YUV4MPEG2 W32 H32 F{fps}:1 Ip A1:1 Cmono\n".encode("ascii")
            )
            writer = csv.DictWriter(
                truth, fieldnames=["frame_id", "target_q15", "class"]
            )
            writer.writeheader()
            for frame_id in range(frames):
                target = trajectory(frame_id)
                video.write(b"FRAME\n")
                video.write(render_frame(target, rng).tobytes(order="C"))
                writer.writerow(
                    {
                        "frame_id": frame_id,
                        "target_q15": target,
                        "class": classify_target(target),
                    }
                )
        os.replace(video_name, video_path)
        os.replace(truth_name, truth_path)
    except BaseException:
        for temporary in (video_name, truth_name):
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--seed", type=int, default=3103)
    parser.add_argument("--fps", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--truth", type=Path, required=True)
    args = parser.parse_args()
    generate_video(
        args.output, args.truth, frames=args.frames, seed=args.seed, fps=args.fps
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
