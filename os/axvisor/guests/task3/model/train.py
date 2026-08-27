#!/usr/bin/env python3
"""Train the deterministic float task-three CNN."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from model.dataset import generate_dataset
from model.network import Adam, TinyCNN


def accuracy(model: TinyCNN, pixels: np.ndarray, classes: np.ndarray) -> float:
    predictions = np.argmax(model.forward(pixels), axis=1) + 1
    return float(np.mean(predictions == classes))


def train(output: Path) -> dict[str, float | int]:
    train_pixels, _, train_classes = generate_dataset(3000, 1201)
    test_pixels, _, test_classes = generate_dataset(600, 3103)
    model = TinyCNN(seed=1201)
    optimizer = Adam(model.params, learning_rate=0.001)
    permutation_rng = np.random.default_rng(1201)
    batch_size = 32
    final_loss = 0.0

    for _epoch in range(25):
        order = permutation_rng.permutation(len(train_pixels))
        for start in range(0, len(order), batch_size):
            indices = order[start : start + batch_size]
            final_loss, gradients = model.loss_and_gradients(
                train_pixels[indices], train_classes[indices]
            )
            optimizer.step(model.params, gradients)

    float_accuracy = accuracy(model, test_pixels, test_classes)
    if float_accuracy < 0.97:
        raise RuntimeError(f"float accuracy gate failed: {float_accuracy:.6f}")
    output.mkdir(parents=True, exist_ok=True)
    model.save(output / "float_weights.npz")
    metadata = {
        "schema": 1,
        "train_seed": 1201,
        "test_seed": 3103,
        "train_samples": 3000,
        "test_samples": 600,
        "epochs": 25,
        "batch_size": batch_size,
        "learning_rate": 0.001,
        "final_batch_loss": final_loss,
        "float_accuracy": float_accuracy,
        "numpy_version": np.__version__,
    }
    (output / "float_metadata.json").write_text(
        json.dumps(metadata, sort_keys=True, indent=2) + "\n", encoding="ascii"
    )
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    metadata = train(args.output)
    print(f"float_accuracy={metadata['float_accuracy']:.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
