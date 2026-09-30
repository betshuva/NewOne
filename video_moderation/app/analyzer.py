from __future__ import annotations

import os
import math
import base64
from collections import defaultdict
from pathlib import Path

from PIL import Image

from app.schemas import AnalysisResult, Finding, FrameSample
from app.sampling import sample_video, VideoDurationExceeded


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

    def analyze(self, path: Path, filename: str) -> AnalysisResult:
        try:
            duration, samples = sample_video(path)
        except VideoDurationExceeded as error:
            return AnalysisResult(
                filename=filename, duration_seconds=round(error.duration, 2),
                sampled_frames=0, decision="blocked", allowed=False,
                labels={"duration_exceeded": 1.0}, findings=[],
                explanation="Video exceeds the 90-minute duration limit.",
            )
        self._load_models()
        findings: list[Finding] = []
        frame_samples: list[FrameSample] = []
        maxima: dict[str, float] = defaultdict(float)
        # Check endpoints first. The returned manifest stays chronological.
        order = [0] if len(samples) == 1 else [0, len(samples) - 1, *range(1, len(samples) - 1)]
        for index in order:
            current, image = samples[index]
            self._analyze_frame(image, current, maxima, findings)
            reason = "start" if index == 0 else "end" if index == len(samples) - 1 else "scheduled"
            frame_samples.append(self._frame_sample(image, current, reason))
        frame_samples.sort(key=lambda sample: sample.timestamp_seconds)
        sampled = len(frame_samples)

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
