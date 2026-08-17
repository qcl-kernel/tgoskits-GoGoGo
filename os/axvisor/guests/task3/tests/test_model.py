import hashlib
import json
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import numpy as np

from model.dataset import generate_dataset
from model.network import TinyCNN, conv3_backward, conv3_forward


ROOT = Path(__file__).resolve().parents[1]


class ModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output_directory = tempfile.TemporaryDirectory()
        cls.model_dir = Path(cls.output_directory.name) / "model"
        cls.environment = os.environ.copy()
        cls.environment["TASK3_MODEL_DIR"] = str(cls.model_dir)
        subprocess.run(
            [str(ROOT / "scripts" / "build_model.sh")],
            check=True,
            env=cls.environment,
        )

    @classmethod
    def tearDownClass(cls):
        cls.output_directory.cleanup()

    def test_quality_gates_and_export(self):
        metadata = json.loads((self.model_dir / "metadata.json").read_text())
        self.assertGreaterEqual(metadata["float_accuracy"], 0.97)
        self.assertGreaterEqual(metadata["quantized_accuracy"], 0.95)
        self.assertEqual(metadata["golden_vectors"], 32)
        self.assertEqual(metadata["train_samples"], 3000)
        self.assertEqual(metadata["test_samples"], 600)
        self.assertEqual(metadata["epochs"], 25)
        self.assertEqual(metadata["batch_size"], 32)
        self.assertEqual(metadata["learning_rate"], 0.001)
        self.assertIn("final_batch_loss", metadata)
        self.assertIn("numpy_version", metadata)

        golden = (self.model_dir / "golden_vectors.bin").read_bytes()
        self.assertEqual(golden[:4], b"T3GV")
        self.assertEqual(struct.unpack_from("<I", golden, 4)[0], 32)
        self.assertEqual(len(golden), 8 + 32 * (1024 + 12 + 1 + 2))

        header = (self.model_dir / "model_weights.h").read_text(encoding="ascii")
        for symbol in (
            "TASK3_INPUT_WIDTH",
            "TASK3_INPUT_HEIGHT",
            "TASK3_CONV1_OUTPUT_SIZE",
            "TASK3_POOL_OUTPUT_SIZE",
            "TASK3_CONV2_OUTPUT_SIZE",
            "TASK3_SPATIAL_FEATURES",
            "TASK3_OUTPUT_CLASSES",
            "TASK3_CONV1_WEIGHTS",
            "TASK3_CONV1_BIAS",
            "TASK3_CONV1_WEIGHT_SCALE",
            "TASK3_CONV1_BIAS_SCALE",
            "TASK3_CONV1_ACTIVATION_SCALE",
            "TASK3_CONV1_MULTIPLIER",
            "TASK3_CONV1_SHIFT",
            "TASK3_CONV2_WEIGHTS",
            "TASK3_CONV2_BIAS",
            "TASK3_CONV2_WEIGHT_SCALE",
            "TASK3_CONV2_BIAS_SCALE",
            "TASK3_CONV2_ACTIVATION_SCALE",
            "TASK3_CONV2_MULTIPLIER",
            "TASK3_CONV2_SHIFT",
            "TASK3_DENSE_WEIGHTS",
            "TASK3_DENSE_BIAS",
            "TASK3_DENSE_WEIGHT_SCALE",
            "TASK3_DENSE_BIAS_SCALE",
            "TASK3_MODEL_SHA256",
        ):
            self.assertIn(symbol, header)
        self.assertNotIn("timestamp", header.lower())

    def test_export_is_reproducible_and_matches_c(self):
        header = self.model_dir / "model_weights.h"
        first_hash = hashlib.sha256(header.read_bytes()).hexdigest()
        subprocess.run(
            [str(ROOT / "scripts" / "build_model.sh")],
            check=True,
            env=self.environment,
        )
        self.assertEqual(first_hash, hashlib.sha256(header.read_bytes()).hexdigest())
        subprocess.run(["make", "-C", str(ROOT / "tests"), "clean"], check=True)
        subprocess.run(
            [
                "make",
                "-C",
                str(ROOT / "tests"),
                "cnn_runner",
                f"MODEL_DIR={self.model_dir}",
            ],
            check=True,
        )
        subprocess.run(
            [
                str(ROOT / "build" / "tests" / "cnn_runner"),
                str(self.model_dir / "golden_vectors.bin"),
            ],
            check=True,
        )


class NetworkGradientTests(unittest.TestCase):
    @staticmethod
    def finite_difference(function, values, epsilon=1e-6):
        gradient = np.empty_like(values)
        for index in np.ndindex(values.shape):
            original = values[index]
            values[index] = original + epsilon
            positive = function()
            values[index] = original - epsilon
            negative = function()
            values[index] = original
            gradient[index] = (positive - negative) / (2.0 * epsilon)
        return gradient

    def test_conv3_backward_matches_all_finite_differences(self):
        rng = np.random.default_rng(91)
        inputs = rng.normal(size=(1, 5, 5, 2))
        weights = rng.normal(size=(2, 2, 3, 3))
        bias = rng.normal(size=2)
        upstream = rng.normal(size=(1, 3, 3, 2))

        def objective():
            return float(np.sum(conv3_forward(inputs, weights, bias) * upstream))

        grad_input, grad_weight, grad_bias = conv3_backward(inputs, weights, upstream)
        np.testing.assert_allclose(
            grad_input, self.finite_difference(objective, inputs), rtol=1e-7, atol=1e-7
        )
        np.testing.assert_allclose(
            grad_weight,
            self.finite_difference(objective, weights),
            rtol=1e-7,
            atol=1e-7,
        )
        np.testing.assert_allclose(
            grad_bias, self.finite_difference(objective, bias), rtol=1e-7, atol=1e-7
        )

    def test_cross_entropy_gradient_reaches_every_parameter_group(self):
        pixels, _, classes = generate_dataset(12, 1771)
        model = TinyCNN(seed=91)
        loss, gradients = model.loss_and_gradients(pixels, classes)

        self.assertTrue(np.isfinite(loss))
        self.assertEqual(set(gradients), set(model.params))
        for name, parameter in model.params.items():
            self.assertEqual(gradients[name].shape, parameter.shape)
            self.assertTrue(np.all(np.isfinite(gradients[name])), name)
            self.assertGreater(float(np.linalg.norm(gradients[name])), 0.0, name)

    def test_confidence_q15_has_independent_boundary_vectors(self):
        from model.quantize import confidence_q15

        logits = np.array(
            [
                [0, 0, -5],
                [100, 50, -1],
                [-10, -20, -30],
                [10, -10, -20],
                [np.iinfo(np.int32).max, 0, np.iinfo(np.int32).min],
            ],
            dtype=np.int32,
        )
        np.testing.assert_array_equal(
            confidence_q15(logits),
            np.array([0, 10922, 10922, 32767, 32767], dtype=np.uint16),
        )


if __name__ == "__main__":
    unittest.main()
