# Packaging notes (verified vs assumed)

A running log of what was confirmed empirically versus carried over by assumption, per AGENTS.md
golden rule 8. Newest first.

## 2026-06-26 - initial packaging (docling-serve 1.25.0)

Verified by inspecting the upstream image and docs:

- Upstream CPU image `quay.io/docling-project/docling-serve-cpu:latest` is v1.25.0 (the latest
  release, 2026-06-22) and is multi-arch (amd64 and arm64). It is a Python 3.12 app installed by uv
  into `/opt/app-root` on a CentOS Stream 9 base, entrypoint `container-entrypoint` then
  `docling-serve run`, listening on 5001.
- docling-serve has built-in API-key auth: `DOCLING_SERVE_API_KEY`, enforced as the `X-Api-Key`
  header (not Bearer). The UI is at `/ui`, off by default, enabled with `DOCLING_SERVE_ENABLE_UI=1`.
  OpenAPI docs at `/docs`. The model cache path is `DOCLING_SERVE_ARTIFACTS_PATH`; models load at
  boot by default.

Verified by building and running the package locally (test/smoke.sh, cloudron/base):

- The pip-install-on-base build links and runs: `docling-serve 1.25.0`, `torch 2.12.1+cpu`,
  `torch.cuda.is_available()` is False. CPU-only confirmed.
- The baked models make the app ready in about 12 seconds with no download.
- The entrypoint drops to the `cloudron` user; the generated API key is 64 hex characters at
  `/app/data/.secrets/keys.env`.
- A real one-page PDF converts to correct Markdown through the baked layout pipeline.
- Auth topology, probed with the API key set and no key sent:
  - `POST /v1/convert/file` -> 401 (key gates the convert API).
  - `/health` -> 200 (open; usable as healthCheckPath).
  - `/ui` -> 307 to `/ui/`, `/docs` -> 200, `/openapi.json` -> 200, `/version` -> 200 (browser
    surfaces are app-open even with the key set). This is why proxyAuth on `/ui` is correct and does
    not break the bundled UI.

Assumed / still to verify on a real box:

- That the `/ui` Gradio app functions end to end behind Cloudron SSO (the local probe shows the page
  is reachable; the full SSO + browser interaction is a box check).
- Update survival (the key and any `/app/data` cache persist across `cloudron update`).
- Backup and restore (the key and HF cache survive byte-equal).

Decisions recorded as ADRs: 0001 (pip-install on base), 0002 (bake models), 0003 (auth topology).

Known follow-ups:

- The image is large (~8.7 GB: torch plus baked models). A two-stage build (builder venv, final
  stage copies it plus runtime libraries only) can slim it without changing any decision.
- For byte-level reproducibility, add a full dependency freeze (a constraints file) before the
  official-track publish; the top-level version is already pinned.
