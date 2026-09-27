import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

from app.analyzer import VideoAnalyzer, sample_frame_indices


class SamplingTests(unittest.TestCase):
    def test_short_video_has_start_middle_end(self):
        timestamps = [i / 100 for i in range(459)]
        self.assertEqual(sample_frame_indices(timestamps, 4.59, 5), [0, 229, 458])

    def test_regular_targets_and_middle_are_deduplicated(self):
        timestamps = [i / 10 for i in range(300)]
        self.assertEqual(sample_frame_indices(timestamps, 30, 5), [0, 50, 100, 150, 200, 250, 299])
        self.assertEqual(sample_frame_indices(timestamps[:230], 23, 5), [0, 50, 100, 115, 150, 200, 229])

    def test_extremely_short_video_still_requires_three_frames(self):
        self.assertEqual(sample_frame_indices([0, .04, .08], .12, 5), [0, 1, 2])
        with self.assertRaises(ValueError):
            sample_frame_indices([0, .04], .08, 5)

    def test_decodes_actual_first_middle_last_without_scene_extras(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'clip.avi'
            writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*'MJPG'), 10, (64, 64))
            for i in range(46):
                writer.write(np.full((64, 64, 3), 255 if i % 2 else 0, dtype=np.uint8))
            writer.release()
            analyzer = VideoAnalyzer()
            with patch.object(analyzer, '_load_models'), patch.object(analyzer, '_analyze_frame') as analyze:
                result = analyzer.analyze(path, 'clip.avi')
            self.assertEqual(result.sampled_frames, 3)
            self.assertEqual(analyze.call_count, 3)
            self.assertEqual([f.timestamp_seconds for f in result.frame_samples], [0, 2.3, 4.5])
            self.assertAlmostEqual(result.duration_seconds, 4.6)
            # Unknown container duration uses decoded timestamps as well.
            with patch.object(analyzer, '_load_models'), patch.object(analyzer, '_analyze_frame'), patch.object(analyzer, '_duration', return_value=0):
                result = analyzer.analyze(path, 'clip.avi')
            self.assertEqual([f.timestamp_seconds for f in result.frame_samples], [0, 2.3, 4.5])
