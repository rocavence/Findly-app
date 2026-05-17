#!/bin/bash
# Generate Resources/AppIcon.icns from the Swift renderer.
# Output: Resources/icon-1024.png and Resources/AppIcon.icns

set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ rendering 1024×1024 master"
swift Scripts/make-icon.swift

ICONSET="Resources/AppIcon.iconset"
SRC="Resources/icon-1024.png"

echo "→ generating iconset sizes"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png">/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png">/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"

echo "→ packaging .icns"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"

echo "Done: Resources/AppIcon.icns"
