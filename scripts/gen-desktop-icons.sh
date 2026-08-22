#!/bin/bash
# One-shot icon generation (macOS: sips + iconutil). Regenerate and commit the
# outputs; CI never runs this. Source: the high-resolution desktop app icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets/desktop"
SRC="$ROOT/assets/app-icon.png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"
for size in 16 32 48; do
  sips -z "$size" "$size" "$SRC" --out "$TMP/$size.png" >/dev/null
done
sips -z 36 36 "$SRC" --out "$TMP/status.png" >/dev/null
cp "$TMP/status.png" "$OUT/status-icon.png"
node "$ROOT/scripts/assemble-ico.js" "$TMP/16.png" "$TMP/32.png" "$TMP/48.png" "$OUT/icon.ico"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" \
            "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" \
            "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" \
            "1024 icon_512x512@2x"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/icon.icns"

echo "wrote $OUT/icon.ico, $OUT/icon.icns, and $OUT/status-icon.png"
