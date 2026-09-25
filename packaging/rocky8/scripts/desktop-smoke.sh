#!/usr/bin/env bash
# Smoke-test the Rocky 8 desktop AppImage.
#  1. every ELF in the payload resolves its shared libs on glibc 2.28,
#  2. the bundled backend (same dist/ as the server release) boots under
#     Electron's Node, with node-pty, fff, and xa11y loading,
#  3. the GUI opens a window under Xvfb (extracted, no FUSE needed),
#  4. when /dev/fuse exists, the AppImage also runs directly (FUSE mount).
#
# Root in a container needs --no-sandbox (Chromium restriction, unrelated to
# Rocky); real desktop users run unprivileged without that flag.
set -euo pipefail

APPIMAGE="$(ls /opt/t3desk/*.AppImage | head -n 1)"
WORK=/tmp/desk-smoke
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "== extract AppImage (no FUSE needed) =="
"$APPIMAGE" --appimage-extract >/dev/null
test -x squashfs-root/AppRun
echo "extracted $(du -sh squashfs-root | cut -f1)"

echo "== ldd sweep over every ELF in the payload =="
# Known-optional exclusion: electron-builder's AppImage template bundles the
# legacy gtk2 tray stack (libappindicator/libindicator/libgconf), which
# Electron only dlopens for tray icons and which can never fully resolve on
# Rocky 8 (no gtk2 dbusmenu/glib bindings ship for EL8). Absence degrades to
# no-legacy-tray; the app runs. Everything else must resolve.
SKIP_TRAY='^lib(appindicator|indicator|gconf).*\.so'
FAIL=0
COUNT=0
while IFS= read -r f; do
  base="$(basename "$f")"
  if [[ "$base" =~ $SKIP_TRAY ]]; then
    echo "skip (optional tray stack): $f"
    continue
  fi
  # Musl-variant bindings ship beside the gnu ones but the loaders only ever
  # open the gnu build on glibc systems.
  if [[ "$f" == *-musl/* ]]; then
    echo "skip (musl variant, never loaded on glibc): $f"
    continue
  fi
  if head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF'; then
    COUNT=$((COUNT + 1))
    OUT="$(ldd "$f" 2>&1)" || true
    if echo "$OUT" | grep -q "not found"; then
      echo "MISSING DEPS in $f:"
      echo "$OUT" | grep "not found"
      FAIL=1
    fi
  fi
done < <(find squashfs-root -type f)
echo "checked $COUNT ELF files"
[[ "$FAIL" == 0 ]] || { echo "ldd sweep failed" >&2; exit 1; }
echo "all shared libs resolve"

echo "== unpack app.asar, overlay unpacked natives =="
npx -y asar@3 extract squashfs-root/resources/app.asar loose >/dev/null 2>&1
test -f loose/apps/server/dist/bin.mjs
test -f loose/apps/desktop/dist-electron/main.cjs
if [[ -d squashfs-root/resources/app.asar.unpacked ]]; then
  cp -r squashfs-root/resources/app.asar.unpacked/* loose/
fi
echo "loose tree ready"

APPRUN="$WORK/squashfs-root/AppRun"
# Node-mode probes bypass AppRun: it prepends --no-sandbox when userns is
# unavailable, which Node's option parser rejects. No Chromium boots here,
# so the sandbox is irrelevant anyway.
ELECTRON_BIN="$WORK/squashfs-root/$(grep -oP 'BIN="\$APPDIR/\K[^"]+' "$APPRUN" | head -n 1)"
test -x "$ELECTRON_BIN"

echo "== bundled backend --version under Electron Node =="
ELECTRON_RUN_AS_NODE=1 "$ELECTRON_BIN" "$WORK/loose/apps/server/dist/bin.mjs" --version

echo "== node-pty under Electron Node =="
ELECTRON_RUN_AS_NODE=1 "$ELECTRON_BIN" -e "
const p = require('$WORK/loose/node_modules/node-pty');
const t = p.spawn('echo', ['pty-alive'], {});
t.onData((d) => { process.stdout.write('pty says: ' + d); t.kill(); });
setTimeout(() => process.exit(0), 3000);
"

echo "== fff search under Electron Node =="
mkdir -p /tmp/fff-desk/src
echo hello > /tmp/fff-desk/src/desk-note.txt
ELECTRON_RUN_AS_NODE=1 "$ELECTRON_BIN" --input-type=module -e "
import('$WORK/loose/node_modules/@ff-labs/fff-node/dist/src/index.js').then(async ({ FileFinder }) => {
  const created = FileFinder.create({ basePath: '/tmp/fff-desk' });
  if (!created.ok) { console.error('create failed:', created.error); process.exit(1); }
  const finder = created.value;
  await finder.waitForScan(15000);
  const res = finder.fileSearch('desk-note', { pageSize: 10 });
  finder.destroy();
  if (!res.ok) { console.error('search failed:', res.error); process.exit(1); }
  const hits = (res.value.items ?? []).map((i) => i.relativePath ?? i.path ?? '');
  console.log('fff search hits:', JSON.stringify(hits));
  if (!hits.some((h) => String(h).includes('desk-note'))) process.exit(1);
});
"

echo "== xa11y binding loads under Electron Node =="
ELECTRON_RUN_AS_NODE=1 "$ELECTRON_BIN" -e "
require('$WORK/loose/node_modules/@crowecawcaw/xa11y');
console.log('xa11y loads');
"

echo "== GUI opens a window under Xvfb =="
Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
XVFB=$!
sleep 2
export DISPLAY=:99
unset ELECTRON_RUN_AS_NODE
"$APPRUN" --no-sandbox >/tmp/app-extracted.log 2>&1 &
APP=$!
cleanup() {
  kill "$APP" 2>/dev/null || true
  kill "$XVFB" 2>/dev/null || true
}
trap cleanup EXIT
sleep 25
if ! kill -0 "$APP" 2>/dev/null; then
  echo "app exited early; last log lines:" >&2
  tail -n 40 /tmp/app-extracted.log >&2 || true
  exit 1
fi
TREE="$(xwininfo -root -tree 2>/dev/null || true)"
echo "$TREE" | grep -qi "t3" || {
  echo "no t3 window found; window tree:" >&2
  echo "$TREE" >&2
  tail -n 20 /tmp/app-extracted.log >&2 || true
  exit 1
}
echo "app alive with a t3 window"
kill "$APP" 2>/dev/null || true
wait "$APP" 2>/dev/null || true

echo "== FUSE direct run =="
if [[ -c /dev/fuse ]]; then
  "$APPIMAGE" --no-sandbox >/tmp/app-fuse.log 2>&1 &
  FUSEAPP=$!
  sleep 12
  if ! kill -0 "$FUSEAPP" 2>/dev/null; then
    if grep -qi "fuse" /tmp/app-fuse.log 2>/dev/null; then
      echo "FUSE mount unavailable in this container (expected without --privileged); extract path already verified"
    else
      echo "direct run exited early:" >&2
      tail -n 30 /tmp/app-fuse.log >&2 || true
      exit 1
    fi
  else
    xwininfo -root -tree 2>/dev/null | grep -qi "t3" && echo "direct FUSE run shows a t3 window"
    kill "$FUSEAPP" 2>/dev/null || true
    wait "$FUSEAPP" 2>/dev/null || true
  fi
else
  echo "no /dev/fuse here; extract path already verified (CI runs unprivileged)"
fi

trap - EXIT
kill "$XVFB" 2>/dev/null || true
echo "DESKTOP SMOKE OK"
