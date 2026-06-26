# Integrations

Docling Serve is the document-ingestion front end of a self-hosted retrieval-augmented-generation
(RAG) stack. This page shows how it connects to the companion services. Hostnames below are
placeholders (`*.example.com`); use your own.

## The pipeline

```
documents (PDF, DOCX, PPTX, XLSX, HTML, images)
   -> Docling Serve   POST /v1/convert/*      clean Markdown / JSON, layout + tables + OCR
   -> chunk the Markdown                       split into passages
   -> Embeddings server  POST /v1/embeddings   passages -> vectors
   -> Vector database    upsert                 store vectors in a collection
   -> Gateway / Chat UI  semantic search        retrieve passages, answer with an LLM
```

Docling sits in front of the embeddings server. The companions in this stack are the TEI package
(text-embeddings-inference, OpenAI-compatible `/v1/embeddings`) and the Qdrant package (vector
database). A default of `BAAI/bge-small-en-v1.5` (384-dimensional) on the embeddings side keeps the
vectors comparable across the stack.

## Calling Docling

The convert API is protected by the API key as the `X-Api-Key` header (generated on first install,
readable at `/app/data/.secrets/keys.env`). The `/ui` and `/docs` pages sit behind Cloudron login.

Convert a file (multipart):

```bash
curl -X POST https://docling.example.com/v1/convert/file \
  -H "X-Api-Key: $DOCLING_KEY" \
  -F "files=@/path/to/document.pdf"
```

Convert a source by URL or inline content (JSON), with options:

```bash
curl -X POST https://docling.example.com/v1/convert/source \
  -H "X-Api-Key: $DOCLING_KEY" -H 'content-type: application/json' \
  -d '{"sources":[{"kind":"http","url":"https://example.com/report.pdf"}],
       "options":{"to_formats":["md"]}}'
```

The response JSON carries the converted Markdown (the document content), which is the input to the
chunk-and-embed step. For large documents use the async endpoints (`/v1/convert/source/async`) and
poll the task.

## An ingestion flow (n8n)

n8n is a natural orchestrator (it has HTTP, file-source, and Qdrant nodes). One workflow:

1. Trigger on a new or changed document (a file store, a webhook, a schedule).
2. HTTP Request -> Docling `POST /v1/convert/file` with the `X-Api-Key` header. Take the Markdown
   from the response.
3. Chunk the Markdown (by headings or a fixed token window with overlap).
4. HTTP Request -> the embeddings server `POST /v1/embeddings` for each chunk, model
   `BAAI/bge-small-en-v1.5`.
5. Qdrant upsert -> store each `{vector, payload}` into the target collection, with the source path
   and chunk text in the payload.

Keep the package generic: the workflow, the collection name, and the credentials are box-specific and
live in n8n, not in this repository.

## Local batch ingestion (tools/ingest_folder.py)

For ingesting a folder of documents in one shot, `tools/ingest_folder.py` (standard library only)
does the whole chain: it walks a folder, converts each file through a Docling endpoint, chunks and
embeds the text, and upserts into a Qdrant collection (creating it if missing, or adding to an
existing one). Point IDs are deterministic, so re-running updates a document in place.

```bash
DOCLING_URL=http://127.0.0.1:5001 DOCLING_API_KEY=... \
TEI_URL=https://tei.example.com  TEI_API_KEY=... \
QDRANT_URL=https://qdrant.example.com QDRANT_API_KEY=... \
python3 tools/ingest_folder.py /path/to/folder --collection myproject
```

Run the Docling endpoint on a strong local machine (optionally a CUDA build for GPU acceleration) and
send only the resulting vectors to a remote Qdrant; this keeps the heavy conversion off the smaller
Cloudron host. The embedding `--model` must match whatever queries the collection later.

## Retrieval (gateway and chat UI)

Once the collection is populated, a gateway with a vector-search tool (for example an MCP tool over
the same collection) or a chat UI pointed at the embeddings server can answer questions grounded in
the ingested documents. Make sure the query embeddings use the same model and dimension as the
ingested vectors, or search will silently return poor matches.

## Observability and future agents

docling-serve exposes OpenTelemetry hooks (`DOCLING_SERVE_OTEL_ENABLE_TRACES`,
`OTEL_EXPORTER_OTLP_ENDPOINT`) and a Prometheus `/metrics` endpoint, so the conversion tier can be
traced and measured alongside the rest of the stack. These are off or unconfigured by default and are
opt-in through the app's Environment.
