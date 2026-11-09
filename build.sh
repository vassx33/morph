#!/bin/bash
# Builds "Morph.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Morph.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -parse-as-library \
  -file-prefix-map "$PWD=." \
  Sources/*.swift -o "$APP/Contents/MacOS/Morph"

echo "→ Icon"
if [ ! -f Resources/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swift scripts/make_icon.swift "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"

echo "→ Signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
