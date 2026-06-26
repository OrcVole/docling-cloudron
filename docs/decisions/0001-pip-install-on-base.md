# 0001: Install docling-serve onto cloudron/base with pip, rather than copy the upstream venv

Status: accepted (2026-06-26)

## Context

Cloudron requires the final image stage to be `cloudron/base` (so the file manager, web terminal, and
log viewer work). docling-serve cannot be consumed as-is. The official image
(`quay.io/docling-project/docling-serve-cpu`) is a full Python 3.12 ML application (torch, the layout
and TableFormer models, OCR engines) installed by uv into `/opt/app-root` on a CentOS Stream 9 base.

The TEI/Qdrant packages copy a single upstream binary onto cloudron/base. The equivalent here would
be a multi-stage copy of the whole uv venv plus the interpreter and the system libraries from the
CentOS image onto Ubuntu. For a large, dlopen-heavy ML stack that cross-distribution copy is brittle
(the interpreter, the exact native libraries, and the libraries the wheels dlopen all have to line
up).

## Decision

Install the pinned upstream release straight onto `cloudron/base` with uv. cloudron/base is Ubuntu
24.04, which ships the same Python 3.12 the app expects, so manylinux wheels resolve cleanly. The
package does not patch docling; it installs `docling-serve==<pinned>` and adapts only the runtime
environment.

CPU-only torch is installed first from the PyTorch CPU index, so the docling-serve install finds torch
already satisfied (the CPU and CUDA wheels share the same version string) and does not pull the
multi-gigabyte CUDA build. The runtime gate confirms `torch.__version__` ends in `+cpu`.

The tesserocr Python binding (which compiles against libtesseract) is intentionally not installed;
Tesseract remains usable through its CLI (the system package), and EasyOCR and RapidOCR cover OCR
without it.

## Consequences

- The build is reproducible enough for the official track (the top-level version is pinned; a full
  dependency freeze can be added as a constraints file before publishing for byte-level
  reproducibility).
- The image is large (torch plus the baked models). A two-stage build (a builder that creates the
  venv, a final stage that copies it and installs only runtime libraries) can slim it later without
  changing this decision.
- When bumping the upstream version, rebuild and re-run the convert smoke; the dlopen-heavy runtime is
  not exercised by the build-time import gate.
