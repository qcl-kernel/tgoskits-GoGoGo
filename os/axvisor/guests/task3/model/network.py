"""Small NumPy CNN with explicit forward and backward passes."""

from __future__ import annotations

import numpy as np


def _windows3(x: np.ndarray) -> np.ndarray:
    return np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(1, 2))


def conv3_forward(x: np.ndarray, weight: np.ndarray, bias: np.ndarray) -> np.ndarray:
    windows = _windows3(x)
    return np.einsum("nhwcij,ocij->nhwo", windows, weight, optimize=True) + bias


def conv3_backward(
    x: np.ndarray, weight: np.ndarray, gradient: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    windows = _windows3(x)
    grad_weight = np.einsum(
        "nhwcij,nhwo->ocij", windows, gradient, optimize=True
    )
    grad_bias = gradient.sum(axis=(0, 1, 2))
    grad_input = np.zeros_like(x)
    output_height = gradient.shape[1]
    output_width = gradient.shape[2]
    for row in range(3):
        for column in range(3):
            grad_input[
                :, row : row + output_height, column : column + output_width, :
            ] += np.einsum(
                "nhwo,oc->nhwc", gradient, weight[:, :, row, column], optimize=True
            )
    return grad_input, grad_weight, grad_bias


def maxpool2_forward(x: np.ndarray) -> tuple[np.ndarray, tuple[np.ndarray, np.ndarray]]:
    reshaped = x.reshape(x.shape[0], x.shape[1] // 2, 2, x.shape[2] // 2, 2, x.shape[3])
    pooled = reshaped.max(axis=(2, 4))
    mask = reshaped == pooled[:, :, None, :, None, :]
    counts = mask.sum(axis=(2, 4), keepdims=True)
    return pooled, (mask, counts)


def maxpool2_backward(
    gradient: np.ndarray, cache: tuple[np.ndarray, np.ndarray]
) -> np.ndarray:
    mask, counts = cache
    expanded = gradient[:, :, None, :, None, :] / counts
    return (mask * expanded).reshape(
        gradient.shape[0], gradient.shape[1] * 2, gradient.shape[2] * 2, gradient.shape[3]
    )


REGIONS = ((0, 4), (4, 9), (9, 13))


def spatial_pool_forward(x: np.ndarray) -> np.ndarray:
    features = [x[:, :, start:end, :].mean(axis=(1, 2)) for start, end in REGIONS]
    return np.stack(features, axis=1).reshape(x.shape[0], -1)


def spatial_pool_backward(gradient: np.ndarray, shape: tuple[int, ...]) -> np.ndarray:
    batch, height, _, channels = shape
    gradient = gradient.reshape(batch, len(REGIONS), channels)
    output = np.zeros(shape, dtype=gradient.dtype)
    for region, (start, end) in enumerate(REGIONS):
        scale = 1.0 / (height * (end - start))
        output[:, :, start:end, :] = gradient[:, region, None, None, :] * scale
    return output


class TinyCNN:
    def __init__(self, seed: int = 1201):
        rng = np.random.default_rng(seed)
        self.params = {
            "conv1_w": (
                rng.normal(0.0, np.sqrt(2.0 / 9), (4, 1, 3, 3)).astype(np.float32)
            ),
            "conv1_b": np.zeros(4, dtype=np.float32),
            "conv2_w": (
                rng.normal(0.0, np.sqrt(2.0 / 36), (8, 4, 3, 3)).astype(np.float32)
            ),
            "conv2_b": np.zeros(8, dtype=np.float32),
            "dense_w": (
                rng.normal(0.0, np.sqrt(2.0 / 24), (24, 3)).astype(np.float32)
            ),
            "dense_b": np.zeros(3, dtype=np.float32),
        }

    def forward(self, pixels: np.ndarray, *, cache: bool = False):
        x = (255.0 - pixels.astype(np.float32))[:, :, :, None] / 255.0
        z1 = conv3_forward(x, self.params["conv1_w"], self.params["conv1_b"])
        a1 = np.maximum(z1, 0.0)
        pooled, pool_cache = maxpool2_forward(a1)
        z2 = conv3_forward(pooled, self.params["conv2_w"], self.params["conv2_b"])
        a2 = np.maximum(z2, 0.0)
        features = spatial_pool_forward(a2)
        logits = features @ self.params["dense_w"] + self.params["dense_b"]
        if not cache:
            return logits
        return logits, {
            "x": x,
            "z1": z1,
            "a1": a1,
            "pool": pooled,
            "pool_cache": pool_cache,
            "z2": z2,
            "a2": a2,
            "features": features,
        }

    def loss_and_gradients(
        self, pixels: np.ndarray, classes: np.ndarray
    ) -> tuple[float, dict[str, np.ndarray]]:
        logits, cache = self.forward(pixels, cache=True)
        labels = classes.astype(np.int64) - 1
        shifted = logits - logits.max(axis=1, keepdims=True)
        probabilities = np.exp(shifted)
        probabilities /= probabilities.sum(axis=1, keepdims=True)
        loss = -np.log(probabilities[np.arange(len(labels)), labels] + 1e-12).mean()
        grad_logits = probabilities
        grad_logits[np.arange(len(labels)), labels] -= 1.0
        grad_logits /= len(labels)

        gradients: dict[str, np.ndarray] = {}
        gradients["dense_w"] = cache["features"].T @ grad_logits
        gradients["dense_b"] = grad_logits.sum(axis=0)
        grad_features = grad_logits @ self.params["dense_w"].T
        grad_a2 = spatial_pool_backward(grad_features, cache["a2"].shape)
        grad_z2 = grad_a2 * (cache["z2"] > 0.0)
        grad_pool, gradients["conv2_w"], gradients["conv2_b"] = conv3_backward(
            cache["pool"], self.params["conv2_w"], grad_z2
        )
        grad_a1 = maxpool2_backward(grad_pool, cache["pool_cache"])
        grad_z1 = grad_a1 * (cache["z1"] > 0.0)
        _, gradients["conv1_w"], gradients["conv1_b"] = conv3_backward(
            cache["x"], self.params["conv1_w"], grad_z1
        )
        return float(loss), gradients

    def save(self, path) -> None:
        np.savez(path, **self.params)

    @classmethod
    def load(cls, path) -> "TinyCNN":
        model = cls()
        with np.load(path) as archive:
            model.params = {name: archive[name].astype(np.float32) for name in archive.files}
        return model


class Adam:
    def __init__(self, parameters: dict[str, np.ndarray], learning_rate: float):
        self.learning_rate = learning_rate
        self.first = {name: np.zeros_like(value) for name, value in parameters.items()}
        self.second = {name: np.zeros_like(value) for name, value in parameters.items()}
        self.step_number = 0

    def step(self, parameters: dict[str, np.ndarray], gradients: dict[str, np.ndarray]):
        self.step_number += 1
        for name, value in parameters.items():
            gradient = np.clip(gradients[name], -5.0, 5.0)
            self.first[name] = 0.9 * self.first[name] + 0.1 * gradient
            self.second[name] = 0.999 * self.second[name] + 0.001 * gradient * gradient
            first_hat = self.first[name] / (1.0 - 0.9**self.step_number)
            second_hat = self.second[name] / (1.0 - 0.999**self.step_number)
            value -= self.learning_rate * first_hat / (np.sqrt(second_hat) + 1e-8)
