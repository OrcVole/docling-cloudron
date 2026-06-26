# AGENTS.md

This file is the working contract for any AI agent or human who edits this repository. Read it fully
before changing anything. It encodes decisions that are already settled, so that you do not
relitigate them and do not regress conformance.

If you are an AI agent: treat the rules in "Golden rules" as hard constraints. When a request
conflicts with them, stop and surface the conflict rather than working around it.

This repository packages **Docling Serve** (https://github.com/docling-project/docling-serve, MIT, the
HTTP API server for Docling, an open document-conversion toolkit) as a **Cloudron-conformant
application**. The goals, in order: (1) it runs cleanly and securely on Cloudron, (2) the repository
is public so others can use it, and (3) it is written to a standard where the Cloudron team could
adopt it as an official application.

It is the document-ingestion tier of a self-hosted RAG stack: Docling parses documents into clean
Markdown/JSON, an embeddings server turns the text into vectors, and a vector database stores and
searches them. The companions are the TEI package (https://github.com/OrcVole/tei-cloudron) and the
Qdrant package (https://github.com/OrcVole/qdrant-cloudron). See docs/INTEGRATIONS.md.

---

## 1. Golden rules (non-negotiable)

1. **Conformance first.** The Cloudron packaging rules in section 5 override convenience. A change
   that writes outside the allowed paths, runs as root, or skips the health check is wrong.
2. **Pin the upstream version. Never use floating tags.** The canonical version is the
   `DOCLING_SERVE_VERSION` build argument in `Dockerfile`. The manifest mirrors it in
   `upstreamVersion`. The package `version` is our own semver and moves independently.
3. **Do not break the topology.** The convert API and the browser surfaces are two security models.
   See section 6. Never place the Cloudron proxyAuth wall in front of the convert API.
4. **Persisted state lives only in `/app/data`.** The API key and the runtime caches live there,
   which is what makes the Cloudron backup complete.
5. **Fail loud, log clearly.** `start.sh` fails fast (`set -euo pipefail`) and prints greppable
   `==>` markers.
6. **Every change updates its documentation.** Code and docs ship together.
7. **House style for prose:** Markdown and open formats only. No em dashes. Full words rather than
   contractions.
8. **Verify, do not assume.** When an upstream flag, image layout, env var, or Cloudron capability
   might have changed, check the live docs and confirm empirically. Record what you verified versus
   assumed (docs/PACKAGING-NOTES.md).

---

## 2. What this repository is and is not

- It **is** a thin packaging layer: a Dockerfile, an entrypoint, a manifest, and docs.
- It **is not** a fork of Docling. Docling is not patched. The package installs the pinned upstream
  release and adapts only the runtime environment to Cloudron.
- Upstream owns the conversion behaviour. This package owns the packaging, the security defaults, the
  topology, and the upgrade path.

---

## 3. Pinned versions and the build (the non-obvious part)

**Canonical upstream version:** the `DOCLING_SERVE_VERSION` build argument in `Dockerfile` (currently
`1.25.0`). The manifest mirrors it in `upstreamVersion`.

Unlike the TEI/Qdrant packages (a single upstream binary copied onto cloudron/base), docling-serve is
a full Python 3.12 ML application: torch, the layout and TableFormer models, and OCR engines. The
official image is built on CentOS Stream 9; rather than copy a uv venv across distributions, this
package installs the pinned release straight onto `cloudron/base` (Ubuntu 24.04, the same Python 3.12
the app expects) with uv. See docs/decisions/0001-pip-install-on-base.md.

Two things make the build correct:

- **CPU-only torch.** The plain PyPI torch wheel bundles the CUDA runtime (multiple GB). The
  Dockerfile installs torch from the PyTorch CPU index FIRST, so the docling-serve install finds
  torch already satisfied and does not pull the CUDA build. The runtime gate confirms
  `torch.__version__` ends in `+cpu` and `torch.cuda.is_available()` is False.
- **Models baked in.** `docling-tools models download` bakes the pipeline models (layout,
  TableFormer, picture classifier, RapidOCR, EasyOCR) into the image under `/app/code/models`, so the
  app is ready on first boot with no download and no health-grace race. See
  docs/decisions/0002-bake-models.md.

The build-time gate only imports the modules. The dlopen-heavy runtime (torch, OpenCV, the models) is
exercised only by an actual conversion, so the real gate is the runtime convert smoke
(`test/smoke.sh`).

---

## 4. Cloudron conformance rules

- **Base image:** the build stage is `cloudron/base`, pinned by digest.
- **Read-only root filesystem.** Only `/tmp`, `/run`, and `/app/data` are writable. The app writes
  only to its caches under `/app/data` (HF home, conversion scratch) and the key; the baked models
  under `/app/code` are read-only.
- **Code under `/app/code`** (read-only at runtime). **State under `/app/data`** (the `localstorage`
  addon, the only backed-up location). Chown `/app/data` in `start.sh` before dropping privileges.
- **Run as the `cloudron` user** via `gosu cloudron:cloudron`. The listener is on the non-privileged
  port 5001 (the upstream default; no move needed).
- **Health check:** `healthCheckPath` is `/health`, which returns 200 and is exempt from the API key
  (verified empirically). See docs/decisions/0003-topology.md.
- **Instant usability:** no setup screen. The app works right after install; the generated key is
  surfaced through `postInstallMessage` and the install checklist.

---

## 5. Architecture and topology (the crux)

docling-serve exposes everything on one HTTP port (5001 in this package). The surfaces split by
purpose:

- **Convert API** (`POST /v1/convert/*`): protected by the API key. docling-serve enforces it as the
  `X-Api-Key` header (NOT a Bearer token). An unauthenticated POST returns 401.
- **Health** (`/health`): open, no key, so Cloudron can monitor the app.
- **Browser surfaces** (`/ui` the demonstrator UI, `/docs` the OpenAPI docs, `/openapi.json`,
  `/version`): app-open even when the API key is set (verified). `/ui` is placed behind Cloudron
  single sign-on with `proxyAuth`.

The package scopes `proxyAuth` to `/ui` only, so Cloudron SSO guards the human UI while the convert
API stays open at the network level and is protected by the key. This is why an unauthenticated
convert call returns docling-serve's own 401, not a login redirect.

Do NOT set `supportsBearerAuth`: docling-serve authenticates with `X-Api-Key`, not Bearer, and
nothing key-related sits under `/ui`, so the flag would only weaken the SSO wall (the lesson from the
TEI package). Declare `proxyAuth` from first install; Cloudron cannot add it later. Never widen
`proxyAuth` to cover the convert API; that would redirect programmatic clients to a login page and
break every integration. See docs/decisions/0003-topology.md.

The package generates one API key on first run, stored at `/app/data/.secrets/keys.env`, injected as
`DOCLING_SERVE_API_KEY`, and never echoed to logs.

---

## 6. Configuration model

docling-serve is configured by environment variables (the `DOCLING_SERVE_*` and `UVICORN_*`
families). `start.sh` owns the package-forced settings:

- **Package-forced:** the listen host (`UVICORN_HOST=0.0.0.0`) and port, the API key, the UI enabled
  (`DOCLING_SERVE_ENABLE_UI=1`), `HOME`/`HF_HOME`/scratch redirected under `/app/data`, and the
  artifacts path pointing at the baked models.
- **Operator-tunable** through the app's Environment: `DOCLING_HTTP_PORT`, `DOCLING_NUM_THREADS`,
  `DOCLING_SERVE_ARTIFACTS_PATH` (to point at a different model set), and any other `DOCLING_SERVE_*`
  knob the operator sets, which passes through.

First-run seeding (only the API key) is idempotent: written only when absent, so an update or restart
never clobbers it.

---

## 7. Build, install, test, update

```bash
# Local build + runtime convert smoke (no Cloudron box needed; uses podman)
test/smoke.sh

# Install or update on the target Cloudron
cloudron install --location docling.example.com --memory-limit 4G
cloudron update  --app docling.example.com

# Logs, exec, debug
cloudron logs -f --app docling.example.com
cloudron exec  --app docling.example.com
```

`test/smoke.sh` is the local gate: the image builds, the key gates the convert API, `/health` is
open, and a real PDF converts to Markdown on cloudron/base. On a real box, confirm the `/ui` SSO
behaviour, update survival, and backup/restore (the key and any cache survive). A change is not done
until the relevant gate passes.

---

## 8. Definition of done (pre-commit checklist)

- [ ] No write paths outside `/tmp`, `/run`, `/app/data` (verified on a real or local run).
- [ ] Runs as `cloudron`, not root.
- [ ] Upstream version pinned in the one canonical place; the base image pinned by digest; torch is
      the `+cpu` build (CUDA not available).
- [ ] Topology unchanged, or the change is recorded in an ADR and re-verified.
- [ ] `start.sh` uses `set -euo pipefail` and prints `==>` markers; first-run seeding is idempotent.
- [ ] Health check returns 2xx and is unauthenticated.
- [ ] README, CHANGELOG, PACKAGING-NOTES, and DEBUGGING updated as relevant.
- [ ] `test/smoke.sh` passes; the relevant box gate passes on the target Cloudron.
- [ ] No secret, personal host, email, or token in any tracked file (`test/secret-scan.sh`).
- [ ] Prose follows house style: no em dashes, full words, open formats.
