#!/usr/bin/env python3
"""Convert a bounded, audio-only recording using the installed FFmpeg encoder."""

import json
import resource
import sys
from fractions import Fraction

import av


MAX_SECONDS = 120
MAX_OUTPUT_BYTES = 2 * 1024 * 1024


class RecordingError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def convert(input_path, output_path, input_format):
    resource.setrlimit(resource.RLIMIT_CPU, (20, 20))
    resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024, 768 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES))
    if "libmp3lame" not in av.codecs_available:
        raise RecordingError("AUDIO_ENCODER_UNAVAILABLE", "MP3 encoder is unavailable")
    if input_format not in {"wav", "matroska", "ogg", "mov", "aac", "mp3"}:
        raise ValueError("unsupported recording container")

    # An explicit demuxer prevents a disguised playlist from opening other files.
    with av.open(input_path, format=input_format,
                 options={"protocol_whitelist": "file"}) as source:
        audio_streams = list(source.streams.audio)
        if len(audio_streams) != 1 or any(stream.type != "audio" for stream in source.streams):
            raise ValueError("recording must contain exactly one audio stream")
        audio = audio_streams[0]
        audio.codec_context.thread_count = 1
        duration = Fraction(0)
        samples_written = 0
        with av.open(output_path, "w", format="mp3") as target:
            encoded = target.add_stream("libmp3lame", rate=44100)
            encoded.bit_rate = 96000
            encoded.layout = "mono"
            encoded.codec_context.thread_count = 1
            resampler = av.AudioResampler(format="fltp", layout="mono", rate=44100)

            def write(frames):
                nonlocal samples_written
                for frame in frames:
                    frame.pts = samples_written
                    frame.time_base = Fraction(1, 44100)
                    samples_written += frame.samples
                    for packet in encoded.encode(frame):
                        target.mux(packet)

            for frame in source.decode(audio):
                if not frame.sample_rate or frame.sample_rate > 192000:
                    raise ValueError("unsupported recording sample rate")
                duration += Fraction(frame.samples, frame.sample_rate)
                if duration > MAX_SECONDS:
                    raise RecordingError("AUDIO_DURATION_EXCEEDED", "recording exceeds two minutes")
                frame.pts = None
                write(resampler.resample(frame))
            if duration <= 0:
                raise ValueError("empty recording")
            write(resampler.resample(None))
            for packet in encoded.encode(None):
                target.mux(packet)
        return {"durationSeconds": float(duration)}


if __name__ == "__main__":
    try:
        print(json.dumps(convert(*sys.argv[1:])))
    except Exception as error:
        print(json.dumps({"code": getattr(error, "code", "INVALID_AUDIO"),
                          "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
