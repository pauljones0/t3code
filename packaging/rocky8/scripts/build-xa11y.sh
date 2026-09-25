#!/usr/bin/env bash
# Rebuild xa11y.linux-x64-gnu.node from source so it runs on Rocky Linux 8.10
# (glibc 2.28).
#
# The published @crowecawcaw/xa11y-linux-x64-gnu targets glibc >= 2.39 and
# fails to dlopen on Rocky 8. Building the exact tagged source with Rust 1.90
# (napi build) produces an ABI-identical binding linked against glibc 2.28.
# Used by the desktop snapshot feature only; the backend does not ship it.
#
# Usage: build-xa11y.sh --tag v0.13.0 --out /opt/native/xa11y.linux-x64-gnu.node
set -euo pipefail

TAG=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TAG" && -n "$OUT" ]] || { echo "usage: $0 --tag <git-tag> --out <path>" >&2; exit 2; }

WORK=/tmp/xa11y-src
rm -rf "$WORK"
git clone --depth 1 --branch "$TAG" https://github.com/xa11y/xa11y.git "$WORK"
cd "$WORK/xa11y-js"

# napi CLI from the project's own devDependencies (matches its release build).
npm install --no-audit --no-fund
npx napi build --platform --release

BUILT="$WORK/xa11y-js/xa11y.linux-x64-gnu.node"
[[ -f "$BUILT" ]] || { echo "expected $BUILT missing" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$BUILT" "$OUT"

echo "== glibc symbols required by rebuilt binding (host has $(ldd --version | head -n 1)) =="
strings "$OUT" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -n 5

# Hard gate: the binding must resolve on THIS system (glibc 2.28).
if ldd "$OUT" 2>&1 | grep -q "not found"; then
  echo "rebuilt xa11y binding still has unresolved deps:" >&2
  ldd "$OUT" >&2
  exit 1
fi
echo "xa11y.linux-x64-gnu.node resolves cleanly on $(cat /etc/rocky-release 2>/dev/null || uname -a)"
