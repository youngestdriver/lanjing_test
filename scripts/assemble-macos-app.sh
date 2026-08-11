#!/bin/bash
# Assemble LanjingQuiz.app from the universal server binary + Swift launcher.
# Usage: assemble-macos-app.sh <server-arm64> <server-x64> <out-dir>
#   out-dir receives LanjingQuiz.app and LanjingQuiz-macOS.dmg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARM="${1:?arm64 binary required}"
X64="${2:?x64 binary required}"
OUT="${3:?out dir required}"
APP="$OUT/LanjingQuiz.app"
VERSION="${LANJING_APP_VERSION:-0.0.1}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal server binary
lipo -create "$ARM" "$X64" -output "$APP/Contents/Resources/LanjingQuiz-server"
chmod +x "$APP/Contents/Resources/LanjingQuiz-server"

# Launcher
swiftc -O "$ROOT/apps/desktop/macos/main.swift" \
  -o "$APP/Contents/MacOS/LanjingQuiz" \
  -framework AppKit -framework Foundation

# Icon + metadata
cp "$ROOT/assets/desktop/status-icon.png" "$APP/Contents/Resources/status-icon.png"
cp "$ROOT/apps/desktop/macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# DMG
hdiutil create -volname "蓝鲸助手" -srcfolder "$APP" -ov -format UDZO \
  "$OUT/LanjingQuiz-macOS.dmg" >/dev/null
echo "wrote $APP and $OUT/LanjingQuiz-macOS.dmg"
