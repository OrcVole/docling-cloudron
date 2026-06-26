Docling Serve is installed and ready. The document-conversion pipeline and its models ship inside the
image, so there is no first-boot download to wait for.

Your API key was generated on first run. To read it, open a Terminal for this app (the >_ button in
the Cloudron dashboard) and run:

cat /app/data/.secrets/keys.env

Send that key as the HTTP header  X-Api-Key: YOUR_KEY  on every call to the conversion API.

Convert a document from the command line (replace YOUR_KEY and the file path):

curl -X POST https://APP_DOMAIN/v1/convert/file -H "X-Api-Key: YOUR_KEY" -F "files=@/path/to/document.pdf"

The response is JSON containing the converted Markdown.

The browser surfaces, both behind your Cloudron login:

- /ui   a demonstrator interface for converting a document by hand. The "Open" button in the
  dashboard goes here.
- /docs  the interactive OpenAPI documentation for every endpoint.

Notes:

- The conversion API is open at the network level and protected by the key, so scripts and other apps
  can reach it without a Cloudron login. The /ui and /docs pages require your Cloudron login.
- All state (the key, the model cache, conversion scratch) lives under /app/data and is included in
  Cloudron backups.
- Document conversion, especially OCR on scanned pages, is memory and CPU intensive. If large jobs
  fail, raise this app's memory limit in the dashboard (Resources) and try again.
- Tesseract, EasyOCR and RapidOCR are all available as OCR engines; EasyOCR is the default.
