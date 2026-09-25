#!/usr/bin/env bash
# Rebuild libfff_c.so from source so it runs on Rocky Linux 8.10 (glibc 2.28).
#
# The published @ff-labs/fff-bin-linux-x64-gnu targets glibc >= 2.31 and fails
# to dlopen on Rocky 8 (GLIBC_2.29/2.30 not found). Building the exact tagged
# source with Rust <= 1.90 on this system produces an ABI-identical library
# linked against glibc 2.28.
#
# Usage: build-fff.sh --tag v0.9.4 --out /opt/fff/libfff_c.so
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

WORK=/tmp/fff-src
rm -rf "$WORK"
git clone --depth 1 --branch "$TAG" https://github.com/dmtrKovalenko/fff.git "$WORK"
cd "$WORK"

# Same crate, profile, and features as the official release build
# (.github/workflows/release.yaml in fff): only the host differs.
cargo build --profile ci -p fff-c --no-default-features --features zlob

BUILT="$WORK/target/ci/libfff_c.so"
[[ -f "$BUILT" ]] || { echo "expected $BUILT missing" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$BUILT" "$OUT"

echo "== glibc symbols required by rebuilt lib (host has $(ldd --version | head -n 1)) =="
strings "$OUT" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -n 5

# Hard gate: the library must resolve on THIS system (glibc 2.28).
if ldd "$OUT" 2>&1 | grep -q "not found"; then
  echo "rebuilt libfff_c.so still has unresolved deps:" >&2
  ldd "$OUT" >&2
  exit 1
fi
echo "libfff_c.so resolves cleanly on $(cat /etc/rocky-release 2>/dev/null || uname -a)"

# Informational: show which options-version the C source speaks. The pinned JS
# wrapper (@ff-labs/fff-node 0.9.x) passes version 1.
grep -rn "OPTIONS_VERSION[^0-9]*1\b\|options_version.*1" crates/fff-c/src/ 2>/dev/null | head -n 3 || true
echo "(built from tag $TAG; wrapper compatibility is verified by the smoke test)"
