#!/usr/bin/env bash
# Smoke-test the Rocky 8 backend: CLI, native modules, server boot, HTTP.
# Runs inside the built image (see Dockerfile `selftest` stage) or against any
# extracted /app tree with node + node_modules beside dist/.
#
#   SMOKE_PORT=3773 T3CODE_HOME=/tmp/t3-smoke ./smoke-test.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
cd "$APP_DIR"
export T3CODE_HOME="${T3CODE_HOME:-/tmp/t3-smoke-home}"
PORT="${SMOKE_PORT:-3773}"

rm -rf "$T3CODE_HOME"
mkdir -p "$T3CODE_HOME"

echo "== files =="
test -f dist/bin.mjs || { echo "dist/bin.mjs missing" >&2; exit 1; }
test -f dist/client/index.html || { echo "dist/client web bundle missing" >&2; exit 1; }
test -d node_modules/node-pty || { echo "node_modules/node-pty missing" >&2; exit 1; }
test -f node_modules/@ff-labs/fff-bin-linux-x64-gnu/libfff_c.so || { echo "libfff_c.so missing" >&2; exit 1; }
echo "bundle + web client + native externals present"

echo "== cli =="
node dist/bin.mjs --version
node dist/bin.mjs --help >/dev/null
echo "cli ok"

echo "== node-pty =="
node -e "const p=require('node-pty');const t=p.spawn('echo',['pty-alive'],{});t.onData(d=>{process.stdout.write('pty says: '+d);t.kill();});setTimeout(()=>process.exit(0),3000);"

echo "== keyring (import-only; secret I/O needs a D-Bus service) =="
node -e "require('@napi-rs/keyring');console.log('keyring ok')"

echo "== fff (rebuilt libfff_c.so via ffi-rs) =="
mkdir -p /tmp/fff-smoke/src
echo "hello rocky" > /tmp/fff-smoke/src/rocky-note.txt
node --input-type=module -e "
import { FileFinder } from '@ff-labs/fff-node';
const created = FileFinder.create({ basePath: '/tmp/fff-smoke' });
if (!created.ok) { console.error('create failed:', created.error); process.exit(1); }
const finder = created.value;
await finder.waitForScan(15000);
const res = finder.fileSearch('rocky-note', { pageSize: 10 });
if (!res.ok) { console.error('search failed:', res.error); process.exit(1); }
const hits = (res.value.items ?? []).map((i) => i.relativePath ?? i.path ?? JSON.stringify(i));
console.log('fff search hits:', JSON.stringify(hits));
finder.destroy();
if (!hits.some((h) => String(h).includes('rocky-note'))) { console.error('expected hit missing'); process.exit(1); }
console.log('fff ok');
"

echo "== server boot =="
node dist/bin.mjs serve --host 127.0.0.1 --port "$PORT" --base-dir "$T3CODE_HOME" >/tmp/t3-smoke.log 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

READY=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/" -o /tmp/t3-index.html 2>/dev/null; then READY=1; break; fi
  sleep 2
done
if [[ "$READY" != 1 ]]; then
  echo "server never answered on :$PORT" >&2
  tail -n 50 /tmp/t3-smoke.log >&2 || true
  exit 1
fi
echo "server answered on :$PORT"

echo "== web client served =="
grep -qi "<!doctype html" /tmp/t3-index.html
echo "index.html served ($(wc -c < /tmp/t3-index.html) bytes)"

echo "== rpc stack + auth gate =="
WS_CODE="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/ws" || true)"
echo "GET /ws -> $WS_CODE (expect 4xx: reachable + auth-gated)"
case "$WS_CODE" in
  4*) echo "auth gate ok" ;;
  *) echo "unexpected /ws status (wanted 4xx, server may be unhealthy)" >&2; tail -n 30 /tmp/t3-smoke.log >&2 || true; exit 1 ;;
esac

echo "== sqlite state (node:sqlite migrations) =="
DB="$T3CODE_HOME/userdata/state.sqlite"
test -f "$DB" || { echo "$DB missing" >&2; ls -laR "$T3CODE_HOME" >&2 || true; exit 1; }
echo "state.sqlite present ($(wc -c < "$DB") bytes)"

kill "$SRV"
trap - EXIT
wait "$SRV" 2>/dev/null || true
echo "SMOKE OK"
