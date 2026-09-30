import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import av
import cv2
import numpy as np
from app.analyzer import VideoAnalyzer
from app.sampling import sample_times, sample_video


def clip(path, seconds, fps=2):
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*'MJPG'), fps, (32, 32))
    for i in range(int(seconds * fps)):
        writer.write(np.full((32, 32, 3), i % 256, dtype=np.uint8))
    writer.release()


class SamplingTests(unittest.TestCase):
    def test_twenty_times_include_both_endpoints_and_are_uniform(self):
        for end in [1, 30, 120, 5400]:
            times = sample_times(0, end)
            self.assertEqual(len(times), 20)
            self.assertEqual(times[0], 0)
            self.assertEqual(times[-1], end)
            for a, b in zip(times, times[1:]):
                self.assertAlmostEqual(b - a, end / 19)

    def test_short_video_has_no_duplicate_frames_and_always_has_endpoints(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'short.avi'
            clip(path, 2)
            duration, samples = sample_video(path)
            self.assertEqual(duration, 2)
            self.assertEqual([t for t, _ in samples], [0, .5, 1, 1.5])
            self.assertEqual(round(np.asarray(samples[0][1]).mean()), 0)
            with av.open(str(path)) as container:
                decoded_last = list(container.decode(video=0))[-1].to_image()
            self.assertEqual(np.asarray(samples[-1][1]).tolist(), np.asarray(decoded_last).tolist())

    def test_ninety_minutes_passes_and_one_second_over_is_blocked(self):
        with TemporaryDirectory() as directory:
            for seconds in [5400, 5401]:
                path = Path(directory) / f'{seconds}.avi'
                clip(path, seconds, fps=1)
                analyzer = VideoAnalyzer()
                with patch.object(analyzer, '_load_models'), patch.object(analyzer, '_analyze_frame') as analyze:
                    result = analyzer.analyze(path, path.name)
                if seconds == 5401:
                    self.assertTrue(result.labels.get('duration_exceeded'))
                    self.assertEqual(analyze.call_count, 0)
                    continue
                self.assertEqual(result.sampled_frames, 20)
                self.assertEqual(analyze.call_count, 20)
                self.assertEqual([call.args[1] for call in analyze.call_args_list[:2]], [0, 5399])
                self.assertEqual(result.frame_samples[0].timestamp_seconds, 0)
                self.assertEqual(result.frame_samples[-1].timestamp_seconds, 5399)
                self.assertEqual(result.frame_samples[0].reason, 'start')
                self.assertEqual(result.frame_samples[-1].reason, 'end')
                steps = np.diff([f.timestamp_seconds for f in result.frame_samples])
                self.assertLessEqual(max(steps) - min(steps), 1)

    def test_webm_without_duration_metadata(self):
        # Real browser-created WebM fixture is mounted by the test command.
        path = Path('/fixtures/webm-video.webm')
        if not path.exists(): self.skipTest('browser fixture not mounted')
        duration, samples = sample_video(path)
        self.assertGreater(duration, 0)
        self.assertLessEqual(len(samples), 20)
        self.assertEqual(samples[0][0], 0)
        self.assertGreaterEqual(samples[-1][0], samples[0][0])

    def test_multiframe_webm_without_declared_duration(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'live.webm'
            with av.open(str(path), 'w', format='webm', options={'live': '1'}) as output:
                stream = output.add_stream('libvpx', rate=5)
                stream.width, stream.height = 32, 32
                stream.pix_fmt = 'yuv420p'
                for i in range(30):
                    frame = av.VideoFrame.from_ndarray(np.full((32, 32, 3), i * 5, dtype=np.uint8), format='rgb24')
                    for packet in stream.encode(frame): output.mux(packet)
                for packet in stream.encode(): output.mux(packet)
            with av.open(str(path)) as source:
                self.assertIsNone(source.duration)
            duration, samples = sample_video(path)
            self.assertAlmostEqual(duration, 6, places=1)
            self.assertEqual(len(samples), 20)
            self.assertAlmostEqual(samples[-1][0], 5.8, places=1)
            self.assertEqual(samples[0][0], 0)
