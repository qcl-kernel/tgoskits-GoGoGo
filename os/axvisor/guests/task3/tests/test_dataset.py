import csv
import tempfile
import unittest
from pathlib import Path

import numpy as np

from model.dataset import CLASS_CENTER, CLASS_LEFT, CLASS_RIGHT, generate_dataset
from model.generate_video import generate_video


class DatasetTests(unittest.TestCase):
    def test_seed_is_reproducible_and_split_is_distinct(self):
        first_pixels, first_targets, first_classes = generate_dataset(96, 3103)
        second_pixels, second_targets, second_classes = generate_dataset(96, 3103)
        train_pixels, _, _ = generate_dataset(96, 1201)

        np.testing.assert_array_equal(first_pixels, second_pixels)
        np.testing.assert_array_equal(first_targets, second_targets)
        np.testing.assert_array_equal(first_classes, second_classes)
        self.assertFalse(np.array_equal(first_pixels, train_pixels))
        self.assertEqual(first_pixels.shape, (96, 32, 32))
        self.assertEqual(first_pixels.dtype, np.uint8)
        self.assertLessEqual(int(first_targets.max()), 20000)
        self.assertGreaterEqual(int(first_targets.min()), -20000)
        self.assertEqual(
            set(np.unique(first_classes).tolist()),
            {CLASS_LEFT, CLASS_CENTER, CLASS_RIGHT},
        )

    def test_video_and_truth_have_exact_frame_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            video = root / "line-follow.y4m"
            truth = root / "truth.csv"

            generate_video(video, truth, frames=600, seed=3103, fps=10)

            data = video.read_bytes()
            self.assertTrue(
                data.startswith(b"YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n")
            )
            self.assertEqual(data.count(b"FRAME\n"), 600)
            with truth.open(newline="", encoding="ascii") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 600)
            self.assertEqual(list(rows[0]), ["frame_id", "target_q15", "class"])
            self.assertEqual([int(row["frame_id"]) for row in rows], list(range(600)))


if __name__ == "__main__":
    unittest.main()
