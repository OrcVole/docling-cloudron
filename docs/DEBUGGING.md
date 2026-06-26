# Debugging runbook

## Greppable log markers

`start.sh` prints every package line with the `==>` prefix, so:

```bash
cloudron logs -f --app docling.example.com | grep '==>'
```

shows the boot sequence: ownership prep, key generation (first run only), the resolved http/models/
scratch/threads facts, and the `exec docling-serve run` handoff. Lines without the prefix are
docling-serve's own (uvicorn, gradio, the conversion pipeline).

## State on disk (everything under /app/data)

- `/app/data/.secrets/keys.env` - the generated API key (`DOCLING_SERVE_API_KEY`). 0600, owned by
  cloudron. Read it from the app Terminal.
- `/app/data/hf` - `HF_HOME`: anything pulled from Hugging Face at runtime (for example an optional
  VLM preset). Empty for the default pipeline, which uses the baked models.
- `/app/data/scratch` - `DOCLING_SERVE_SCRATCH_PATH`: in-flight conversion working files.

The pipeline models are baked into the image at `/app/code/models` (read-only), not under `/app/data`,
because they are reproducible from the image and do not need backing up.

## Common checks

- Health: `curl -fsS https://docling.example.com/health` returns 200 with no key.
- Convert is gated: `curl -o /dev/null -w '%{http_code}' -X POST https://docling.example.com/v1/convert/file -F files=@x.pdf`
  returns 401 without the key.
- A keyed convert: add `-H "X-Api-Key: $KEY"` and a real file; the response JSON carries the Markdown.
- Which user: `cloudron exec --app docling.example.com -- ps -o user=,comm= | grep docling-serve`
  should show `cloudron`.

## Symptoms

- **App marked unhealthy at boot.** The models are baked in, so first boot is fast; if it is slow,
  check the logs for an unexpected runtime download (a non-default OCR engine or VLM preset pulling
  from Hugging Face) and either bake that model or raise the health grace.
- **Conversions fail or the container is OOM-killed.** OCR and layout over large or scanned PDFs are
  memory intensive. Raise the app memory limit (dashboard -> Resources) and retry.
- **A convert call returns 401.** The `X-Api-Key` header is missing or wrong. Read the current key
  from `/app/data/.secrets/keys.env`.
- **The /ui page redirects to Cloudron login.** That is by design: `/ui` sits behind single sign-on.
  The convert API does not.

## Rebuild and re-test after a change

```bash
test/smoke.sh                          # local build + runtime convert gate
cloudron update --app docling.example.com
```
