# Docling Serve (document conversion API) packaged for Cloudron.
#
# Unlike the TEI/Qdrant packages (a single upstream binary copied onto cloudron/base), docling-serve
# is a full Python 3.12 ML application (torch, layout + TableFormer models, OCR engines). Rather than
# copy a uv venv across distributions from the official CentOS-based image, this package installs the
# pinned upstream release straight onto cloudron/base (6.0.1, Ubuntu 26.04) with uv, on the Python 3.12
# the app expects. cloudron/base 6 carries Python 3.14 and no venv or pip, so uv installs its own
# pinned CPython 3.12 under /app/code/python and the venv links to it; no future base bump can move
# the interpreter (doctrine/base-6-migration.md step 5). The version is pinned by the
# DOCLING_SERVE_VERSION build argument; the manifest
# mirrors it in upstreamVersion. The pipeline models are baked into the image at build time so the
# first boot needs no download (avoiding the health-grace-vs-download race the TEI package hit).
#
# Three stages (a pinned uv, then two on the same cloudron/base so the venv is portable between them,
# see ADR 0001):
#   - uv: the pinned uv binary, which installs the interpreter as well as the packages.
#   - builder: install the build libraries, create the venv, install the pinned release, bake the
#     models. uv's multi-gigabyte download cache stays in this throwaway stage.
#   - runtime: install only the runtime libraries and COPY the venv + models across. The image ships
#     just the installed tree (about 2.5 GB lighter than a single-stage build that bakes the uv cache
#     into its layers).

# ===== Stage 0: uv, pinned ==============================================================
FROM ghcr.io/astral-sh/uv:0.13.1@sha256:4a1f3666816dafadd20ceb71eac9a7d56d7ef30279f7d64048519ab901ada336 AS uv

# ===== Stage 1: builder =================================================================
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee AS builder

ARG DOCLING_SERVE_VERSION=1.37.0
ENV DOCLING_SERVE_VERSION=${DOCLING_SERVE_VERSION}

# Build dependencies. The runtime libraries (tesseract, libGL, libgomp, libglib) are installed here
# too because the model bake imports OpenCV; the runtime stage installs its own slimmer subset.
# No python3.12-dev: every dependency installs as a wheel (nothing compiles; tesserocr is not
# installed), and uv's managed CPython ships its own headers should one ever be needed.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng \
      libgl1 libglib2.0-0 libgomp1 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /usr/local/bin/uv

ENV VENV=/app/code/venv \
    UV_PYTHON_INSTALL_DIR=/app/code/python \
    UV_PYTHON_PREFERENCE=only-managed
ENV PATH=${VENV}/bin:${PATH} \
    PYTHONUNBUFFERED=1

# The interpreter is a pinned uv-managed CPython 3.12 under /app/code/python (the same minor the
# package used on base 5). The venv's python is a symlink into it, so BOTH trees are copied to the
# runtime stage below.
RUN uv python install 3.12.15 \
    && uv venv --python 3.12.15 ${VENV}

# The managed CPython carries its own pip (26.2.1 at the time of writing). The Cloudron security
# advisory of 2026-10-21 asks for pip 26.2.2 or later, so raise it in the interpreter itself (the venv
# has no pip of its own; uv installs the packages). The build fails if the result is older.
RUN PY="$(uv python find 3.12.15)" \
    && "${PY}" -m pip install --no-cache-dir --break-system-packages 'pip>=26.2.2' \
    && "${PY}" -c "import pip; from importlib.metadata import version; v=tuple(int(x) for x in version('pip').split('.')[:3]); assert v>=(26,2,2), v; print('pip', version('pip'))"

# Install CPU-only torch FIRST, from the PyTorch CPU index. The plain PyPI torch wheel bundles the
# CUDA runtime (multiple GB); pinning the CPU build here means the subsequent docling-serve install
# finds torch already satisfied (CPU and CUDA wheels share the same version string) and does not pull
# the CUDA build. This is what makes the image a true CPU package.
RUN uv pip install --python ${VENV}/bin/python \
      --index-url https://download.pytorch.org/whl/cpu \
      torch torchvision

# docling-serve, pinned, with the demonstrator UI and the OCR engines. The CPU torch index is kept as
# a fallback (with unsafe-best-match) so any torch/vision resolution stays on the CPU build. Tesseract
# is available via its CLI (system package above); the tesserocr Python binding is intentionally not
# installed (it compiles against libtesseract and is not needed for rapidocr/easyocr or the Tesseract
# CLI path).
RUN uv pip install --python ${VENV}/bin/python \
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

# ===== Stage 2: runtime =================================================================
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

ARG DOCLING_SERVE_VERSION=1.37.0
ENV DOCLING_SERVE_VERSION=${DOCLING_SERVE_VERSION}

# Step 6b of base-6-migration.md (measured 2026-10-16): ldd over every *.so* in the venv, the managed
# CPython and /usr/bin/tesseract on THIS stage leaves only torchvision's libtorch/libc10 names, which
# torch supplies at import. No library base 5 carried incidentally is missing, so nothing is added
# beyond the four packages below.
# Runtime libraries only (no -dev headers, no curl): the Tesseract engine and the OpenCV/OpenMP
# shared libraries the wheels dlopen. The Python interpreter is NOT an apt package any more: it is the
# uv-managed CPython 3.12 copied below.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng \
      libgl1 libglib2.0-0 libgomp1 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV VENV=/app/code/venv
ENV PATH=${VENV}/bin:${PATH} \
    PYTHONUNBUFFERED=1 \
    DOCLING_SERVE_ARTIFACTS_PATH=/app/code/models

# Copy the interpreter, the built venv and the baked models from the builder. Both stages share the same
# cloudron/base and the same /app/code paths, so the venv's interpreter symlink (into /app/code/python)
# and shebangs resolve unchanged. Only the installed tree is copied; uv's download cache stays behind
# in the builder.
COPY --from=builder /app/code/python /app/code/python
COPY --from=builder /app/code/venv  /app/code/venv
COPY --from=builder /app/code/models /app/code/models

COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/start.sh

# Runtime gate on the assembled image, through the exact interpreter start.sh execs (#291): fail the
# build if the copied interpreter and venv cannot import the native modules (cv2, torch, onnxruntime),
# the OCR engine modules (EasyOCR, the default, and RapidOCR), or convert a tiny generated PDF to
# Markdown by text layer and by forced full-page OCR through each engine. This is what catches a
# system library cloudron/base no longer carries (step 6b of base-6-migration.md). The runtime convert
# smoke in test/smoke.sh remains the gate for the HTTP surface.
COPY tools/image-gate.py /tmp/image-gate.py
RUN HOME=/tmp /app/code/venv/bin/python /tmp/image-gate.py \
    && /app/code/venv/bin/python -c "import docling, docling_serve; from importlib.metadata import version; print('imports ok: docling-serve', version('docling-serve'))" \
    && /app/code/venv/bin/docling-serve --help >/dev/null \
    && rm -f /tmp/image-gate.py

LABEL org.opencontainers.image.title="docling-cloudron" \
      org.opencontainers.image.description="Docling Serve (document conversion API) packaged for Cloudron" \
      org.opencontainers.image.source="https://github.com/OrcVole/docling-cloudron" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data, then drops to the cloudron user via gosu.
CMD [ "/app/code/start.sh" ]
