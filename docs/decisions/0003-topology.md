# 0003: Auth topology - proxyAuth on /ui, key on the convert API, health open

Status: accepted (verified on a local container 2026-06-26; box re-verify in PACKAGING-NOTES)

## Context

docling-serve serves everything on one HTTP port (5001). The surfaces split by purpose:

- the convert API (`POST /v1/convert/*`): programmatic traffic that cannot complete an interactive
  login;
- `/health`: monitoring;
- the browser surfaces: `/ui` (the demonstrator UI), `/docs` (OpenAPI), `/openapi.json`, `/version`.

docling-serve has built-in API-key auth: set `DOCLING_SERVE_API_KEY` and requests require the
`X-Api-Key` header. On Cloudron, `proxyAuth` places Cloudron single sign-on in front of a chosen path.

Empirically, with the API key set (probed without any key):

- `POST /v1/convert/file` returns 401 (the key gates the convert API).
- `/health` returns 200 (open).
- `/ui` (307 to `/ui/`), `/docs`, `/openapi.json`, `/version` all return 200 (the key middleware does
  NOT gate the browser surfaces).

## Decision

- Generate the API key on first run and inject it as `DOCLING_SERVE_API_KEY`. The convert API is open
  at the network level and protected by the key, so n8n and sibling apps authenticate with the
  `X-Api-Key` header and are never redirected to a login page.
- Scope `proxyAuth` to `/ui` only, and set `configurePath` to `/ui` so the dashboard "Open" button
  lands on the SSO-guarded UI. Because `/ui` is app-open (it does not itself require the key), Cloudron
  SSO alone is sufficient to guard it, and the bundled Gradio UI keeps working behind the wall.
- `healthCheckPath` is `/health` (open 2xx).
- Do NOT set `supportsBearerAuth`. docling-serve uses `X-Api-Key`, not Bearer, and nothing key-related
  sits under `/ui`, so the flag would only let a bogus bearer header skip the SSO wall (the lesson
  from the TEI package).

## Consequences

- `/docs`, `/openapi.json`, and `/version` are open. That is API shape, not data, and is acceptable;
  Swagger "Try it out" calls hit the key-gated convert API and get 401 without a key.
- Never widen `proxyAuth` to cover `/v1/convert/*`; that would redirect every programmatic client to a
  login page and break the ingestion pipeline.
- `proxyAuth` must be declared from first install; Cloudron cannot add it to an existing app later.
