# Packaging notes (verified vs assumed)

A running log of what was confirmed empirically versus carried over by assumption, per AGENTS.md
golden rule 8. Newest first.

## 2026-08-02 - update round timing: this package is structurally slow to release

1.0.1 -> 1.0.2 (upstream 1.25.0 -> 1.29.0). The bump itself was trivial (15 commits, no auth or
entrypoint change; upstream removed the unused `DOCLING_SERVE_ENG_KFP_*` settings, which this
package never set). What was NOT fast: the image is ~6 GB (CPU torch plus the five baked pipeline
models), so both `podman build` (full pip resolve, torch install, model download) and `podman push`
to GHCR ran to roughly ten-plus minutes each on this workstation's connection, dwarfing every other
step in the release. **This is a property of the package, not of this one round** — every future
docling-serve update will pay the same build and push time regardless of how small the upstream
diff is. For the next update round: start this package's build in the background as early as
possible (even before the version bump is fully decided, using a placeholder tag, if the diff read
is otherwise done) and work on other packages' mechanical or reasoning-tier work while it runs,
rather than waiting on it serially. Do not schedule this package last in a round if the round is
time-boxed; its long pole is fixed cost, not diff size, so put it where the wait can overlap.

Verified on the real box by backup, restore, and in-container inspection:

- **Backup and restore survival.** A fresh `cloudron backup create` followed by `cloudron restore`
  brings the app back healthy. The API key is byte-identical across the restore (same sha256), the
  `/app/data` tree (hf cache, scratch, secrets) survives, ownership returns to `cloudron:cloudron`,
  and `start.sh` takes the "existing API key found" path rather than regenerating. The live topology
  is intact afterwards: `/health` 200, `POST /v1/convert/source` 401 without a key, `/ui` 302 to
  `/login`, `/version` 200.
- **Read-only root filesystem.** `/` is mounted `overlay ... (ro,...)`; only `/tmp` and `/app/data`
  are `rw` (plus `/run`). A write to `/app/code` as the `cloudron` user fails with "Read-only file
  system". The app process (PID 1) runs as `cloudron`. The runtime torch is `2.12.1+cpu` with
  `torch.cuda.is_available()` False.

Two findings, both fixed in this pass:

- **Key file mode drifts to 0644 on restore.** `start.sh` previously set `chmod 0600` on the key only
  in the first-run branch, but a Cloudron restore returns `keys.env` as `0644`. The `0700` parent
  `.secrets` dir still blocks traversal, so it was not exploitable, but the file mode was looser than
  intended. Fix: `start.sh` now re-asserts `chown cloudron:cloudron` and `chmod 0600` on the key on
  every boot, idempotently, not only at creation.
- **Hugging Face telemetry phones home on boot.** A `.agent_harnesses.json` manifest appears under
  `HF_HOME` (`/app/data/hf`): huggingface_hub fetches it to enrich its telemetry user-agent. For a
  self-hosted, models-baked package there is no reason to call out. Fix: `start.sh` now exports
  `HF_HUB_DISABLE_TELEMETRY=1` and `DO_NOT_TRACK=1`. This does not block a deliberate model pull.

Both fixes ship in the running container at the next `cloudron update` (the publish build); the live
`0700` dir keeps the current key protected in the meantime.

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

Verified on the real box (on-server build install, docling.example.com):

- The on-server build succeeds and the app reaches healthy ("Wait for health check" passes), so
  `/health` works through the Cloudron reverse proxy.
- Anonymous probes through the proxy: `/health` 200, `/docs` 200, `/version` 200, `/ui` 302 to
  `/login?redirect=/ui` (the proxyAuth SSO wall works), `POST /v1/convert/file` 401 without a key.
- A keyed convert through the proxy (`X-Api-Key`) returns `status: success` with correct Markdown, so
  the full pipeline runs end to end on the box.

Assumed / still to verify on a real box:

- Update survival (the key and any `/app/data` cache persist across `cloudron update`). To be
  confirmed during the first publish update (1.0.0 -> 1.0.1). Backup and restore are now verified
  (see the hardening pass above).

Decisions recorded as ADRs: 0001 (pip-install on base), 0002 (bake models), 0003 (auth topology).

Known follow-ups:

- Image size: done in 1.0.1. A two-stage build copies only the venv and the baked models into a
  fresh runtime stage, dropping uv's download cache (which the single-stage build had baked into its
  layers) and the build-only packages. Measured: 8.74 GB single-stage -> 6.05 GB two-stage, with the
  convert smoke still passing. The remainder is irreducible: cloudron/base is 2.48 GB, torch + the
  ML/OCR wheels are about 2.6 GB, and the baked models are 0.74 GB.
- For byte-level reproducibility, add a full dependency freeze (a constraints file) before the
  official-track publish; the top-level version is already pinned.
