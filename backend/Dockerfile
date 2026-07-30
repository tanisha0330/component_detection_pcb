# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Builder
# ─────────────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        git \
        gcc \
        g++ \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender-dev \
        libgl1 \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 \
        python3.11-venv \
        python3.11-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

# Added timeout and fallback parameters for unstable connections
RUN pip install --no-cache-dir --default-timeout=1000 \
        torch==2.7.1+cu118 \
        torchvision==0.22.1+cu118 \
        torchaudio==2.7.1+cu118 \
        --index-url https://download.pytorch.org/whl/cu118

RUN pip install --no-cache-dir --default-timeout=1000 \
        "clip @ git+https://github.com/openai/CLIP.git@d05afc436d78f1c48dc0dbf8e5980a9d471f35f6" \
        "mobileclip @ git+https://github.com/apple/ml-mobileclip.git@aecfb5453d022e9deff12f81a150ea8f35194baa" \
        "ultralytics @ git+https://github.com/THU-MIG/yoloe.git@40cd606cabdbe2b566d6f14a6b162c89206e9a1b"

RUN pip install --no-cache-dir \
        fastapi==0.136.3 \
        uvicorn==0.49.0 \
        python-multipart==0.0.32 \
        sqlalchemy==2.0.50 \
        pydantic==2.13.4 \
        opencv-python-headless==4.13.0.92 \
        pillow==12.2.0 \
        numpy==2.4.6 \
        supervision==0.28.0 \
        timm==1.0.27 \
        open_clip_torch==3.3.0 \
        scikit-learn==1.9.0 \
        scipy==1.17.1 \
        transformers==5.10.2 \
        huggingface_hub==1.18.0 \
        psutil==7.2.2 \
        requests==2.34.2 \
        aiohttp==3.14.1 \
        tqdm==4.68.1 \
        easyocr==1.7.2

# Pre-warm the DINOv2 torch.hub cache (missing-component detection) and the
# EasyOCR model cache (marking/rating OCR) so the weights are baked into the
# image instead of being fetched on first inference request (this build
# stage has internet; the runtime container may not).
RUN python3.11 -c "import torch; torch.hub.load('facebookresearch/dinov2', 'dinov2_vits14', trust_repo=True)" \
    || echo "WARNING: could not pre-warm DINOv2 weights - missing-component detection will be disabled at runtime"
RUN python3.11 -c "import easyocr; easyocr.Reader(['en'], gpu=False, verbose=False)" \
    || echo "WARNING: could not pre-warm EasyOCR weights - marking/rating OCR will be disabled at runtime"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        libgl1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# DINOv2 (torch.hub) and EasyOCR model caches, pre-warmed in the builder stage
COPY --from=builder /root/.cache/torch /root/.cache/torch
COPY --from=builder /root/.EasyOCR    /root/.EasyOCR

WORKDIR /app

COPY app/ ./app/

COPY pcb_anchor_yolo.pt         ./pcb_anchor_yolo.pt
COPY FastSAM-x.pt               ./FastSAM-x.pt

RUN mkdir -p storage/samples

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

# ADDED --reload flag for Live Sync inside Docker
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]