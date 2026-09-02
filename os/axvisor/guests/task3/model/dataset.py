"""Deterministic synthetic line-following images for task three."""

from __future__ import annotations

import numpy as np

IMAGE_SIZE = 32
TARGET_MIN = -20000
TARGET_MAX = 20000
CLASS_LEFT = 1
CLASS_CENTER = 2
CLASS_RIGHT = 3


def classify_target(target_q15: int) -> int:
    if target_q15 < -6000:
        return CLASS_LEFT
    if target_q15 > 6000:
        return CLASS_RIGHT
    return CLASS_CENTER


def render_frame(target_q15: int, rng: np.random.Generator) -> np.ndarray:
    """Render one noisy grayscale frame with a dark guide line."""
    if not TARGET_MIN <= target_q15 <= TARGET_MAX:
        raise ValueError("target_q15 is outside the supported trajectory")

    y, x = np.mgrid[0:IMAGE_SIZE, 0:IMAGE_SIZE]
    illumination = rng.integers(170, 231)
    vertical_gradient = rng.uniform(-20.0, 20.0) * (y / (IMAGE_SIZE - 1) - 0.5)
    image = np.full((IMAGE_SIZE, IMAGE_SIZE), illumination, dtype=np.float64)
    image += vertical_gradient

    center = (IMAGE_SIZE - 1) / 2 + target_q15 * 11.0 / TARGET_MAX
    slope = rng.uniform(-0.045, 0.045)
    line_center = center + slope * (y - (IMAGE_SIZE - 1) / 2)
    half_width = rng.uniform(1.0, 2.1)
    line_mask = np.abs(x - line_center) <= half_width
    image[line_mask] = rng.uniform(18.0, 55.0)

    image += rng.normal(0.0, rng.uniform(2.0, 8.0), image.shape)
    if rng.random() < 0.25:
        top = int(rng.integers(3, 25))
        left = int(rng.integers(0, 25))
        height = int(rng.integers(2, 6))
        width = int(rng.integers(2, 7))
        image[top : top + height, left : left + width] = rng.uniform(90.0, 180.0)

    return np.clip(np.rint(image), 0, 255).astype(np.uint8)


def _balanced_target(index: int, rng: np.random.Generator) -> int:
    bucket = index % 3
    if bucket == 0:
        return int(rng.integers(TARGET_MIN, -6000))
    if bucket == 1:
        return int(rng.integers(-6000, 6001))
    return int(rng.integers(6001, TARGET_MAX + 1))


def generate_dataset(
    count: int, seed: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if count <= 0:
        raise ValueError("count must be positive")
    rng = np.random.default_rng(seed)
    targets = np.empty(count, dtype=np.int16)
    classes = np.empty(count, dtype=np.uint8)
    pixels = np.empty((count, IMAGE_SIZE, IMAGE_SIZE), dtype=np.uint8)

    for index in range(count):
        target = _balanced_target(index, rng)
        targets[index] = target
        classes[index] = classify_target(target)
        pixels[index] = render_frame(target, rng)
    return pixels, targets, classes
