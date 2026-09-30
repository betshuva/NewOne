"""Bounded, time-spaced samples using packet metadata and keyframe seeks."""
from pathlib import Path
import math
import av

MAX_SAMPLES = 20
MAX_SECONDS = 90 * 60

class VideoDurationExceeded(ValueError):
    def __init__(self, duration: float):
        self.duration = duration
        super().__init__('Video exceeds 90 minutes')


def sample_times(first: float, last: float, count: int = MAX_SAMPLES) -> list[float]:
    if not math.isfinite(first) or not math.isfinite(last) or last < first:
        raise ValueError('Invalid video timeline')
    if count < 2 or count > MAX_SAMPLES:
        raise ValueError('Sample count must be between 2 and 20')
    if last == first:
        return [first]
    return [first + (last - first) * i / (count - 1) for i in range(count)]


def sample_video(path: Path) -> tuple[float, list[tuple[float, object]]]:
    with av.open(str(path), options={'protocol_whitelist': 'file'}) as container:
        if not container.streams.video:
            raise ValueError('No video stream')
        stream = container.streams.video[0]
        rate = float(stream.average_rate or 30)
        base = float(stream.time_base)
        first_pts = None
        last_key = None
        packet_end = 0.0
        # Demux packet headers without decompressing all video frames. This
        # also finds the true tail when WebM has no declared duration/cues.
        for packet in container.demux(stream):
            if packet.pts is None:
                continue
            pts = packet.pts
            first_pts = pts if first_pts is None else min(first_pts, pts)
            packet_end = max(packet_end, (pts + (packet.duration or 0)) * base)
            if packet.is_keyframe:
                last_key = pts if last_key is None else max(last_key, pts)
            if first_pts is not None and packet_end - first_pts * base > MAX_SECONDS + .25:
                raise VideoDurationExceeded(packet_end - first_pts * base)
        if first_pts is None or last_key is None:
            raise ValueError('No seekable video frames')

        def decode_from(pts: int):
            container.seek(pts, stream=stream, backward=True, any_frame=False)
            return container.decode(stream)

        first = next(decode_from(first_pts), None)
        if first is None or first.pts is None:
            raise ValueError('Cannot decode the first video frame')
        last = None
        for frame in decode_from(last_key):
            if frame.pts is not None and (last is None or frame.pts > last.pts):
                last = frame
        if last is None:
            raise ValueError('Cannot decode the last video frame')
        start_time = float(first.pts * stream.time_base)
        end_time = float(last.pts * stream.time_base)
        duration = max(packet_end, end_time + (float(last.duration * stream.time_base)
            if last.duration else 1 / rate)) - start_time
        if duration > MAX_SECONDS + .25:
            raise VideoDurationExceeded(duration)

        samples = {}
        def keep(frame):
            image = frame.to_image()
            image.thumbnail((768, 768))
            samples[frame.pts] = (float(frame.pts * stream.time_base) - start_time, image)
        keep(first)
        keep(last)
        for target in sample_times(start_time, end_time)[1:-1]:
            previous = None
            chosen = None
            for frame in decode_from(int(target / base)):
                if frame.pts is None:
                    continue
                time = float(frame.pts * stream.time_base)
                if time >= target:
                    chosen = frame
                    if previous is not None and target - float(previous.pts * stream.time_base) < time - target:
                        chosen = previous
                    break
                previous = frame
            chosen = chosen if chosen is not None else previous
            if chosen is None:
                raise ValueError('Cannot decode a required sample')
            keep(chosen)
        return duration, [samples[pts] for pts in sorted(samples)]
