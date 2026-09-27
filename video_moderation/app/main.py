from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from app.analyzer import VideoAnalyzer
from app.schemas import AnalysisResult

app = FastAPI(title="Local Video Classification", version="0.1.0")
analyzer = VideoAnalyzer()
MAX_BYTES = int(os.getenv("MAX_VIDEO_MB", "200")) * 1024 * 1024


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/analyze", response_model=AnalysisResult)
def analyze_video(
    video: UploadFile = File(...),
    sample_interval_seconds: float = Form(5.0, ge=0.25, le=10.0),
) -> AnalysisResult:
    suffix = Path(video.filename or "video.mp4").suffix or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as target:
        path = Path(target.name)
        shutil.copyfileobj(video.file, target)
    try:
        if path.stat().st_size > MAX_BYTES:
            raise HTTPException(status_code=413, detail="Video is larger than the configured limit")
        return analyzer.analyze(path, video.filename or path.name, sample_interval_seconds)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        path.unlink(missing_ok=True)
