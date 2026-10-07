#!/usr/bin/env python3
"""Verify the actual short-video timeline before storage or moderation."""
import json
import math
import sys
import av

MAX_SECONDS = 10.0


def checked(duration):
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('unknown video duration')
    if duration > MAX_SECONDS + 1e-6:
        raise OverflowError('listing video exceeds ten seconds')
    return duration


def probe(path):
    with av.open(path, options={'protocol_whitelist': 'file'}) as container:
        if not container.streams.video:
            raise ValueError('no video stream')
        # Do not trust only the container header: WebM recordings can omit it.
        spans = {}
        timeline_first = timeline_last = None
        for packet in container.demux():
            if packet.stream.type not in ('video', 'audio') or packet.pts is None:
                continue
            base = packet.stream.time_base
            if base is None:
                raise ValueError('missing packet time base')
            start = float(packet.pts * base)
            end = float((packet.pts + (packet.duration or 0)) * base)
            first, last = spans.get(packet.stream.index, (start, end))
            spans[packet.stream.index] = (min(first, start), max(last, end))
            timeline_first = start if timeline_first is None else min(timeline_first, start)
            timeline_last = end if timeline_last is None else max(timeline_last, end)
            if timeline_last - timeline_first > MAX_SECONDS + 1e-6:
                raise OverflowError('listing video exceeds ten seconds')
            if max(last, end) - min(first, start) > MAX_SECONDS + 1e-6:
                raise OverflowError('listing video exceeds ten seconds')
        durations = [last - first for first, last in spans.values()]
        if timeline_first is not None:
            durations.append(timeline_last - timeline_first)
        if container.duration is not None:
            durations.append(float(container.duration / av.time_base))
        stream = container.streams.video[0]
        if stream.duration is not None and stream.time_base is not None:
            durations.append(float(stream.duration * stream.time_base))
        # Confirm a real decodable video and include its last frame's duration.
        container.seek(0, stream=stream, backward=True)
        first = last = None
        end = 0.0
        rate = float(stream.average_rate or 30)
        for frame in container.decode(stream):
            if frame.pts is None:
                raise ValueError('missing frame timestamp')
            current = float(frame.pts * stream.time_base)
            first = current if first is None else min(first, current)
            last = current
            end = current + (float(frame.duration * stream.time_base) if frame.duration else 1 / rate)
            if end - first > MAX_SECONDS + 1e-6:
                raise OverflowError('listing video exceeds ten seconds')
        if first is None or last is None:
            raise ValueError('no decoded video frames')
        durations.append(end - first)
        return checked(max(durations))


if __name__ == '__main__':
    try:
        print(json.dumps({'durationSeconds': probe(sys.argv[1])}))
    except Exception as error:
        print(json.dumps({'code': 'LISTING_VIDEO_TOO_LONG' if isinstance(error, OverflowError)
                          else 'LISTING_VIDEO_DURATION_UNKNOWN'}), file=sys.stderr)
        sys.exit(1)
