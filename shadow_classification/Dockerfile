FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask gunicorn "numpy<2" "opencv-python-headless==4.10.0.84"
COPY app.py .
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "2", "--timeout", "60", "app:app"]
