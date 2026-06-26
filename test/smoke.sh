#!/bin/bash
#
# Local container-level smoke test for the Docling Serve Cloudron package. No Cloudron box required:
# it builds the image and runs it the way Cloudron does (root entrypoint -> start.sh -> gosu
# cloudron), then asserts the auth topology and that a real PDF conversion actually runs on
# cloudron/base.
#
# The build-time gate only imports the modules; the dlopen-heavy runtime (torch, OpenCV, the layout
# and TableFormer models) is exercised only by an actual conversion, which is what this test does.
# Re-run it on any change to the Dockerfile, start.sh, or the upstream pin.
#
# Usage:  test/smoke.sh            (uses podman; set ENGINE=docker to override)
# Needs:  python3 (JSON asserts), a working container engine. The image bakes the models, so the
#         conversion itself needs no network.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ENGINE="${ENGINE:-podman}"
IMG="${IMG:-docling-cloudron:smoke}"
NAME=docling-smoke-$$
PORT="${PORT:-18501}"
DATADIR="$(mktemp -d)"
PDF=test/fixtures/hello.pdf
fail=0
note() { printf '  %-30s %s\n' "$1" "$2"; }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  # Files under $DATADIR are owned by the in-container cloudron uid (a subuid the host user cannot
  # remove directly), so clear them from inside a throwaway container as root first.
  "$ENGINE" run --rm -v "$DATADIR":/d:Z "$IMG" sh -c 'rm -rf /d/* /d/.[!.]* /d/..?*' >/dev/null 2>&1
  rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "== build (cached if already built) =="
"$ENGINE" build -t "$IMG" -f Dockerfile . >/dev/null 2>&1 || { echo "BUILD FAILED"; exit 1; }
echo "  build ok"

echo "== run (Cloudron-style: root -> start.sh -> gosu cloudron) =="
"$ENGINE" run -d --name "$NAME" -v "$DATADIR":/app/data:Z -p 127.0.0.1:$PORT:5001 "$IMG" >/dev/null 2>&1
ready=0
for i in $(seq 1 120); do
  "$ENGINE" logs "$NAME" 2>&1 | grep -qE 'Application startup complete|Uvicorn running' && { ready=1; break; }
  "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^$NAME$" || { echo "  CONTAINER EXITED EARLY"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }
  sleep 2
done
[ "$ready" = 1 ] && note "ready:" "yes (~$((i*2))s)" || { echo "  NEVER became ready"; "$ENGINE" logs "$NAME" 2>&1 | tail -30; exit 1; }

# Dropped privileges? The uvicorn worker should be the cloudron user.
u="$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -p 1; ps -o user= -C docling-serve 2>/dev/null | tail -1' 2>/dev/null | tail -1 | tr -d ' ')"
note "runs as:" "$u"; [ "$u" = cloudron ] || { echo "  EXPECTED cloudron user"; fail=1; }

# Read the generated key as root inside the container (.secrets is 0700 cloudron).
KEY="$("$ENGINE" exec "$NAME" cat /app/data/.secrets/keys.env 2>/dev/null | grep -oP 'DOCLING_SERVE_API_KEY=\K.*')"
note "key length:" "${#KEY} (expect 64)"; [ "${#KEY}" = 64 ] || fail=1

B="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

h=$(code "$B/health");                                                  note "/health no-auth:" "$h"; [ "$h" = 200 ] || fail=1
n=$(code -X POST "$B/v1/convert/file" -F "files=@${PDF}");              note "convert no-key:" "$n"; [ "$n" = 401 ] || [ "$n" = 403 ] || fail=1

# Keyed conversion: POST the baked-model pipeline a real PDF and confirm Markdown comes back.
resp="$(curl -s -X POST "$B/v1/convert/file" -H "X-Api-Key: $KEY" -F "files=@${PDF}")"
md="$(printf '%s' "$resp" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); sys.exit()
doc=d.get("document",d)
print(doc.get("md_content") or doc.get("markdown") or "")
' 2>/dev/null)"
note "convert keyed -> md:" "${md:0:40}${md:+ ...}"
printf '%s' "$md" | grep -qi 'Docling' && note "markdown has text:" "yes" || { note "markdown has text:" "NO"; echo "  raw: ${resp:0:300}"; fail=1; }

echo
if [ "$fail" = 0 ]; then echo "SMOKE: PASS"; else echo "SMOKE: FAIL"; fi
exit "$fail"
