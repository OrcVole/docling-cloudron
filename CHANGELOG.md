[1.0.5]

- Upstream docling-serve 1.32.0 to 1.35.0 (three releases merged)
- S3 region support for storage coordinates, form model fix, UI OCR selection preservation
- Ray application-level metrics support; notifier task cleanup
- Chart extraction runtimes, RQ queue waiting time via OTLP, multi-queue drain in priority order
- New `enable_api_docs` toggle and `/metrics` endpoint with Prometheus export
- Removal of deprecated openapi-3 endpoint (upstream deprecation cleanup)
- Five new settings added: enable_api_docs, allow_custom_chart_extraction_config, artifact_storage_region, eng_ray_generate_metrics, eng_ray_metrics_port; all default to existing-compatible values
- No breaking changes, no migration required, no packaging changes


- Update docling-serve 1.30.0 -> 1.32.0
- Upstream: invalid options on multipart endpoints now return 422 instead of 500, which may break clients that key off the 500 status
- Upstream: routine features and fixes across two releases
- No packaging changes: auth topology, workspace layout and secrets handling unchanged; base and built images digest-pinned

# Changelog

All notable changes to this Cloudron package are documented here. The package version is this
repository's own semver and moves independently of the upstream docling-serve version, which is
recorded in `upstreamVersion` in the manifest.

[1.0.3]
*2026-08-07*

- Update docling-serve 1.29.0 -> 1.30.0 (upstream release 2026-08-07)
- Upstream: Docling v2.118.0 (new backends, heading-hierarchy options and fixes),
  docling-jobkit v3.3.0 (new connectors); UI exposes PDF heading-level inference
- No packaging changes: proxyAuth on /ui, keyed convert API and key handling unchanged;
  transformers constraint byte-identical between releases

[1.0.2]
*2026-08-02*

Bump upstream to docling-serve 1.29.0 (15 commits since 1.25.0). No auth or entrypoint change;
upstream removed the unused KFP engine settings (`DOCLING_SERVE_ENG_KFP_*`), which this package
never set. Adds the `<upstream>` tag to DESCRIPTION.md.

[1.0.1]
*2026-06-26*

First published release. Hardening and a smaller image; no behaviour or topology change.

- Two-stage build. The image is built in a throwaway builder stage, and only the installed venv and
  the baked models are copied into a fresh `cloudron/base` runtime stage. This drops uv's multi-
  gigabyte download cache and the build-only packages, taking the image from about 8.7 GB to about
  6.0 GB. No packaging decision changes (see ADR 0001).
- The API key file is re-asserted to mode `0600` on every boot, not only at creation. A Cloudron
  restore returns the key file as `0644`; the `0700` parent directory still blocks traversal, but the
  file is now tightened on each start as defense in depth.
- Hugging Face telemetry is disabled (`HF_HUB_DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=1`) so the app does
  not phone home on boot. The default pipeline models are baked in, so this removes the only routine
  outbound call without blocking a deliberate model pull.
- Verified on the box: backup and restore survival (the key, the `/app/data` caches, and ownership
  survive, and the auth topology is intact afterwards).

[1.0.0]
*2026-06-26*

Initial package. Packages docling-serve 1.25.0 for Cloudron. Built and deployed to the target box;
not published.

- Multi-stage-free build straight onto `cloudron/base` (Ubuntu 24.04, Python 3.12): the pinned
  docling-serve release is installed with uv, CPU-only torch from the PyTorch CPU index.
- The default pipeline models (layout, TableFormer, picture classifier, RapidOCR, EasyOCR) are baked
  into the image, so the app is ready on first boot with no model download.
- API key generated on first run and stored under `/app/data/.secrets`; sent as the `X-Api-Key`
  header to the `/v1/convert/*` endpoints.
- The demonstrator UI (`/ui`) is enabled and scoped behind Cloudron single sign-on via `proxyAuth`;
  the convert API stays open at the network level and is protected by the key.
- All mutable state (HF cache, conversion scratch, the key) is kept under `/app/data` for backup.
- Runs as the `cloudron` user on the non-privileged port 5001.
