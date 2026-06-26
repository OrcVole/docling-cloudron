# Docling Serve for Cloudron

[Docling](https://github.com/docling-project/docling) converts documents (PDF, DOCX, PPTX, XLSX,
HTML, Markdown, images) into clean, structured Markdown and JSON, with layout analysis, table
reconstruction, and OCR. This repository packages
[docling-serve](https://github.com/docling-project/docling-serve), its HTTP API server, as a
Cloudron community app, to the same standard as the companion
[TEI](https://github.com/OrcVole/tei-cloudron) and [Qdrant](https://github.com/OrcVole/qdrant-cloudron)
packages.

It is the document-ingestion tier of a self-hosted RAG stack: Docling parses documents, an embeddings
server turns the text into vectors, and a vector database stores and searches them. See
[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## What you get

- A document-conversion API on one HTTP port, with a generated API key.
- A demonstrator web UI at `/ui`, behind Cloudron single sign-on.
- Interactive OpenAPI docs at `/docs`.
- The full default pipeline (layout, TableFormer table structure, EasyOCR and RapidOCR, picture
  classification) with its models baked into the image, so the app works immediately on first boot,
  CPU-only, with no model download and no external model server.

## Security model (the topology)

Everything is served on one port. The surfaces split by purpose:

- `POST /v1/convert/*` (the convert API): open at the network level, protected by the API key. Send
  the key as the `X-Api-Key` header. An unauthenticated call returns docling-serve's own 401, not a
  login redirect, so scripts and sibling apps can reach it without a Cloudron login.
- `/health`: open, for Cloudron's health check.
- `/ui`: the demonstrator UI, placed behind Cloudron single sign-on (`proxyAuth`). The dashboard
  "Open" button lands here.
- `/docs`, `/openapi.json`, `/version`: open API shape (no data).

The API key is generated on first run, stored at `/app/data/.secrets/keys.env`, and injected as the
`DOCLING_SERVE_API_KEY` environment variable so it never appears in the process table. All mutable
state lives under `/app/data` and is included in Cloudron backups.

See [docs/decisions/0003-topology.md](docs/decisions/0003-topology.md) for the verified details and
why `supportsBearerAuth` is deliberately not set.

## Install

Community-app install from the published versions URL:

```bash
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/docling-cloudron/main/CloudronVersions.json \
  --location docling.example.com
```

Or build on your own box from a clone:

```bash
git clone https://github.com/OrcVole/docling-cloudron
cd docling-cloudron
cloudron install --location docling.example.com --memory-limit 4G
```

After install, read your key from the app Terminal: `cat /app/data/.secrets/keys.env`.

## Use

```bash
curl -X POST https://docling.example.com/v1/convert/file \
  -H "X-Api-Key: YOUR_KEY" \
  -F "files=@/path/to/document.pdf"
```

The response JSON contains the converted Markdown. For large documents use the async endpoints under
`/v1/convert/source/async`. The full API is documented at `/docs`.

## Configuration

docling-serve is configured by environment variables. The package forces the host, port, API key, UI,
and the cache paths under `/app/data`. Operator-tunable values are set through the app's Environment,
for example `DOCLING_NUM_THREADS`, `DOCLING_HTTP_PORT`, and any `DOCLING_SERVE_*` knob you need (the
OCR engine, page and size limits, OpenTelemetry). See
[AGENTS.md](AGENTS.md) section 6 and the upstream
[configuration docs](https://github.com/docling-project/docling-serve/blob/main/docs/configuration.md).

## Resources

Document conversion, especially OCR over scanned pages, is memory and CPU intensive. The default
memory limit is 4 GB; raise it in the dashboard (Resources) for large or heavily scanned documents.

## Versioning and upstream

This package tracks the upstream docling-serve release, pinned by the `DOCLING_SERVE_VERSION` build
argument and mirrored in the manifest's `upstreamVersion`. Docling is not patched. The package
`version` is its own semver. See [CHANGELOG.md](CHANGELOG.md) and
[docs/decisions/](docs/decisions/).

## License

This packaging is provided as-is. Docling and docling-serve are licensed by their authors under the
MIT license. See the upstream repository for details.
