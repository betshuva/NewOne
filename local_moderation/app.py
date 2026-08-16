import io
import os
import time

import torch
from flask import Flask, jsonify, request
from PIL import Image, ImageOps, UnidentifiedImageError
from transformers import AutoImageProcessor, AutoModelForImageClassification


MODEL_ID = os.environ.get("FALCON_MODEL_ID", "Falconsai/nsfw_image_detection")
MODEL_REVISION = os.environ.get(
    "FALCON_MODEL_REVISION",
    "63e0a066bb08d2ae47324b540fba3adfd4536569",
)
NSFW_THRESHOLD = float(os.environ.get("FALCON_NSFW_THRESHOLD", "0.85"))
REVIEW_THRESHOLD = float(os.environ.get("FALCON_REVIEW_THRESHOLD", "0.50"))
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_BYTES
Image.MAX_IMAGE_PIXELS = 25_000_000

torch.set_num_threads(max(1, min(2, os.cpu_count() or 1)))
processor = AutoImageProcessor.from_pretrained(
    MODEL_ID,
    revision=MODEL_REVISION,
    local_files_only=True,
)
model = AutoModelForImageClassification.from_pretrained(
    MODEL_ID,
    revision=MODEL_REVISION,
    local_files_only=True,
)
model.eval()


def normalize_label(label):
    value = str(label).strip().lower()
    if value in {"sfw", "safe"}:
        return "normal"
    return value


@app.get("/healthz")
def healthz():
    return jsonify({
        "ok": True,
        "model": MODEL_ID,
        "revision": MODEL_REVISION,
    })


@app.post("/moderate")
def moderate():
    image_file = request.files.get("image")
    if image_file is None:
        return jsonify({"error": "No image provided"}), 400

    started_at = time.perf_counter()
    try:
        raw = image_file.read(MAX_UPLOAD_BYTES + 1)
        if len(raw) > MAX_UPLOAD_BYTES:
            return jsonify({"error": "Image exceeds 10MB"}), 413
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
        inputs = processor(images=image, return_tensors="pt")
    except (UnidentifiedImageError, OSError, ValueError) as error:
        return jsonify({"error": f"Invalid image: {error}"}), 400

    inference_started_at = time.perf_counter()
    with torch.inference_mode():
        logits = model(**inputs).logits
        probabilities = torch.softmax(logits, dim=-1)[0].cpu().tolist()

    scores = {}
    for index, probability in enumerate(probabilities):
        label = normalize_label(model.config.id2label.get(index, str(index)))
        scores[label] = round(float(probability), 6)

    normal_score = float(scores.get("normal", 0.0))
    nsfw_score = float(scores.get("nsfw", 0.0))
    would_block = nsfw_score >= NSFW_THRESHOLD
    decision = "nsfw" if would_block else (
        "review" if nsfw_score >= REVIEW_THRESHOLD else "normal"
    )

    return jsonify({
        "available": True,
        "provider": MODEL_ID,
        "revision": MODEL_REVISION,
        "mode": "comparison",
        "scope": "generalNsfwOnly",
        "canApprove": False,
        "scores": {
            "normal": round(normal_score, 6),
            "nsfw": round(nsfw_score, 6),
        },
        "decision": decision,
        "confidence": round(max(normal_score, nsfw_score), 6),
        "threshold": NSFW_THRESHOLD,
        "reviewThreshold": REVIEW_THRESHOLD,
        "wouldBlock": would_block,
        "inferenceDurationMs": round(
            (time.perf_counter() - inference_started_at) * 1000
        ),
        "durationMs": round((time.perf_counter() - started_at) * 1000),
    })


@app.errorhandler(413)
def too_large(_error):
    return jsonify({"error": "Image exceeds 10MB"}), 413
