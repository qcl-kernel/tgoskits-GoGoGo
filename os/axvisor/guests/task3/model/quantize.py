#!/usr/bin/env python3
"""Quantize the task-three CNN and emit a dependency-free C model."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from model.dataset import generate_dataset
from model.network import REGIONS, TinyCNN

REQUANT_SHIFT = 20
ARCHITECTURE_DIMENSIONS = (
    ("TASK3_INPUT_WIDTH", 32),
    ("TASK3_INPUT_HEIGHT", 32),
    ("TASK3_KERNEL_SIZE", 3),
    ("TASK3_CONV1_CHANNELS", 4),
    ("TASK3_CONV1_OUTPUT_SIZE", 30),
    ("TASK3_POOL_OUTPUT_SIZE", 15),
    ("TASK3_CONV2_CHANNELS", 8),
    ("TASK3_CONV2_OUTPUT_SIZE", 13),
    ("TASK3_SPATIAL_REGIONS", 3),
    ("TASK3_SPATIAL_FEATURES", 24),
    ("TASK3_OUTPUT_CLASSES", 3),
)


def quantize_weights(weight: np.ndarray) -> tuple[np.ndarray, float]:
    maximum = float(np.max(np.abs(weight)))
    scale = maximum / 127.0 if maximum > 0.0 else 1.0
    quantized = np.clip(np.rint(weight / scale), -127, 127).astype(np.int8)
    return quantized, scale


def multiplier(real_scale: float) -> int:
    value = int(round(real_scale * (1 << REQUANT_SHIFT)))
    if not 0 < value < 2**31:
        raise ValueError(f"invalid requantization multiplier: {value}")
    return value


def conv_integer(x: np.ndarray, weight: np.ndarray, bias: np.ndarray) -> np.ndarray:
    windows = np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(1, 2))
    return (
        np.einsum(
            "nhwcij,ocij->nhwo",
            windows.astype(np.int64),
            weight.astype(np.int64),
            optimize=True,
        )
        + bias.astype(np.int64)
    )


def requantize_relu(
    accumulator: np.ndarray, scale_multiplier: int, shift: int
) -> np.ndarray:
    positive = np.maximum(accumulator, 0)
    rounded = (positive * scale_multiplier + (1 << (shift - 1))) >> shift
    return np.clip(rounded, 0, 127).astype(np.int8)


def integer_spatial_pool(x: np.ndarray) -> np.ndarray:
    outputs = []
    height = x.shape[1]
    for start, end in REGIONS:
        count = height * (end - start)
        total = x[:, :, start:end, :].astype(np.int64).sum(axis=(1, 2))
        outputs.append((total + count // 2) // count)
    return np.stack(outputs, axis=1).reshape(x.shape[0], -1).astype(np.int8)


def confidence_q15(logits: np.ndarray) -> np.ndarray:
    if logits.ndim != 2 or logits.shape[1] != 3:
        raise ValueError("logits must have shape (batch, 3)")
    ordered = np.sort(logits.astype(np.int64), axis=1)
    best = ordered[:, -1]
    second = ordered[:, -2]
    margin = best - second
    normalizer = np.abs(best) + np.abs(second)
    numerator = margin * 32767 + normalizer // 2
    confidence = np.where(normalizer == 0, 0, numerator // np.maximum(normalizer, 1))
    return np.clip(confidence, 0, 32767).astype(np.uint16)


def quantized_forward(pixels: np.ndarray, model: dict[str, object]) -> np.ndarray:
    x = (255 - pixels.astype(np.int16)).astype(np.uint8)[:, :, :, None]
    conv1 = conv_integer(x, model["conv1_w"], model["conv1_b"])
    a1 = requantize_relu(
        conv1, int(model["conv1_multiplier"]), int(model["conv1_shift"])
    )
    pooled = a1.reshape(a1.shape[0], 15, 2, 15, 2, 4).max(axis=(2, 4))
    conv2 = conv_integer(pooled, model["conv2_w"], model["conv2_b"])
    a2 = requantize_relu(
        conv2, int(model["conv2_multiplier"]), int(model["conv2_shift"])
    )
    features = integer_spatial_pool(a2)
    logits = (
        features.astype(np.int64) @ model["dense_w"].astype(np.int64)
        + model["dense_b"].astype(np.int64)
    )
    if np.any(logits < np.iinfo(np.int32).min) or np.any(logits > np.iinfo(np.int32).max):
        raise OverflowError("quantized logits exceed int32")
    return logits.astype(np.int32)


def build_quantized_model(float_model: TinyCNN) -> dict[str, object]:
    calibration_pixels, _, _ = generate_dataset(600, 1202)
    _, cache = float_model.forward(calibration_pixels, cache=True)
    activation1_scale = max(float(cache["a1"].max()) / 127.0, 1e-9)
    activation2_scale = max(float(cache["a2"].max()) / 127.0, 1e-9)

    conv1_w, conv1_weight_scale = quantize_weights(float_model.params["conv1_w"])
    conv2_w, conv2_weight_scale = quantize_weights(float_model.params["conv2_w"])
    dense_w, dense_weight_scale = quantize_weights(float_model.params["dense_w"])
    input_scale = 1.0 / 255.0

    conv1_bias_scale = input_scale * conv1_weight_scale
    conv2_bias_scale = activation1_scale * conv2_weight_scale
    dense_bias_scale = activation2_scale * dense_weight_scale
    return {
        "input_scale": input_scale,
        "conv1_w": conv1_w,
        "conv1_b": np.rint(float_model.params["conv1_b"] / conv1_bias_scale).astype(
            np.int32
        ),
        "conv1_weight_scale": conv1_weight_scale,
        "conv1_bias_scale": conv1_bias_scale,
        "conv1_activation_scale": activation1_scale,
        "conv1_multiplier": multiplier(conv1_bias_scale / activation1_scale),
        "conv1_shift": REQUANT_SHIFT,
        "conv2_w": conv2_w,
        "conv2_b": np.rint(float_model.params["conv2_b"] / conv2_bias_scale).astype(
            np.int32
        ),
        "conv2_weight_scale": conv2_weight_scale,
        "conv2_bias_scale": conv2_bias_scale,
        "conv2_activation_scale": activation2_scale,
        "conv2_multiplier": multiplier(conv2_bias_scale / activation2_scale),
        "conv2_shift": REQUANT_SHIFT,
        "dense_w": dense_w,
        "dense_b": np.rint(float_model.params["dense_b"] / dense_bias_scale).astype(
            np.int32
        ),
        "dense_weight_scale": dense_weight_scale,
        "dense_bias_scale": dense_bias_scale,
    }


def array_bytes(model: dict[str, object]) -> bytes:
    content = bytearray(b"TASK3CNN\x01")
    for _, value in ARCHITECTURE_DIMENSIONS:
        content.extend(struct.pack("<I", value))
    for name, dtype in (
        ("conv1_w", np.dtype("i1")),
        ("conv1_b", np.dtype("<i4")),
        ("conv2_w", np.dtype("i1")),
        ("conv2_b", np.dtype("<i4")),
        ("dense_w", np.dtype("i1")),
        ("dense_b", np.dtype("<i4")),
    ):
        content.extend(np.asarray(model[name], dtype=dtype).tobytes(order="C"))
    for name in (
        "input_scale",
        "conv1_weight_scale",
        "conv1_bias_scale",
        "conv1_activation_scale",
        "conv2_weight_scale",
        "conv2_bias_scale",
        "conv2_activation_scale",
        "dense_weight_scale",
        "dense_bias_scale",
    ):
        content.extend(struct.pack("<d", float(model[name])))
    content.extend(
        struct.pack(
            "<iiii",
            int(model["conv1_multiplier"]),
            int(model["conv1_shift"]),
            int(model["conv2_multiplier"]),
            int(model["conv2_shift"]),
        )
    )
    return bytes(content)


def format_array(name: str, c_type: str, values: np.ndarray) -> str:
    flattened = values.reshape(-1)
    rows = []
    for start in range(0, len(flattened), 12):
        rows.append("    " + ", ".join(str(int(value)) for value in flattened[start : start + 12]))
    return f"static const {c_type} {name}[{len(flattened)}] = {{\n" + ",\n".join(rows) + "\n};\n"


def write_header(path: Path, model: dict[str, object], digest: str) -> None:
    dimensions = "".join(
        f"#define {name} {value}\n" for name, value in ARCHITECTURE_DIMENSIONS
    )
    scales = "".join(
        f"#define TASK3_{name.upper()} {float(model[name]):.17g}\n"
        for name in (
            "input_scale",
            "conv1_weight_scale",
            "conv1_bias_scale",
            "conv1_activation_scale",
            "conv2_weight_scale",
            "conv2_bias_scale",
            "conv2_activation_scale",
            "dense_weight_scale",
            "dense_bias_scale",
        )
    )
    parts = [
        "#ifndef TASK3_MODEL_WEIGHTS_H\n#define TASK3_MODEL_WEIGHTS_H\n\n",
        "#include <stdint.h>\n\n",
        f'#define TASK3_MODEL_SHA256 "{digest}"\n',
        dimensions,
        scales,
        f"#define TASK3_CONV1_MULTIPLIER {int(model['conv1_multiplier'])}\n",
        f"#define TASK3_CONV1_SHIFT {int(model['conv1_shift'])}\n",
        f"#define TASK3_CONV2_MULTIPLIER {int(model['conv2_multiplier'])}\n",
        f"#define TASK3_CONV2_SHIFT {int(model['conv2_shift'])}\n\n",
        format_array("TASK3_CONV1_WEIGHTS", "int8_t", model["conv1_w"]),
        format_array("TASK3_CONV1_BIAS", "int32_t", model["conv1_b"]),
        format_array("TASK3_CONV2_WEIGHTS", "int8_t", model["conv2_w"]),
        format_array("TASK3_CONV2_BIAS", "int32_t", model["conv2_b"]),
        format_array("TASK3_DENSE_WEIGHTS", "int8_t", model["dense_w"]),
        format_array("TASK3_DENSE_BIAS", "int32_t", model["dense_b"]),
        "\n#endif\n",
    ]
    path.write_text("".join(parts), encoding="ascii")


def quantize(output: Path) -> dict[str, object]:
    float_model = TinyCNN.load(output / "float_weights.npz")
    quantized = build_quantized_model(float_model)
    digest = hashlib.sha256(array_bytes(quantized)).hexdigest()
    write_header(output / "model_weights.h", quantized, digest)

    test_pixels, _, test_classes = generate_dataset(600, 3103)
    logits = quantized_forward(test_pixels, quantized)
    predictions = np.argmax(logits, axis=1) + 1
    confidences = confidence_q15(logits)
    accuracy = float(np.mean(predictions == test_classes))
    if accuracy < 0.95:
        raise RuntimeError(f"quantized accuracy gate failed: {accuracy:.6f}")

    golden_count = 32
    with (output / "golden_vectors.bin").open("wb") as stream:
        stream.write(b"T3GV")
        stream.write(struct.pack("<I", golden_count))
        for index in range(golden_count):
            stream.write(test_pixels[index].tobytes(order="C"))
            stream.write(struct.pack("<3i", *(int(value) for value in logits[index])))
            stream.write(struct.pack("B", int(predictions[index])))
            stream.write(struct.pack("<H", int(confidences[index])))

    float_metadata = json.loads((output / "float_metadata.json").read_text())
    metadata = {
        **float_metadata,
        "quantized_accuracy": accuracy,
        "golden_vectors": golden_count,
        "model_sha256": digest,
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, sort_keys=True, indent=2) + "\n", encoding="ascii"
    )
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    metadata = quantize(args.output)
    print(f"quantized_accuracy={metadata['quantized_accuracy']:.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
