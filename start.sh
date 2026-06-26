#!/bin/bash
#
# Cloudron entrypoint for Docling Serve.
#
# Runs as root, prepares /app/data, generates and persists the API key on first run, exports the
# package-forced settings (host, port, cache paths under /app/data, the key, UI enabled), then drops
# to the cloudron user and execs docling-serve. Every package-emitted line is prefixed with "==>" so
# logs are greppable. See docs/DEBUGGING.md.

set -euo pipefail

CODE=/app/code
DATA=/app/data
VENV="${CODE}/venv"
BIN="${VENV}/bin/docling-serve"
SECRETS_DIR="${DATA}/.secrets"
KEYS_ENV="${SECRETS_DIR}/keys.env"
VERSION="${DOCLING_SERVE_VERSION:-unknown}"

# Writable, backed-up state lives only under /app/data.
HF_DIR="${DATA}/hf"               # HF_HOME: any model pulled at runtime (e.g. an optional VLM preset)
SCRATCH_DIR="${DATA}/scratch"     # docling-serve working area for in-flight conversions
HTTP_PORT="${DOCLING_HTTP_PORT:-5001}"

echo "==> [start] docling-serve ${VERSION} booting"

# 1. Ownership and layout. Backups/restores can reset ownership, so fix it before anything else.
echo "==> [start] preparing ${DATA} (hf cache, scratch, secrets)"
mkdir -p "${HF_DIR}" "${SCRATCH_DIR}" "${SECRETS_DIR}"
chown -R cloudron:cloudron "${DATA}"
chmod 0700 "${SECRETS_DIR}"

# 2. First run only: generate the API key. Never clobber an existing key; integrators may have it
#    configured. Docling authenticates the convert API with the X-Api-Key header.
if [[ ! -f "${KEYS_ENV}" ]]; then
  echo "==> [start] first run: generating API key"
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; cat > "${KEYS_ENV}" <<EOF
# Docling Serve API key generated on first run. Treat as a secret.
# Send it as the header  X-Api-Key: <key>  to the /v1/convert/* endpoints.
# /health is open (no key); /ui and /docs sit behind Cloudron single sign-on.
DOCLING_SERVE_API_KEY=${GEN_KEY}
EOF
  )
  unset GEN_KEY
  echo "==> [start] API key stored at ${KEYS_ENV}"
else
  echo "==> [start] existing API key found"
fi

# Re-assert key ownership and mode on every boot, not only at creation. A Cloudron restore returns
# keys.env as 0644 (verified empirically), so tightening it here keeps the secret file 0600 across
# restores. The 0700 parent dir already blocks traversal; this is defense in depth.
chown cloudron:cloudron "${KEYS_ENV}"
chmod 0600 "${KEYS_ENV}"

# 3. Load the key, then export the package-forced settings. Setting these from start.sh (not the
#    Dockerfile) keeps the secret out of the image and lets a few stay operator-overridable.
set -a
# shellcheck source=/dev/null
. "${KEYS_ENV}"
set +a
export DOCLING_SERVE_API_KEY

export HOME="${DATA}"                                   # stray ~/.cache writes land in backed-up state
export HF_HOME="${HF_DIR}"
# Self-hosted, offline-capable (models are baked). Disable Hugging Face usage telemetry so the app
# does not phone home on boot to fetch the agent-harness manifest or send usage pings. This does not
# block legitimate model pulls (an operator can still enable an optional VLM preset).
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export DOCLING_SERVE_SCRATCH_PATH="${SCRATCH_DIR}"
export DOCLING_SERVE_ARTIFACTS_PATH="${DOCLING_SERVE_ARTIFACTS_PATH:-/app/code/models}"
export DOCLING_SERVE_ENABLE_UI="${DOCLING_SERVE_ENABLE_UI:-1}"
# Bind explicitly: the platform sets HOSTNAME to the container id, so rely on 0.0.0.0, not the name.
export UVICORN_HOST=0.0.0.0
export UVICORN_PORT="${HTTP_PORT}"

# 4. Concurrency, sized to the cgroup CPU allotment Cloudron grants this app.
CPUS="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CQ CP < /sys/fs/cgroup/cpu.max || true
  if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then
    C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C
  fi
fi
THREADS="${DOCLING_NUM_THREADS:-${CPUS}}"
(( THREADS < 1 )) && THREADS=1
export DOCLING_NUM_THREADS="${THREADS}"
export OMP_NUM_THREADS="${THREADS}"

if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "==> [start] cgroup memory.max=$(cat /sys/fs/cgroup/memory.max) bytes"
fi

# 5. Report resolved runtime facts (never the key) and hand off.
echo "==> [start] http     : 0.0.0.0:${HTTP_PORT} (UI /ui, docs /docs, convert /v1/convert/*)"
echo "==> [start] models   : ${DOCLING_SERVE_ARTIFACTS_PATH} (baked into the image)"
echo "==> [start] hf_home  : ${HF_DIR}"
echo "==> [start] scratch  : ${SCRATCH_DIR}"
echo "==> [start] ui       : ${DOCLING_SERVE_ENABLE_UI}"
echo "==> [start] threads  : ${THREADS}"
echo "==> [start] api key  : $( [[ -s "${KEYS_ENV}" ]] && echo 'present' || echo 'MISSING' )"
echo "==> [start] exec docling-serve run ${VERSION}"
exec gosu cloudron:cloudron "${BIN}" run
