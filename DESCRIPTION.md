<upstream>1.29.0</upstream>

Docling Serve converts documents into clean, structured Markdown and JSON through an HTTP API. It is
the API server for Docling, the open document-conversion toolkit, packaged here for Cloudron.

Point it at a PDF, DOCX, PPTX, XLSX, HTML, Markdown, or an image and it returns well-structured text
with the reading order preserved. It recovers page layout, reconstructs tables, reads embedded and
scanned text with OCR, and classifies pictures, so the output is faithful enough to feed a
retrieval-augmented-generation pipeline or any downstream text process.

What you get on Cloudron:

- A document-conversion API on one HTTP port, protected by an API key that is generated for you on
  first install. Send it as the `X-Api-Key` header to the `/v1/convert/*` endpoints.
- A demonstrator web UI at `/ui`, placed behind Cloudron single sign-on, for converting a document
  in the browser without writing any code.
- Interactive OpenAPI documentation at `/docs`.
- The full default pipeline (layout analysis, TableFormer table structure, the EasyOCR and RapidOCR
  engines, picture classification) with its models baked into the image, so the app works the moment
  it finishes installing, with no first-boot download and no external model server.

It runs CPU-only, stores all state under its data volume so Cloudron backs it up, and ships with
sensible, secure defaults. It pairs naturally with an embeddings server and a vector database to
build a self-hosted "ask questions about my own documents" stack.

Docling is open source under the MIT license. This package tracks the upstream docling-serve release
and adapts only the runtime environment to Cloudron; it does not modify Docling itself.
