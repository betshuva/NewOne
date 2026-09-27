from pydantic import BaseModel, Field


class Finding(BaseModel):
    label: str
    confidence: float = Field(ge=0, le=1)
    timestamp_seconds: float


class FrameSample(BaseModel):
    timestamp_seconds: float
    jpeg_base64: str
    reason: str


class AnalysisResult(BaseModel):
    filename: str
    duration_seconds: float
    sampled_frames: int
    decision: str
    allowed: bool
    labels: dict[str, float]
    findings: list[Finding]
    explanation: str
    frame_samples: list[FrameSample] = Field(default_factory=list)
