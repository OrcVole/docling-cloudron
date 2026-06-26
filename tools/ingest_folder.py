#!/usr/bin/env python3
"""
ingest_folder.py - convert a local folder of documents with Docling and load them into a Qdrant
collection, ready for semantic search.

It points a Docling Serve endpoint (local or remote) at each file, converts to Markdown, chunks the
text, embeds each chunk with an OpenAI-compatible embeddings server (for example the TEI package),
and upserts the vectors into a Qdrant collection. Run Docling locally on a strong machine (optionally
a CUDA build for GPU acceleration) and send only the resulting vectors to a remote Qdrant.

Send results to a new ("empty project") collection or add to an existing one. Point IDs are
deterministic (a UUID5 of the source path plus chunk index), so re-running updates a document in
place instead of duplicating it.

Configuration (environment variables, all overridable by flags):
  DOCLING_URL        Docling Serve base URL              (e.g. http://127.0.0.1:5001)
  DOCLING_API_KEY    Docling X-Api-Key                   (optional; omit if the endpoint is open)
  TEI_URL            embeddings base URL                 (e.g. https://tei.example.com)
  TEI_API_KEY        embeddings bearer token             (optional)
  QDRANT_URL         Qdrant base URL                     (e.g. https://qdrant.example.com)
  QDRANT_API_KEY     Qdrant api-key                      (optional)

Usage:
  python3 ingest_folder.py /path/to/folder --collection myproject
  python3 ingest_folder.py /path/to/folder --collection myproject --recreate
  python3 ingest_folder.py /path/to/folder --collection myproject --model BAAI/bge-small-en-v1.5
  # target an agentgateway mcp-server-qdrant collection (named vector + document/metadata payload):
  python3 ingest_folder.py /path/to/folder --collection knowledge --for-agentgateway

Notes:
  - The embedding model and dimension must match whatever queries the collection later (for example
    an agentgateway MCP tool), or search returns poor matches even when the dimensions line up.
  - Stdlib only by default. The optional --local-embed mode additionally needs `fastembed`, and
    embeds with the exact same model mcp-server-qdrant uses for queries (tightest alignment).
"""
import argparse, json, os, sys, threading, time, uuid, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

SUPPORTED = (".pdf", ".docx", ".pptx", ".xlsx", ".html", ".htm", ".md", ".markdown",
             ".adoc", ".asciidoc", ".csv", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp")
NS = uuid.UUID("6f4b8d2e-0000-4000-8000-d0c11a9f01de")  # fixed namespace for deterministic IDs


def http(url, method="GET", headers=None, data=None, files=None, timeout=300):
    h = dict(headers or {})
    if files:
        b = "----d" + uuid.uuid4().hex
        fn, content, ctype = files
        body = ("--%s\r\nContent-Disposition: form-data; name=\"files\"; filename=\"%s\"\r\n"
                "Content-Type: %s\r\n\r\n" % (b, fn, ctype)).encode() + content + ("\r\n--%s--\r\n" % b).encode()
        h["Content-Type"] = "multipart/form-data; boundary=%s" % b
        data = body
    elif data is not None and not isinstance(data, bytes):
        data = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else {}


def convert(docling, key, path, fname):
    """Convert one file via Docling's async endpoint and return its Markdown."""
    hdr = {"X-Api-Key": key} if key else {}
    content = open(path, "rb").read()
    r = http(f"{docling}/v1/convert/file/async", "POST", hdr, files=(fname, content, "application/octet-stream"), timeout=120)
    tid = r.get("task_id") or r.get("task", {}).get("task_id")
    for _ in range(1200):  # up to ~1 hour for very large documents
        s = http(f"{docling}/v1/status/poll/{tid}", "GET", hdr, timeout=60)
        st = s.get("task_status") or s.get("status")
        if st in ("success", "completed"):
            break
        if st in ("failure", "error"):
            raise RuntimeError("conversion failed: %s" % json.dumps(s)[:200])
        time.sleep(3)
    res = http(f"{docling}/v1/result/{tid}", "GET", hdr, timeout=120)
    return res.get("document", {}).get("md_content", "")


def chunk(md, size=1000, overlap=120):
    paras = [p.strip() for p in md.split("\n\n") if p.strip()]
    out, cur = [], ""
    for p in paras:
        if len(cur) + len(p) + 2 <= size:
            cur = (cur + "\n\n" + p).strip()
        else:
            if cur:
                out.append(cur)
            if len(p) <= size:
                cur = p
            else:
                for i in range(0, len(p), size - overlap):
                    out.append(p[i:i + size])
                cur = ""
    if cur:
        out.append(cur)
    return [c for c in out if len(c) > 30]


def embed(tei, key, model, texts, batch=32):
    hdr = {"Authorization": "Bearer " + key} if key else {}
    vecs = []
    for i in range(0, len(texts), batch):
        d = http(f"{tei}/v1/embeddings", "POST", hdr, {"input": texts[i:i + batch], "model": model}, timeout=120)
        vecs += [x["embedding"] for x in d["data"]]
    return vecs


_LOCAL_EMBEDDER = None
_EMBED_LOCK = threading.Lock()


def embed_local(model, texts):
    """Embed locally with fastembed. This is the SAME embedder mcp-server-qdrant uses for queries,
    so data and queries land in the identical space (tighter than TEI-data vs fastembed-query).
    Serialized with a lock so it is safe to call from concurrent ingest workers."""
    global _LOCAL_EMBEDDER
    with _EMBED_LOCK:
        if _LOCAL_EMBEDDER is None:
            try:
                from fastembed import TextEmbedding
            except ImportError:
                sys.exit("--local-embed needs fastembed (pip install fastembed)")
            _LOCAL_EMBEDDER = TextEmbedding(model_name=model)
        return [v.tolist() for v in _LOCAL_EMBEDDER.embed(list(texts))]


def main():
    ap = argparse.ArgumentParser(description="Ingest a local folder into a Qdrant collection via Docling + embeddings.")
    ap.add_argument("folder")
    ap.add_argument("--collection", required=True)
    ap.add_argument("--recreate", action="store_true", help="delete and recreate the collection first")
    ap.add_argument("--model", default=os.environ.get("EMBED_MODEL", "BAAI/bge-small-en-v1.5"))
    ap.add_argument("--vector-name", default="", help="store under a NAMED vector (e.g. fast-bge-small-en-v1.5); default is an unnamed vector")
    ap.add_argument("--mcp-payload", action="store_true", help="payload as {document, metadata} (mcp-server-qdrant format) instead of {text, source, chunk}")
    ap.add_argument("--for-agentgateway", action="store_true", help="shortcut: target an agentgateway mcp-server-qdrant collection (named vector fast-<model> plus --mcp-payload)")
    ap.add_argument("--local-embed", action="store_true", help="embed locally with fastembed (matches mcp-server-qdrant's query embedder exactly) instead of calling TEI; needs fastembed")
    ap.add_argument("--workers", type=int, default=1, help="convert N documents concurrently (one doc only uses ~5 cores; raise this to use more, and match docling-serve's eng_loc_num_workers)")
    ap.add_argument("--docling", default=os.environ.get("DOCLING_URL", "http://127.0.0.1:5001"))
    ap.add_argument("--tei", default=os.environ.get("TEI_URL", ""))
    ap.add_argument("--qdrant", default=os.environ.get("QDRANT_URL", ""))
    a = ap.parse_args()
    if a.for_agentgateway:
        a.mcp_payload = True
        if not a.vector_name:
            a.vector_name = "fast-" + a.model.split("/")[-1].lower()
    dkey = os.environ.get("DOCLING_API_KEY", "")
    tkey = os.environ.get("TEI_API_KEY", "")
    qkey = os.environ.get("QDRANT_API_KEY", "")
    if not a.qdrant:
        sys.exit("set QDRANT_URL (env or flag)")
    if not a.local_embed and not a.tei:
        sys.exit("set TEI_URL (env or flag), or pass --local-embed to embed locally with fastembed")
    qhdr = {"api-key": qkey} if qkey else {}

    files = []
    for root, _, names in os.walk(a.folder):
        for n in sorted(names):
            if n.lower().endswith(SUPPORTED):
                files.append(os.path.join(root, n))
    if not files:
        sys.exit("no supported documents under %s" % a.folder)
    print("found %d documents under %s" % (len(files), a.folder), flush=True)

    # Decide collection: create if missing (dimension probed from one embedding), or add to existing.
    if a.recreate:
        try: http(f"{a.qdrant}/collections/{a.collection}", "DELETE", qhdr)
        except Exception: pass
    try:
        info = http(f"{a.qdrant}/collections/{a.collection}", "GET", qhdr)
        exists = info.get("status") == "ok"
    except urllib.error.HTTPError:
        exists = False
    if not exists:
        dim = len((embed_local(a.model, ["dimension probe"]) if a.local_embed
                   else embed(a.tei, tkey, a.model, ["dimension probe"]))[0])
        vparams = {"size": dim, "distance": "Cosine"}
        vectors = {a.vector_name: vparams} if a.vector_name else vparams
        http(f"{a.qdrant}/collections/{a.collection}", "PUT", qhdr, {"vectors": vectors})
        print("created collection '%s' (%d-dim, Cosine%s)" % (
            a.collection, dim, (", named vector '%s'" % a.vector_name) if a.vector_name else ""), flush=True)
    else:
        print("adding to existing collection '%s'" % a.collection, flush=True)

    lock = threading.Lock()
    stats = {"chunks": 0, "docs": 0}

    def process_one(path):
        rel = os.path.relpath(path, a.folder)
        t0 = time.time()
        try:
            md = convert(a.docling, dkey, path, os.path.basename(path))
        except Exception as e:
            with lock:
                print("  SKIP %-50s %s" % (rel[:50], e), flush=True)
            return
        chunks = chunk(md)
        if not chunks:
            with lock:
                print("  SKIP %-50s (no text)" % rel[:50], flush=True)
            return
        vecs = embed_local(a.model, chunks) if a.local_embed else embed(a.tei, tkey, a.model, chunks)
        points = []
        for i, (v, c) in enumerate(zip(vecs, chunks)):
            vec = {a.vector_name: v} if a.vector_name else v
            payload = ({"document": c, "metadata": {"source": rel, "chunk": i}}
                       if a.mcp_payload else {"text": c, "source": rel, "chunk": i})
            points.append({"id": str(uuid.uuid5(NS, "%s::%d" % (rel, i))), "vector": vec, "payload": payload})
        http(f"{a.qdrant}/collections/{a.collection}/points?wait=true", "PUT", qhdr, {"points": points})
        with lock:
            stats["chunks"] += len(points)
            stats["docs"] += 1
            print("  %-50s %4d chunks  (%.0fs)" % (rel[:50], len(chunks), time.time() - t0), flush=True)

    if a.workers > 1:
        print("converting with %d concurrent workers" % a.workers, flush=True)
        with ThreadPoolExecutor(max_workers=a.workers) as ex:
            list(ex.map(process_one, files))
    else:
        for path in files:
            process_one(path)

    print("\ndone: %d chunks across %d documents in collection '%s'" % (stats["chunks"], stats["docs"], a.collection), flush=True)


if __name__ == "__main__":
    main()
