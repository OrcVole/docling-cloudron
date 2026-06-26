# Changelog

All notable changes to this Cloudron package are documented here. The package version is this
repository's own semver and moves independently of the upstream docling-serve version, which is
recorded in `upstreamVersion` in the manifest.

## [1.0.0] - unreleased

First release. Packages docling-serve 1.25.0 for Cloudron.

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
