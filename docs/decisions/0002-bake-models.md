# 0002: Bake the pipeline models into the image

Status: accepted (2026-06-26)

## Context

docling-serve loads its models at boot (`DOCLING_SERVE_LOAD_MODELS_AT_BOOT` defaults to true). The
default pipeline needs the layout model, TableFormer, a picture classifier, and an OCR engine. These
can be downloaded on first boot (the TEI package downloads its embedding model on first boot) or baked
into the image at build time.

The TEI package learned that first-boot downloads race the Cloudron health-check grace period: if the
download is slow, the app is marked unhealthy before it is ready.

## Decision

Bake the version-locked models into the image at build time with `docling-tools models download -o
/app/code/models layout tableformer picture_classifier rapidocr easyocr` (the same set the upstream
image pre-downloads). The runtime artifacts path (`DOCLING_SERVE_ARTIFACTS_PATH`) points at this baked
directory under `/app/code` (read-only at runtime; the models are only read).

## Consequences

- The app is ready within seconds of first boot (verified: ~12s to "Application startup complete"),
  with no download and no health-grace race, and it runs offline.
- The models are deterministic and locked to the package build, not whatever upstream serves later.
- The models are not under `/app/data`, so they are not in the backup. That is correct: they are
  reproducible from the image and do not need backing up. Only mutable state (the key, the HF cache
  for any model pulled at runtime, conversion scratch) lives under `/app/data`.
- The image is larger by the size of the models. Accepted for instant, offline readiness.
- An operator who wants a different model set can override `DOCLING_SERVE_ARTIFACTS_PATH` to a
  directory under `/app/data` and populate it; the baked set is the default, not a hard limit.
