# Docling Serve (document conversion API) packaged for Cloudron.
#
# Unlike the TEI/Qdrant packages (a single upstream binary copied onto cloudron/base), docling-serve
# is a full Python 3.12 ML application (torch, layout + TableFormer models, OCR engines). Rather than
# copy a uv venv across distributions from the official CentOS-based image, this package installs the
# pinned upstream release straight onto cloudron/base with uv, on the same Ubuntu 24.04 / Python 3.12
# the app expects. The version is pinned by the DOCLING_SERVE_VERSION build argument; the manifest
# mirrors it in upstreamVersion. The pipeline models are baked into the image at build time so the
# first boot needs no download (avoiding the health-grace-vs-download race the TEI package hit).

FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

ARG DOCLING_SERVE_VERSION=1.25.0
ENV DOCLING_SERVE_VERSION=${DOCLING_SERVE_VERSION}

# --- System dependencies -------------------------------------------------------------------------
# python3.12 (+venv): the interpreter; cloudron/base is Ubuntu 24.04, which ships Python 3.12, the
#   same minor the upstream image uses, so wheels resolve cleanly.
# tesseract-ocr(+eng): the Tesseract engine, usable by docling through its OCR CLI option.
# libgl1, libglib2.0-0: OpenCV runtime libraries (docling, easyocr and rapidocr pull OpenCV).
# libgomp1: OpenMP runtime used by onnxruntime / torch.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      tesseract-ocr tesseract-ocr-eng \
      libgl1 libglib2.0-0 libgomp1 \
      ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ENV VENV=/app/code/venv
ENV PATH=${VENV}/bin:${PATH} \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# uv (installed into the venv) drives the dependency resolution of the large ML stack quickly and
# deterministically.
RUN python3.12 -m venv ${VENV} \
    && ${VENV}/bin/pip install --no-cache-dir --upgrade pip uv

# Install CPU-only torch FIRST, from the PyTorch CPU index. The plain PyPI torch wheel bundles the
# CUDA runtime (multiple GB); pinning the CPU build here means the subsequent docling-serve install
# finds torch already satisfied (CPU and CUDA wheels share the same version string) and does not pull
# the CUDA build. This is what makes the image a true CPU package.
RUN ${VENV}/bin/uv pip install --python ${VENV}/bin/python \
      --index-url https://download.pytorch.org/whl/cpu \
      torch torchvision

# docling-serve, pinned, with the demonstrator UI and the OCR engines. The CPU torch index is kept as
# a fallback (with unsafe-best-match) so any torch/vision resolution stays on the CPU build. Tesseract
# is available via its CLI (system package above); the tesserocr Python binding is intentionally not
# installed (it compiles against libtesseract and is not needed for rapidocr/easyocr or the Tesseract
# CLI path).
RUN ${VENV}/bin/uv pip install --python ${VENV}/bin/python \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      --index-strategy unsafe-best-match \
      "docling-serve[ui,rapidocr,easyocr]==${DOCLING_SERVE_VERSION}"

# Bake the version-locked pipeline models into the image (same set the upstream image pre-downloads),
# so the app is ready immediately on first boot and runs offline. They live under /app/code (read
# only at runtime); start.sh keeps only mutable state under /app/data.
ENV DOCLING_SERVE_ARTIFACTS_PATH=/app/code/models
RUN ${VENV}/bin/docling-tools models download -o ${DOCLING_SERVE_ARTIFACTS_PATH} \
      layout tableformer picture_classifier rapidocr easyocr \
    && chmod -R a+rX ${DOCLING_SERVE_ARTIFACTS_PATH}

COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/start.sh

# Build-time import + CLI gate: fail the build if the app cannot import or the CLI is broken on this
# base. This does NOT run a real conversion (torch/opencv/tesseract are dlopen-heavy and not
# exercised here), so the real gate is the runtime convert smoke in test/smoke.sh.
RUN ${VENV}/bin/python -c "import docling, docling_serve, torch; from importlib.metadata import version; print('imports ok: docling-serve', version('docling-serve'), 'torch', torch.__version__)" \
    && ${VENV}/bin/docling-serve --help >/dev/null

LABEL org.opencontainers.image.title="docling-cloudron" \
      org.opencontainers.image.description="Docling Serve (document conversion API) packaged for Cloudron" \
      org.opencontainers.image.source="https://github.com/OrcVole/docling-cloudron" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data, then drops to the cloudron user via gosu.
CMD [ "/app/code/start.sh" ]
