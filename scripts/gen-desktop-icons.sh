#!/bin/bash
# One-shot icon generation (macOS: sips). Regenerate and commit the outputs;
# CI never runs this. Source: apps/web/public/icon-192.png.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/web/public/icon-192.png"
OUT="$ROOT/assets/desktop"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"
for size in 16 32 48; do
  sips -z "$size" "$size" "$SRC" --out "$TMP/$size.png" >/dev/null
done
sips -z 36 36 "$SRC" --out "$TMP/status.png" >/dev/null
cp "$TMP/status.png" "$OUT/status-icon.png"
node "$ROOT/scripts/assemble-ico.js" "$TMP/16.png" "$TMP/32.png" "$TMP/48.png" "$OUT/icon.ico"
echo "wrote $OUT/icon.ico and $OUT/status-icon.png"
