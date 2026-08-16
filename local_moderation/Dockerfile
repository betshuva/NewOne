FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/models/huggingface \
    HF_HUB_DISABLE_XET=1

WORKDIR /app

RUN pip install --upgrade pip==25.1.1 && \
    pip install --no-deps --trusted-host pypi.org \
      --trusted-host files.pythonhosted.org \
      --trusted-host download.pytorch.org \
      --trusted-host download-r2.pytorch.org \
      torch==2.5.1 torchvision==0.20.1 \
      --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --trusted-host pypi.org \
      --trusted-host files.pythonhosted.org \
      -r requirements.txt

ARG FALCON_MODEL_ID=Falconsai/nsfw_image_detection
ARG FALCON_MODEL_REVISION=63e0a066bb08d2ae47324b540fba3adfd4536569
ENV FALCON_MODEL_ID=${FALCON_MODEL_ID} \
    FALCON_MODEL_REVISION=${FALCON_MODEL_REVISION}

# Store the exact model revision in the image so runtime scanning never sends
# an uploaded image to an external service and does not depend on the network.
RUN python -c "from transformers import AutoImageProcessor, AutoModelForImageClassification; model='${FALCON_MODEL_ID}'; revision='${FALCON_MODEL_REVISION}'; AutoImageProcessor.from_pretrained(model, revision=revision); AutoModelForImageClassification.from_pretrained(model, revision=revision)"

COPY app.py .

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "2", "--timeout", "120", "app:app"]
