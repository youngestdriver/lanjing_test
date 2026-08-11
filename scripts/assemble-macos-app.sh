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
VERSION="${VERSION#v}" # strip leading v (matches Windows -p:Version handling)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal server binary
lipo -create "$ARM" "$X64" -output "$APP/Contents/Resources/LanjingQuiz-server"
chmod +x "$APP/Contents/Resources/LanjingQuiz-server"

# Launcher: compile both archs (each targeting macOS 12.0 to match
# Info.plist's LSMinimumSystemVersion) and lipo into a universal binary.
# The CLI toolchain on recent macOS cannot link the x86_64 slice (its
# libswiftCompatibility archives are arm64-only) — prefer a full Xcode
# toolchain when available. SWIFTC overrides everything; `lipo -info` in CI
# asserts the result is actually universal.
SWIFT_CMD=()
if [ -n "${SWIFTC:-}" ]; then
  SWIFT_CMD=("$SWIFTC")
else
  if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
    XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
    if [ -n "$XCODE" ]; then
      export DEVELOPER_DIR="$XCODE/Contents/Developer"
    fi
  fi
  SWIFT_CMD=(xcrun -sdk macosx swiftc)
fi
TMPB="$(mktemp -d)"
trap 'rm -rf "$TMPB"' EXIT
"${SWIFT_CMD[@]}" -O -target arm64-apple-macosx12.0 "$ROOT/apps/desktop/macos/main.swift" \
  -o "$TMPB/launcher-arm64" -framework AppKit -framework Foundation
"${SWIFT_CMD[@]}" -O -target x86_64-apple-macosx12.0 "$ROOT/apps/desktop/macos/main.swift" \
  -o "$TMPB/launcher-x64" -framework AppKit -framework Foundation
lipo -create "$TMPB/launcher-arm64" "$TMPB/launcher-x64" \
  -output "$APP/Contents/MacOS/LanjingQuiz"

# Icon + metadata
cp "$ROOT/assets/desktop/status-icon.png" "$APP/Contents/Resources/status-icon.png"
cp "$ROOT/apps/desktop/macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# DMG with install guidance: an Applications shortcut plus a background
# picture that tells the user to drag the app in. Layout is applied via
# Finder (osascript) on a writable image; when that is unavailable (headless
# CI) the image still ships with the shortcut and background, just without
# the pre-arranged window.
STAGE="$(mktemp -d)"
TMPIMG="$(mktemp -d)/lanjing-stage.dmg"
MOUNT="$(mktemp -d)"
trap 'rm -rf "$TMPB" "$STAGE" "$(dirname "$TMPIMG")" "$MOUNT"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$ROOT/assets/desktop/dmg-background.png" "$STAGE/.background/background.png"

hdiutil create -volname "蓝鲸助手" -srcfolder "$STAGE" -format UDRW -ov "$TMPIMG" >/dev/null
hdiutil attach "$TMPIMG" -mountpoint "$MOUNT" >/dev/null
osascript <<'EOF' >/dev/null 2>&1 || echo "warning: dmg window layout skipped (Finder unavailable)"
tell application "Finder"
  tell disk "蓝鲸助手"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 900, 600}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.png"
    set position of item "LanjingQuiz.app" of container window to {250, 250}
    set position of item "Applications" of container window to {650, 250}
    close
  end tell
end tell
EOF
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$TMPIMG" -format UDZO -o "$OUT/LanjingQuiz-macOS.dmg" >/dev/null
echo "wrote $APP and $OUT/LanjingQuiz-macOS.dmg"
