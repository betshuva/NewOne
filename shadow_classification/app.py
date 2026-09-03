from time import perf_counter

import cv2
import numpy as np
from flask import Flask, jsonify, request

app = Flask(__name__)
face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
hog = cv2.HOGDescriptor()
hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())


@app.get("/healthz")
def healthz():
    return jsonify({"ok": True, "version": "opencv-hog-haar-1"})


@app.post("/analyze")
def analyze():
    upload = request.files.get("image")
    if upload is None:
        return jsonify({"error": "No image provided"}), 400
    image = cv2.imdecode(np.frombuffer(upload.read(), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        return jsonify({"error": "Invalid image"}), 400
    height, width = image.shape[:2]
    scale = min(1.0, 1024.0 / max(height, width))
    if scale < 1.0:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    started = perf_counter()
    faces = face_cascade.detectMultiScale(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY),
                                          scaleFactor=1.1, minNeighbors=5, minSize=(24, 24))
    haar_ms = round((perf_counter() - started) * 1000)
    started = perf_counter()
    boxes, weights = hog.detectMultiScale(image, winStride=(8, 8), padding=(8, 8), scale=1.05)
    hog_ms = round((perf_counter() - started) * 1000)
    scores = [round(float(score), 4) for score in weights]
    return jsonify({
        "version": "opencv-hog-haar-1", "imageWidth": width, "imageHeight": height,
        "haarFaceDetected": len(faces) > 0, "haarFaceCount": len(faces),
        "haarConfidence": None, "haarDurationMs": haar_ms,
        "hogPersonDetected": len(boxes) > 0, "hogPersonCount": len(boxes),
        "hogConfidence": max(scores) if scores else 0, "hogDurationMs": hog_ms,
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
