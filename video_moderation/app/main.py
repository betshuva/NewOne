from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile

from app.analyzer import VideoAnalyzer
from app.schemas import AnalysisResult

app = FastAPI(title="Local Video Classification", version="0.1.0")
analyzer = VideoAnalyzer()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/analyze", response_model=AnalysisResult)
def analyze_video(
    video: UploadFile = File(...),
) -> AnalysisResult:
    suffix = Path(video.filename or "video.mp4").suffix or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as target:
        path = Path(target.name)
        shutil.copyfileobj(video.file, target)
    try:
        return analyzer.analyze(path, video.filename or path.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        path.unlink(missing_ok=True)
