from __future__ import annotations

import os
import math
import base64
from bisect import bisect_left
from collections import defaultdict
from pathlib import Path

import cv2
from PIL import Image

from app.schemas import AnalysisResult, Finding, FrameSample


PERSON_LABELS = ["child", "adult woman", "adult man"]
SCENE_LABELS = ["people", "landscape without people"]


def safety_decision(unsafe_score: float) -> str:
    """Return non-overlapping safety bands for one video's maximum score."""
    block_threshold = float(os.getenv("UNSAFE_THRESHOLD", "0.75"))
    review_threshold = float(os.getenv("REVIEW_THRESHOLD", "0.50"))
    if not 0 <= review_threshold < block_threshold <= 1:
        raise ValueError("Safety thresholds must satisfy 0 <= review < block <= 1")
    if unsafe_score >= block_threshold:
        return "blocked"
    if unsafe_score >= review_threshold:
        return "review"
    return "allowed"


def sample_frame_indices(timestamps: list[float], duration: float, interval: float) -> list[int]:
    """First, middle, last, plus five-second targets; decode each frame once."""
    if len(timestamps) < 3:
        raise ValueError("At least three decodable video frames are required")
    if not math.isfinite(interval) or interval <= 0:
        raise ValueError("The sample interval must be positive")
    def nearest(target: float, interior: bool = False) -> int:
        low, high = (1, len(timestamps) - 2) if interior else (0, len(timestamps) - 1)
        index = max(low, min(high, bisect_left(timestamps, target)))
        return min({max(low, index - 1), index}, key=lambda i: (abs(timestamps[i] - target), i))

    selected = {0, nearest(duration / 2, interior=True), len(timestamps) - 1}
    target = interval
    while target < duration:
        selected.add(nearest(target))
        target += interval
    return sorted(selected)


class VideoAnalyzer:
    """Lazy-loaded local models so health checks stay fast."""

    def __init__(self) -> None:
        self.device = int(os.getenv("MODEL_DEVICE", "-1"))
        self._detector = None
        self._clip = None
        self._safety = None

    def _load_models(self) -> None:
        if self._detector is not None:
            return
        from transformers import pipeline
        from ultralytics import YOLO

        self._detector = YOLO(os.getenv("YOLO_MODEL", "yolo11n.pt"))
        self._clip = pipeline(
            "zero-shot-image-classification",
            model=os.getenv("CLIP_MODEL", "openai/clip-vit-base-patch32"),
            device=self.device,
        )
        self._safety = pipeline(
            "image-classification",
            model=os.getenv("SAFETY_MODEL", "Falconsai/nsfw_image_detection"),
            device=self.device,
        )

    @staticmethod
    def _duration(cap: cv2.VideoCapture) -> float:
        fps = cap.get(cv2.CAP_PROP_FPS) or 0
        frames = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
        duration = frames / fps if fps > 0 and frames > 0 else 0
        return duration if math.isfinite(duration) and duration > 0 else 0

    def analyze(self, path: Path, filename: str, interval: float = 5.0) -> AnalysisResult:
        self._load_models()
        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            raise ValueError("The uploaded file is not a readable video")

        duration = self._duration(cap)
        max_duration = float(os.getenv("MAX_VIDEO_SECONDS", "30"))
        if duration > max_duration + 0.25:
            cap.release()
            return AnalysisResult(
                filename=filename, duration_seconds=round(duration, 2),
                sampled_frames=1, decision="blocked", allowed=False,
                labels={"duration_exceeded": 1.0}, findings=[],
                explanation="Video exceeds the configured duration limit.",
            )
        findings: list[Finding] = []
        frame_samples: list[FrameSample] = []
        maxima: dict[str, float] = defaultdict(float)
        sampled = 0
        current = 0.0

        try:
            # First pass finds actual frame timestamps, including the last frame.
            # This also handles WebM files without reliable duration metadata.
            fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
            timestamps = []
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                stream_ms = cap.get(cv2.CAP_PROP_POS_MSEC)
                current = stream_ms / 1000 if stream_ms > 0 else len(timestamps) / fps
                if timestamps and current <= timestamps[-1]:
                    current = timestamps[-1] + 1 / fps
                if current > max_duration + 0.25:
                    return AnalysisResult(
                        filename=filename, duration_seconds=round(current, 2),
                        sampled_frames=1, decision="blocked", allowed=False,
                        labels={"duration_exceeded": 1.0}, findings=[],
                        explanation="Video exceeds the configured duration limit.",
                    )
                timestamps.append(current)
            if duration <= 0:
                duration = timestamps[-1] + 1 / fps if timestamps else 0
            indices = sample_frame_indices(timestamps, duration, interval)
            if len(indices) > int(os.getenv("MAX_VIDEO_FRAME_SAMPLES", "90")):
                raise ValueError("The required samples exceed the configured frame limit")
            cap.release()
            cap = cv2.VideoCapture(str(path))
            selected = set(indices)
            frame_number = 0
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                if frame_number in selected:
                    current = timestamps[frame_number]
                    image = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
                    self._analyze_frame(image, current, maxima, findings)
                    reason = "start" if frame_number == 0 else (
                        "end" if frame_number == len(timestamps) - 1 else "scheduled")
                    frame_samples.append(self._frame_sample(image, current, reason))
                    sampled += 1
                frame_number += 1
            if sampled != len(indices):
                raise ValueError("Could not decode every required video sample")
        finally:
            cap.release()

        if sampled == 0:
            raise ValueError("No video frames could be decoded")

        nsfw = maxima.get("unsafe", 0.0)
        decision = safety_decision(nsfw)
        explanation = {
            "blocked": "Blocked because explicit-content confidence crossed the configured threshold.",
            "review": "Not automatically classified: suggestive-content confidence requires review.",
            "allowed": "No blocking signal crossed the configured threshold.",
        }[decision]
        return AnalysisResult(
            filename=filename,
            duration_seconds=round(duration, 2),
            sampled_frames=sampled,
            decision=decision,
            allowed=decision == "allowed",
            labels={key: round(value, 4) for key, value in sorted(maxima.items())},
            findings=findings,
            explanation=explanation,
            frame_samples=frame_samples,
        )

    @staticmethod
    def _frame_sample(image: Image.Image, timestamp: float, reason: str) -> FrameSample:
        from io import BytesIO
        preview = image.copy()
        preview.thumbnail((768, 768))
        output = BytesIO()
        preview.save(output, format="JPEG", quality=78, optimize=True)
        return FrameSample(timestamp_seconds=round(timestamp, 3),
                           jpeg_base64=base64.b64encode(output.getvalue()).decode("ascii"),
                           reason=reason)

    def _analyze_frame(
        self,
        image: Image.Image,
        timestamp: float,
        maxima: dict[str, float],
        findings: list[Finding],
    ) -> None:
        safety = self._safety(image)
        for result in safety:
            raw = result["label"].lower()
            label = "unsafe" if raw in {"nsfw", "porn", "explicit"} else "safe"
            maxima[label] = max(maxima[label], float(result["score"]))

        boxes = self._detector.predict(image, classes=[0], verbose=False)[0].boxes
        if boxes is None or len(boxes) == 0:
            scene = self._clip(image, candidate_labels=SCENE_LABELS)[0]
            label = "landscape" if "landscape" in scene["label"] else "people"
            maxima[label] = max(maxima[label], float(scene["score"]))
            return

        maxima["people"] = 1.0
        for box in boxes.xyxy.cpu().tolist():
            x1, y1, x2, y2 = map(int, box)
            crop = image.crop((x1, y1, x2, y2))
            result = self._clip(crop, candidate_labels=PERSON_LABELS)[0]
            label = result["label"].replace("adult ", "")
            score = float(result["score"])
            maxima[label] = max(maxima[label], score)
            if score >= 0.55:
                findings.append(Finding(label=label, confidence=score, timestamp_seconds=timestamp))
