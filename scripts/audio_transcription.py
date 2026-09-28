#!/usr/bin/env python3
"""Read audio duration without speech recognition."""

import argparse
import json
import sys
from fractions import Fraction

import av


def audio_duration(path: str) -> float:
    with av.open(path) as container:
        streams = [stream for stream in container.streams if stream.type == "audio"]
        if not streams:
            raise ValueError("no audio stream")
        stream = streams[0]
        # MP3 container duration includes encoder padding. Decoded samples honor
        # gapless metadata so the displayed duration excludes encoder padding.
        if stream.codec_context.name in {"mp3", "mp3float"}:
            duration = Fraction(0)
            for frame in container.decode(stream):
                duration += Fraction(frame.samples, frame.sample_rate)
            return float(duration)
        if stream.duration is not None and stream.time_base is not None:
            return float(stream.duration * stream.time_base)
        if container.duration is not None:
            return float(container.duration / av.time_base)
        # Browser WebM recordings may omit duration metadata.
        duration = Fraction(0)
        for frame in container.decode(stream):
            duration += Fraction(frame.samples, frame.sample_rate)
        return float(duration)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("probe", "webm-type"))
    parser.add_argument("path")
    args = parser.parse_args()

    if args.mode == "webm-type":
        # Force the container demuxer: filenames and browser MIME types are
        # ambiguous, and must never cause video to take the audio-only path.
        with open(args.path, "rb") as source:
            if source.read(4) != bytes.fromhex("1a45dfa3"):
                raise ValueError("invalid WebM signature")
        with av.open(args.path, format="matroska",
                     options={"protocol_whitelist": "file"}) as container:
            types = [stream.type for stream in container.streams]
            if "video" in types:
                kind = "video"
            elif types and all(kind == "audio" for kind in types):
                kind = "audio"
            else:
                raise ValueError("no supported WebM media tracks")
        print(json.dumps({"mime": kind + "/webm"}))
        return 0

    duration = audio_duration(args.path)
    print(json.dumps({"durationSeconds": duration}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
