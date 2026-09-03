#!/usr/bin/env python3
"""Probe and locally transcribe one audio file for the moderation queue."""

import argparse
import json
import os
import sys

import av


def audio_duration(path: str) -> float:
    with av.open(path) as container:
        streams = [stream for stream in container.streams if stream.type == "audio"]
        if not streams:
            raise ValueError("no audio stream")
        stream = streams[0]
        if stream.duration is not None and stream.time_base is not None:
            return float(stream.duration * stream.time_base)
        if container.duration is not None:
            return float(container.duration / av.time_base)
        raise ValueError("audio duration is unavailable")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("probe", "transcribe"))
    parser.add_argument("path")
    args = parser.parse_args()

    duration = audio_duration(args.path)
    if args.mode == "probe":
        print(json.dumps({"durationSeconds": duration}))
        return 0

    from faster_whisper import WhisperModel

    model_name = os.environ.get("WHISPER_MODEL", "small")
    model_dir = os.environ.get("WHISPER_MODEL_DIR")
    model = WhisperModel(
        model_name,
        device="cpu",
        compute_type="int8",
        download_root=model_dir,
        cpu_threads=1,
        num_workers=1,
    )
    segments, info = model.transcribe(
        args.path,
        language="he",
        beam_size=3,
        vad_filter=True,
        condition_on_previous_text=False,
    )
    transcript = " ".join(segment.text.strip() for segment in segments).strip()
    print(json.dumps({
        "durationSeconds": duration,
        "language": info.language,
        "languageProbability": info.language_probability,
        "transcript": transcript,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
